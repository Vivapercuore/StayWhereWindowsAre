import AppKit
import Observation

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, general, restore, apps, layouts, permissions, diagnostics, log, about
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        case needsPermission
        case watching
        case paused
        case settling(String)
        case restoring(String)

        var title: String {
            switch self {
            case .starting: "正在启动"
            case .needsPermission: "需要辅助功能权限"
            case .watching: "守护中"
            case .paused: "已暂停记录"
            case .settling(let reason): reason
            case .restoring(let reason): "正在恢复：\(reason)"
            }
        }
    }

    let settings: AppSettings
    let store: LayoutStore
    let log: ActivityLog

    @ObservationIgnored let catalog = WindowCatalog()
    @ObservationIgnored let switcher = SpaceSwitcher()
    @ObservationIgnored let engine: RestoreEngine
    @ObservationIgnored let events = SystemEvents()
    @ObservationIgnored let observers = AXObserverHub()
    @ObservationIgnored let restoreLock = RestoreLock()
    @ObservationIgnored let selfTest = SelfTest()
    @ObservationIgnored var openSettingsHandler: ((SettingsPage?) -> Void)?

    private(set) var isTrusted = AX.isTrusted
    private(set) var phase: Phase = .starting
    private(set) var displays: [DisplayInfo] = []
    private(set) var configKey = ""
    private(set) var topology: SpaceTopology?
    var lastCaptureAt: Date?
    var lastRestoreAt: Date?
    var lastRestoreSummary: String?
    private(set) var isRestoring = false
    private(set) var launchAtLogin = LoginItem.isEnabled

    @ObservationIgnored var freezes: [String: Date] = [:]
    @ObservationIgnored var frozenApps: [String: Date] = [:]
    @ObservationIgnored var launchSessions: [pid_t: LaunchSession] = [:]
    @ObservationIgnored var pokedPIDs: Set<pid_t> = []
    @ObservationIgnored var pendingRestore: (reason: String, passes: Int)?
    /// Number of restores running or waiting for the lock; captures stay frozen while it is above zero.
    @ObservationIgnored var restoreDepth = 0
    @ObservationIgnored var lastFingerprint: Int?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var lastFullCapture = Date.distantPast
    @ObservationIgnored private var lastAutoSnapshot = Date()
    @ObservationIgnored private var captureInFlight = false
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var captureSoonTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var arrangementSignature = ""
    /// Arrangement the last display-change handling restored for; compared instead of the live configuration,
    /// which restores and captures refresh on their own.
    @ObservationIgnored private var handledArrangement = ""
    @ObservationIgnored private var displayGeneration = 0
    @ObservationIgnored private var wakeGeneration = 0
    @ObservationIgnored private var started = false
    /// Debug runs with separate data that must not prompt for permissions or register a login item.
    @ObservationIgnored var isSandboxed = false

    init(settings: AppSettings? = nil, store: LayoutStore? = nil, log: ActivityLog? = nil) {
        self.settings = settings ?? AppSettings()
        self.store = store ?? LayoutStore(fileURL: LayoutStore.defaultFileURL)
        self.log = log ?? ActivityLog()
        self.engine = RestoreEngine(catalog: catalog, switcher: switcher)
    }

    var currentLayout: ConfigLayout? { store.layout(for: configKey) }
    var displaySummary: String { DisplayConfiguration.summary(of: displays) }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        store.onError = { [weak self] message in self?.log.add(message, level: .error) }
        store.load()
        switcher.log = { [weak self] message in self?.log.add(message, level: .warning) }
        engine.dragger.log = { [weak self] message in self?.log.add(message, level: .warning) }
        applySettings()
        refreshDisplays()
        handledArrangement = arrangementSignature
        events.handler = { [weak self] event in self?.handle(event) }
        events.start()
        observers.onEvent = { [weak self] pid, event in self?.handleAXEvent(pid: pid, event: event) }
        log.add("已启动，当前显示器：\(displaySummary)")
        if !settings.hasLaunchedBefore && !isSandboxed {
            settings.hasLaunchedBefore = true
            if LoginItem.isUnregistered { setLaunchAtLogin(true) }
        }
        if AX.isTrusted {
            beginMonitoring()
        } else {
            phase = .needsPermission
            log.add("需要辅助功能权限才能读取和移动窗口", level: .warning)
            if !isSandboxed {
                // 每次重新编译后签名会变，旧的授权记录指向旧签名，不清掉系统设置里会
                // 显示"已授权"但实际不生效。重置后用户只需要打开一次开关。
                AccessibilityReset.resetIfNeeded()
                AX.requestTrust()
            }
            startTrustPolling()
            openSettingsHandler?(.permissions)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        events.stop()
        observers.stopAll()
        store.saveNow()
    }

    /// Pushes settings into the components that cache them.
    func applySettings() {
        let subroles: Set<String> = settings.includeDialogs ? [kAXStandardWindowSubrole, kAXDialogSubrole] : [kAXStandardWindowSubrole]
        let discover = settings.discoverOffSpaceWindows
        let catalog = self.catalog
        AXWorker.shared.queue.async {
            catalog.allowedSubroles = subroles
            catalog.offSpaceDiscoveryEnabled = discover
        }
        engine.allowDrag = settings.allowDragFallback
        switcher.methods = settings.spaceSwitchMethods
        if pollTimer != nil { startPolling() }
        lastFingerprint = nil
        updatePhase()
    }

    private func beginMonitoring() {
        isTrusted = true
        AX.configureGlobalTimeout()
        for app in trackedApps() { observers.observe(pid: app.pid) }
        let sinceLogin = Date().timeIntervalSince(Self.sessionStartDate())
        if settings.restoreOnLogin, sinceLogin < settings.loginWindowMinutes * 60, currentLayout != nil {
            freeze("startup")
            log.add("检测到刚登录（约 \(Int(sinceLogin)) 秒前），\(Int(settings.loginRestoreDelay)) 秒后恢复窗口布局")
            // Apps that started just before us may still be bringing back their windows one by one.
            for app in NSWorkspace.shared.runningApplications {
                if let launched = app.launchDate, Date().timeIntervalSince(launched) < 90 { appLaunched(app) }
            }
            Task { [weak self] in
                guard let self else { return }
                await sleepUnlessCancelled(self.settings.loginRestoreDelay)
                await self.displayTask?.value
                await self.restore(reason: "开机登录", passes: 2)
                self.unfreeze("startup")
            }
        } else {
            freeze("startup", for: 2)
        }
        startPolling()
        updatePhase()
    }

    private func startTrustPolling() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AX.isTrusted else { return }
                self.trustTimer?.invalidate()
                self.trustTimer = nil
                self.log.add("已获得辅助功能权限", level: .success)
                self.beginMonitoring()
            }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: max(1, settings.pollInterval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Login time, approximated by when the Dock started for this session.
    static func sessionStartDate() -> Date {
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
           let started = processStartDate(pid: dock.processIdentifier) {
            return started
        }
        return Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
    }

    static func processStartDate(pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }

    // MARK: Freezing

    /// While frozen, captures are dropped so a scrambled layout never overwrites the remembered one.
    func freeze(_ reason: String, for seconds: TimeInterval? = nil) {
        freezes[reason] = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
        updatePhase()
    }

    func unfreeze(_ reason: String, after seconds: TimeInterval = 0) {
        freezes[reason] = seconds > 0 ? Date().addingTimeInterval(seconds) : nil
        updatePhase()
    }

    var isFrozen: Bool { freezes.values.contains { $0 > Date() } }

    func isFrozen(by reasons: Set<String>) -> Bool {
        freezes.contains { reasons.contains($0.key) && $0.value > Date() }
    }

    var frozenAppIDs: Set<String> { Set(frozenApps.filter { $0.value > Date() }.keys) }

    var canCapture: Bool {
        isTrusted && settings.autoSaveEnabled && !isFrozen && !isRestoring
            && !(settings.pauseWhenIdle && SessionInfo.secondsSinceLastInput > 300)
    }

    func updatePhase() {
        freezes = freezes.filter { $0.value > Date() }
        frozenApps = frozenApps.filter { $0.value > Date() }
        if !isTrusted { phase = .needsPermission; return }
        if case .restoring = phase, isRestoring { return }
        if !settings.autoSaveEnabled { phase = .paused; return }
        let labels: [(String, String)] = [
            ("locked", "屏幕已锁定"), ("session", "已切换到其他用户"), ("sleep", "睡眠中"), ("wake", "等待唤醒稳定"),
            ("displays", "显示器变化中"), ("startup", "等待开机恢复"), ("selftest", "正在自检"), ("restore", "恢复完成，稍候"),
        ]
        if let label = labels.first(where: { freezes[$0.0] != nil }) {
            phase = .settling(label.1)
        } else {
            phase = .watching
        }
    }

    func setRestoring(_ reason: String?) {
        isRestoring = reason != nil
        if let reason { phase = .restoring(reason) } else { updatePhase() }
    }

    // MARK: Capture

    func trackedApps() -> [TrackedApp] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated, let bundleID = app.bundleIdentifier,
                  bundleID != own, !settings.isExcluded(bundleID) else { return nil }
            return TrackedApp(pid: app.processIdentifier, bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
    }

    private func tick() {
        guard AX.isTrusted else {
            if isTrusted {
                isTrusted = false
                log.add("辅助功能权限已失效（重新编译或移动 App 后常见），请重新授权", level: .error)
                startTrustPolling()
            }
            updatePhase()
            return
        }
        updatePhase()
        guard canCapture, !captureInFlight else { return }
        let fingerprint = LayoutCapturer.fingerprint(pids: Set(trackedApps().map(\.pid)))
        if fingerprint != lastFingerprint || Date().timeIntervalSince(lastFullCapture) > 60 {
            Task { await capture(fingerprint: fingerprint) }
        }
    }

    func capture(fingerprint: Int? = nil, force: Bool = false) async {
        guard !captureInFlight, force || canCapture else { return }
        captureInFlight = true
        defer { captureInFlight = false }
        let displays = DisplayService.currentDisplays()
        let currentKey = SpaceService.layoutKey(for: displays, topology: SpaceService.topology())
        guard currentKey == configKey else {
            displaysChanged()
            return
        }
        let topology = SpaceService.topology()
        let apps = trackedApps()
        let previous = store.layout(for: currentKey)
        let catalog = self.catalog, sessionID = SessionInfo.sessionID, discover = settings.discoverOffSpaceWindows
        let captured = await AXWorker.shared.run {
            LayoutCapturer.capture(apps: apps, catalog: catalog, displays: displays, topology: topology,
                                   sessionID: sessionID, previous: previous, discoverOffSpace: discover)
        }
        // A display change or restore may have started while AX was busy.
        guard force || canCapture, currentKey == configKey else { return }
        store.merge(configKey: currentKey, displays: displays, captured: captured, frozen: frozenAppIDs)
        self.topology = topology
        lastFingerprint = fingerprint ?? LayoutCapturer.fingerprint(pids: Set(apps.map(\.pid)))
        lastFullCapture = Date()
        lastCaptureAt = Date()
        if Date().timeIntervalSince(lastAutoSnapshot) > settings.snapshotIntervalMinutes * 60, let savedConfig = store.layout(for: currentKey) {
            lastAutoSnapshot = Date()
            store.addAutomaticSnapshotIfChanged(from: savedConfig)
        }
    }

    func scheduleCapture(after seconds: TimeInterval) {
        captureSoonTask?.cancel()
        captureSoonTask = Task { [weak self] in
            try? await Task.sleep(seconds: seconds)
            guard !Task.isCancelled, let self, self.canCapture else { return }
            await self.capture()
        }
    }

    func refreshDisplays() {
        let current = DisplayService.currentDisplays()
        let configuration = DisplayConfiguration(displays: current)
        displays = current
        topology = SpaceService.topology()
        configKey = SpaceService.layoutKey(for: current, topology: topology)
        arrangementSignature = configuration.arrangementSignature
    }

    // MARK: Events

    private func handle(_ event: SystemEvents.Event) {
        switch event {
        case .appLaunched(let app):
            appLaunched(app)
        case .appTerminated(let app):
            let pid = app.processIdentifier
            observers.stop(pid: pid)
            launchSessions.removeValue(forKey: pid)?.task.cancel()
            let catalog = self.catalog
            AXWorker.shared.queue.async { catalog.forget(pid: pid) }
        case .displaysChanged:
            displaysChanged()
        case .willSleep, .screensDidSleep:
            // Record the last state the user saw, then stop recording until the system settles after wake.
            let allowed = canCapture
            freeze("sleep")
            if allowed { Task { await capture(force: true) } }
        case .didWake, .screensDidWake, .sessionActivated:
            if case .sessionActivated = event { unfreeze("session", after: 1) }
            scheduleWakeRestore()
        case .screenLocked:
            freeze("locked")
        case .screenUnlocked:
            unfreeze("locked", after: 1.5)
            if let pending = pendingRestore {
                pendingRestore = nil
                // Bounded: if the screen locks again first, the restore is deferred and never clears this.
                freeze("restore", for: 6)
                Task { [weak self] in
                    await sleepUnlessCancelled(1.5)
                    await self?.restore(reason: pending.reason, passes: pending.passes)
                }
            }
        case .sessionResigned:
            freeze("session")
        case .activeSpaceChanged:
            topology = SpaceService.topology()
            scheduleCapture(after: 1.2)
        }
    }

    private func handleAXEvent(pid: pid_t, event: AXObserverHub.Event) {
        if event == .windowCreated { pokedPIDs.insert(pid) }
        scheduleCapture(after: 1.5)
    }

    func displaysChanged() {
        displayGeneration += 1
        let generation = displayGeneration
        freeze("displays")
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            guard let self, await sleepUnlessCancelled(self.settings.displaySettleDelay), generation == self.displayGeneration else { return }
            await self.displaysSettled(generation: generation)
        }
    }

    private func displaysSettled(generation: Int) async {
        refreshDisplays()
        if arrangementSignature != handledArrangement {
            handledArrangement = arrangementSignature
            lastFingerprint = nil
            log.add("显示器配置变化：\(displaySummary)")
            if currentLayout == nil {
                log.add("这是新的显示器组合，开始记录它的布局")
            } else if settings.restoreOnDisplayChange {
                // Runs in its own task so a newer display event cannot cut its waits short; the newer event
                // restores again afterwards, and this one skips its second pass once it is stale.
                await Task { [weak self] in
                    await self?.restore(reason: "显示器变化", passes: 2, isStale: { [weak self] in
                        self.map { $0.displayGeneration != generation } ?? true
                    })
                }.value
            }
        }
        if generation == displayGeneration { unfreeze("displays", after: 2) }
    }

    private func scheduleWakeRestore() {
        wakeGeneration += 1
        let generation = wakeGeneration
        wakeTask?.cancel()
        freeze("wake")
        wakeTask = Task { [weak self] in
            guard let self, await sleepUnlessCancelled(max(3, self.settings.displaySettleDelay + 1)), generation == self.wakeGeneration else { return }
            self.unfreeze("sleep")
            await self.displayTask?.value
            guard generation == self.wakeGeneration else { return }
            if self.settings.restoreOnWake, self.currentLayout != nil {
                await Task { [weak self] in await self?.restore(reason: "唤醒") }.value
            }
            if generation == self.wakeGeneration { self.unfreeze("wake", after: 2) }
        }
    }

    // MARK: Login item

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            log.add(enabled ? "已开启开机自启" : "已关闭开机自启", level: .success)
        } catch {
            log.add("设置开机自启失败：\(error.localizedDescription)", level: .error)
        }
        launchAtLogin = LoginItem.isEnabled
    }

    func refreshLoginItemStatus() { launchAtLogin = LoginItem.isEnabled }

    func openSettings(_ page: SettingsPage? = nil) { openSettingsHandler?(page) }
}
