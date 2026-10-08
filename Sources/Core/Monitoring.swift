import AppKit

/// Accessibility notifications per app: lets captures follow window moves quickly and lets launch-time
/// restores react as soon as windows appear instead of waiting for the next poll.
@MainActor
final class AXObserverHub {
    enum Event {
        case windowCreated
        case windowChanged
    }

    var onEvent: ((pid_t, Event) -> Void)?
    private var observers: [pid_t: AXObserver] = [:]
    private var pending: Set<pid_t> = []

    func observe(pid: pid_t, attempt: Int = 0) {
        guard observers[pid] == nil, !pending.contains(pid) else { return }
        pending.insert(pid)
        let refconBits = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        AXWorker.shared.queue.async {
            let refcon = UnsafeMutableRawPointer(bitPattern: refconBits)
            var created: AXObserver?
            var registered = false
            if AXObserverCreate(pid, axObserverCallback, &created) == .success, let observer = created {
                let app = AXUIElementCreateApplication(pid)
                for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXFocusedWindowChangedNotification] {
                    let result = AXObserverAddNotification(observer, app, name as CFString, refcon)
                    registered = registered || result == .success || result == .notificationAlreadyRegistered
                }
            }
            DispatchQueue.main.async {
                // Cleared when stop(pid:) ran meanwhile (the app quit).
                guard self.pending.remove(pid) != nil else { return }
                if registered, let observer = created {
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
                    self.observers[pid] = observer
                } else if attempt < 3 {
                    // Apps that are still launching reject registration; try again shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
                        self.observe(pid: pid, attempt: attempt + 1)
                    }
                }
            }
        }
    }

    func stop(pid: pid_t) {
        pending.remove(pid)
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    func stopAll() {
        for pid in Array(observers.keys) { stop(pid: pid) }
    }

    fileprivate func handle(pid: pid_t, notification: String) {
        onEvent?(pid, notification == kAXWindowCreatedNotification ? .windowCreated : .windowChanged)
    }
}

private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let name = notification as String
    let hub = Unmanaged<AXObserverHub>.fromOpaque(refcon).takeUnretainedValue()
    // Sources are attached to the main run loop, so this already runs on the main thread.
    MainActor.assumeIsolated { hub.handle(pid: pid, notification: name) }
}

/// System notifications that can scramble window layouts.
@MainActor
final class SystemEvents {
    enum Event {
        case appLaunched(NSRunningApplication)
        case appTerminated(NSRunningApplication)
        case displaysChanged
        case willSleep
        case didWake
        case screensDidSleep
        case screensDidWake
        case screenLocked
        case screenUnlocked
        case sessionResigned
        case sessionActivated
        case activeSpaceChanged
    }

    var handler: ((Event) -> Void)?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var displayCallbackRegistered = false

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ make: @escaping (Notification) -> Event?) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let event = make(note) else { return }
                MainActor.assumeIsolated { self?.handler?(event) }
            }
            tokens.append((center, token))
        }
        func app(_ note: Notification) -> NSRunningApplication? {
            note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { app($0).map(Event.appLaunched) }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { app($0).map(Event.appTerminated) }
        observe(workspace, NSWorkspace.willSleepNotification) { _ in .willSleep }
        observe(workspace, NSWorkspace.didWakeNotification) { _ in .didWake }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { _ in .screensDidSleep }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { _ in .screensDidWake }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { _ in .sessionResigned }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { _ in .sessionActivated }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { _ in .activeSpaceChanged }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { _ in .displaysChanged }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { _ in .screenLocked }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { _ in .screenUnlocked }

        if !displayCallbackRegistered {
            displayCallbackRegistered = true
            CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
            displayCallbackRegistered = false
        }
    }

    fileprivate func displayReconfigured() {
        handler?(.displaysChanged)
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
    guard let userInfo else { return }
    let events = Unmanaged<SystemEvents>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { events.displayReconfigured() } }
}
