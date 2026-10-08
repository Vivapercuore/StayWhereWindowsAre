import AppKit

struct LaunchSession {
    let token: UUID
    let bundleID: String
    let task: Task<Void, Never>
}

extension AppModel {
    // MARK: Restore

    /// Puts windows of running apps back where `layout` (by default the current display configuration's) says.
    func restore(
        reason: String,
        apps filter: Set<String>? = nil,
        passes: Int = 1,
        layout override: ConfigLayout? = nil,
        recordUndo: Bool = false,
        isStale: (() -> Bool)? = nil
    ) async {
        guard isTrusted else { return }
        if SessionInfo.isScreenLocked {
            pendingRestore = (reason, passes)
            log.add("屏幕已锁定，解锁后再恢复（\(reason)）")
            return
        }
        // Freeze before waiting for the lock so nothing records the scrambled layout in the meantime.
        restoreDepth += 1
        freeze("restore")
        await restoreLock.acquire()
        setRestoring(reason)
        refreshDisplays()
        var total = RestoreReport()
        if let layout = override ?? currentLayout {
            if recordUndo { await saveUndoSnapshot() }
            for pass in 1...max(1, passes) {
                if pass > 1, isStale?() == true { break }
                let moves = await planMoves(layout: layout, apps: filter)
                if moves.isEmpty { break }
                total.add(await engine.execute(moves, displays: displays, topology: SpaceService.topology()))
                // Some apps and macOS itself keep shuffling windows for a moment after a display change.
                if pass < passes { await sleepUnlessCancelled(2.5) }
            }
        }
        lastFingerprint = nil
        await restoreLock.release()
        restoreDepth -= 1
        if restoreDepth == 0 {
            setRestoring(nil)
            unfreeze("restore", after: 2.5)
        }

        lastRestoreAt = Date()
        if total.planned == 0 {
            lastRestoreSummary = "窗口都在原位"
            log.add("\(reason)：窗口都在原位，无需移动")
        } else {
            lastRestoreSummary = total.summary
            let level: ActivityLog.Level = total.failed > 0 || total.spaceFailed > 0 ? .warning : .success
            log.add("\(reason)：\(total.summary)", level: level)
        }
    }

    func planMoves(layout: ConfigLayout, apps filter: Set<String>?) async -> [PlannedMove] {
        let apps = trackedApps().filter { filter?.contains($0.bundleID) ?? true }
        let displays = self.displays
        let topology = SpaceService.topology()
        let sessionID = SessionInfo.sessionID
        let options = RestoreOptions(restoreSpaces: settings.restoreSpaces && PrivateAPI.spacesAvailable)
        let catalog = self.catalog
        let discover = settings.discoverOffSpaceWindows
        return await AXWorker.shared.run {
            let cgWindows = CGWindowSnapshot.all()
            catalog.allowDiscovery(for: 4, visibleSpaces: Set(topology?.displays.map(\.currentSpaceID) ?? []))
            var moves: [PlannedMove] = []
            for (bundleID, instances) in Dictionary(grouping: apps, by: \.bundleID) {
                guard let saved = layout.apps[bundleID] else { continue }
                let live = instances.flatMap { catalog.windows(pid: $0.pid, cgWindows: cgWindows, discoverOffSpace: discover) }.map(\.state)
                moves += RestorePlanner.plan(saved: saved, live: live, displays: displays, topology: topology,
                                             sessionID: sessionID, options: options).moves
            }
            return moves
        }
    }

    // MARK: App launches

    func appLaunched(_ app: NSRunningApplication) {
        guard isTrusted, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return }
        let pid = app.processIdentifier
        Task { [weak self] in
            // AX is not ready the instant a process starts.
            await sleepUnlessCancelled(1)
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
            self?.observers.observe(pid: pid)
        }
        // Login may report the same process twice (our startup scan and the launch notification).
        guard launchSessions[pid] == nil else { return }
        let duringLogin = settings.restoreOnLogin && isFrozen(by: ["startup"])
        guard settings.restoreOnAppLaunch || duringLogin, !settings.isExcluded(bundleID),
              let saved = currentLayout?.apps[bundleID], !saved.windows.isEmpty else { return }
        frozenApps[bundleID] = .distantFuture
        let token = UUID()
        let name = app.localizedName ?? bundleID
        let key = configKey
        let task = Task { [weak self] () -> Void in
            await self?.runLaunchSession(pid: pid, bundleID: bundleID, appName: name, saved: saved, configKey: key, token: token)
        }
        launchSessions[pid] = LaunchSession(token: token, bundleID: bundleID, task: task)
    }

    /// Watches a freshly launched app and moves each window back as soon as it appears and its title settles.
    /// Works on a copy of the layout taken at launch, so indices stay valid while captures update the store.
    private func runLaunchSession(pid: pid_t, bundleID: String, appName: String, saved: AppLayout, configKey key: String, token: UUID) async {
        let deadline = Date().addingTimeInterval(settings.appLaunchWatchSeconds)
        var restoredSaved = Set<Int>()
        var handledLive = Set<UInt32>()
        var seenTitles: [UInt32: String] = [:]
        var total = RestoreReport()
        let blocking: Set<String> = ["displays", "sleep", "locked", "session", "wake"]

        while Date() < deadline {
            guard await waitForPoke(pid: pid, timeout: 0.7) else { break }
            // A different display configuration has its own layout; the display-change restore takes over.
            guard configKey == key else { break }
            if NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true { break }
            if isRestoring || isFrozen(by: blocking) { continue }

            let live = await liveWindows(pid: pid)
            // A window is only matched once its title has been the same on two polls: apps often show a
            // placeholder title ("New Tab", "Untitled") before restoring their real content.
            let settled = live.filter { seenTitles[$0.descriptor.windowID] == $0.descriptor.title }
            for window in live { seenTitles[window.descriptor.windowID] = window.descriptor.title }
            guard !settled.isEmpty else { continue }

            let options = RestoreOptions(restoreSpaces: settings.restoreSpaces && PrivateAPI.spacesAvailable)
            let plan = RestorePlanner.plan(
                saved: saved, live: settled, displays: displays, topology: SpaceService.topology(),
                sessionID: SessionInfo.sessionID, options: options,
                excludingSaved: restoredSaved, excludingLive: handledLive)
            for match in plan.matched {
                restoredSaved.insert(match.savedIndex)
                handledLive.insert(match.windowID)
            }
            if !plan.moves.isEmpty {
                await restoreLock.acquire()
                total.add(await engine.execute(plan.moves, displays: displays, topology: SpaceService.topology()))
                await restoreLock.release()
            }
            if restoredSaved.count >= saved.windows.count { break }
        }
        if total.planned > 0 {
            log.add("\(appName) 启动后：\(total.summary)", level: total.failed + total.spaceFailed > 0 ? .warning : .success)
        }
        if launchSessions[pid]?.token == token { launchSessions[pid] = nil }
        if !launchSessions.values.contains(where: { $0.bundleID == bundleID }) {
            frozenApps[bundleID] = Date().addingTimeInterval(3)
        }
    }

    /// Returns false when the session was cancelled.
    private func waitForPoke(pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pokedPIDs.remove(pid) != nil {
                // Give the new window a moment to get its title and frame.
                return await sleepUnlessCancelled(0.25)
            }
            guard await sleepUnlessCancelled(0.1) else { return false }
        }
        return !Task.isCancelled
    }

    func liveWindows(pid: pid_t) async -> [LiveWindowState] {
        let catalog = self.catalog
        let discover = settings.discoverOffSpaceWindows
        let visibleSpaces = Set(SpaceService.topology()?.displays.map(\.currentSpaceID) ?? [])
        return await AXWorker.shared.run {
            catalog.allowDiscovery(for: 1, visibleSpaces: visibleSpaces)
            return catalog.windows(pid: pid, cgWindows: CGWindowSnapshot.all(), discoverOffSpace: discover).map(\.state)
        }
    }

    // MARK: Manual actions

    func restoreNow() {
        Task { await restore(reason: "手动恢复", recordUndo: true) }
    }

    func togglePaused() {
        settings.autoSaveEnabled.toggle()
        log.add(settings.autoSaveEnabled ? "已恢复自动记录" : "已暂停自动记录")
        updatePhase()
    }

    /// Saves what is on screen now as a named snapshot. The remembered layout is only updated when recording
    /// is allowed, so a snapshot taken while paused or while windows are scrambled cannot overwrite it.
    func saveSnapshot(named name: String? = nil) {
        Task {
            let (displays, apps) = await captureLive(discoverOffSpace: settings.discoverOffSpaceWindows)
            let key = DisplayConfiguration.key(for: displays.map(\.uuid))
            if canCapture, key == configKey {
                store.merge(configKey: key, displays: displays, captured: apps, frozen: frozenAppIDs)
                lastCaptureAt = Date()
            }
            let windows = apps.filter { !$0.value.windows.isEmpty }
            let title = name?.isEmpty == false ? name! : "手动快照 \(Date().formatted(date: .abbreviated, time: .shortened))"
            let snapshot = LayoutSnapshot(id: UUID(), name: title, kind: .manual, createdAt: Date(), configKey: key,
                                          displays: displays, apps: windows)
            store.addSnapshot(snapshot)
            log.add("已保存快照「\(title)」（\(snapshot.windowCount) 个窗口）", level: .success)
        }
    }

    func restoreSnapshot(_ snapshot: LayoutSnapshot) {
        let layout = ConfigLayout(key: snapshot.configKey, displays: snapshot.displays, apps: snapshot.apps,
                                  createdAt: snapshot.createdAt, updatedAt: snapshot.createdAt)
        if snapshot.configKey != configKey {
            log.add("快照「\(snapshot.name)」来自其他显示器组合，只恢复仍连接的显示器上的窗口", level: .warning)
        }
        Task { await restore(reason: "恢复快照「\(snapshot.name)」", layout: layout, recordUndo: true) }
    }

    func restoreConfig(_ config: ConfigLayout) {
        Task { await restore(reason: "恢复「\(config.summary)」的布局", layout: config, recordUndo: true) }
    }

    /// Keeps the layout from just before a manual restore so it can be undone.
    private func saveUndoSnapshot() async {
        let (displays, apps) = await captureLive(discoverOffSpace: false)
        store.addSnapshot(LayoutSnapshot(
            id: UUID(), name: "恢复前的布局", kind: .beforeRestore, createdAt: Date(),
            configKey: DisplayConfiguration.key(for: displays.map(\.uuid)), displays: displays,
            apps: apps.filter { !$0.value.windows.isEmpty }))
    }

    /// Reads the current layout without touching the store.
    private func captureLive(discoverOffSpace: Bool) async -> (displays: [DisplayInfo], apps: [String: AppLayout]) {
        let apps = trackedApps()
        let displays = DisplayService.currentDisplays()
        let topology = SpaceService.topology()
        let previous = store.layout(for: DisplayConfiguration.key(for: displays.map(\.uuid)))
        let catalog = self.catalog, sessionID = SessionInfo.sessionID
        let captured = await AXWorker.shared.run {
            LayoutCapturer.capture(apps: apps, catalog: catalog, displays: displays, topology: topology,
                                   sessionID: sessionID, previous: previous, discoverOffSpace: discoverOffSpace)
        }
        return (displays, captured)
    }
}
