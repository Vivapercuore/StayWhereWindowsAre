import AppKit

struct SymbolicHotkey: Equatable {
    var keyCode: CGKeyCode
    var flags: CGEventFlags
}

/// Mission Control keyboard shortcuts as configured in System Settings › Keyboard › Keyboard Shortcuts.
enum SymbolicHotkeys {
    static let moveLeftID = 79
    static let moveRightID = 81
    /// "Switch to Desktop 1" … "Switch to Desktop 16".
    static let firstDesktopID = 118

    private static func entries() -> [String: Any] {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
    }

    static func hotkey(id: Int) -> SymbolicHotkey? {
        guard let entry = entries()[String(id)] as? [String: Any] else {
            // Never customised: only the left/right shortcuts are on by default (⌃← / ⌃→).
            switch id {
            case moveLeftID: return SymbolicHotkey(keyCode: 123, flags: [.maskControl, .maskSecondaryFn])
            case moveRightID: return SymbolicHotkey(keyCode: 124, flags: [.maskControl, .maskSecondaryFn])
            default: return nil
            }
        }
        let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? false
        guard enabled,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3,
              parameters[1].intValue != 65535 else { return nil }
        return SymbolicHotkey(keyCode: CGKeyCode(parameters[1].intValue), flags: CGEventFlags(rawValue: parameters[2].uint64Value))
    }

    static func desktop(_ number: Int) -> SymbolicHotkey? {
        (1...16).contains(number) ? hotkey(id: firstDesktopID + number - 1) : nil
    }

    static var moveLeft: SymbolicHotkey? { hotkey(id: moveLeftID) }
    static var moveRight: SymbolicHotkey? { hotkey(id: moveRightID) }

    static var enabledDesktopShortcuts: [Int] { (1...16).filter { desktop($0) != nil } }

    static func post(_ hotkey: SymbolicHotkey) {
        let source = CGEventSource(stateID: .hidSystemState)
        let modifierKeys: [(CGEventFlags, CGKeyCode)] = [(.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55)]
        let held = modifierKeys.filter { hotkey.flags.contains($0.0) }
        var flags: CGEventFlags = []
        func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        for (flag, code) in held { flags.insert(flag); key(code, down: true, flags: flags) }
        key(hotkey.keyCode, down: true, flags: hotkey.flags)
        key(hotkey.keyCode, down: false, flags: hotkey.flags)
        for (flag, code) in held.reversed() { flags.remove(flag); key(code, down: false, flags: flags) }
    }
}

/// A transparent window owned by this app. This process may move its own windows between Spaces,
/// and bringing the window forward makes macOS switch the display to that Space.
final class AnchorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func make() -> AnchorWindow {
        let window = AnchorWindow(contentRect: NSRect(x: 0, y: 0, width: 8, height: 8), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        window.title = "StayWhereWindowsAre Anchor"
        return window
    }
}

@MainActor
final class SpaceSwitcher {
    enum Method: String, CaseIterable, Codable, Identifiable {
        case anchor
        case desktopShortcut
        case arrowShortcut

        var id: String { rawValue }

        var title: String {
            switch self {
            case .anchor: "锚点窗口"
            case .desktopShortcut: "“切换到桌面 N”快捷键"
            case .arrowShortcut: "“向左/右移动一个空间”快捷键"
            }
        }
    }

    var methods: [Method] = Method.allCases
    private(set) var lastWorkingMethod: Method?
    var log: ((String) -> Void)?
    private var anchor: AnchorWindow?

    /// Makes `spaceID` the visible Space of its display. Returns the method that worked, or nil.
    @discardableResult
    func switchTo(
        spaceID: UInt64,
        displayID: String,
        displayFrame: CGRect?,
        topology: SpaceTopology,
        allowAnchor: Bool = true,
        movePointer: Bool = true,
        only: Method? = nil
    ) async -> Method? {
        if SpaceService.currentSpace(displayID: displayID) == spaceID { return lastWorkingMethod ?? .anchor }
        var order = only.map { [$0] } ?? methods
        if !allowAnchor { order.removeAll { $0 == .anchor } }
        if only == nil, let last = lastWorkingMethod, let index = order.firstIndex(of: last) {
            order.remove(at: index)
            order.insert(last, at: 0)
        }
        for method in order {
            let worked: Bool
            switch method {
            case .anchor: worked = await viaAnchor(spaceID: spaceID, displayID: displayID, displayFrame: displayFrame)
            case .desktopShortcut: worked = await viaDesktopShortcut(spaceID: spaceID, displayID: displayID, topology: topology)
            case .arrowShortcut:
                worked = await viaArrows(spaceID: spaceID, displayID: displayID, displayFrame: displayFrame, topology: topology, movePointer: movePointer)
            }
            if worked {
                lastWorkingMethod = method
                return method
            }
            log?("切换桌面方式「\(method.title)」未生效")
        }
        return nil
    }

    /// Puts the anchor away and hands focus back to the app the user was using.
    func finish(reactivating app: NSRunningApplication?) {
        anchor?.orderOut(nil)
        guard let app, !app.isTerminated, app.processIdentifier != getpid() else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    func waitForSpace(_ spaceID: UInt64, displayID: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SpaceService.currentSpace(displayID: displayID) == spaceID {
                // The switch animation is still running; moving a window now would race it.
                guard await sleepUnlessCancelled(0.35) else { return false }
                return SpaceService.currentSpace(displayID: displayID) == spaceID
            }
            guard await sleepUnlessCancelled(0.05) else { return false }
        }
        return false
    }

    private func viaAnchor(spaceID: UInt64, displayID: String, displayFrame: CGRect?) async -> Bool {
        let anchor = self.anchor ?? AnchorWindow.make()
        self.anchor = anchor
        if let displayFrame {
            let rect = CGRect(x: displayFrame.midX - 4, y: displayFrame.midY - 4, width: 8, height: 8)
            anchor.setFrame(DisplayService.appKitRect(fromQuartz: rect), display: false)
        }
        anchor.orderFrontRegardless()
        let windowID = CGWindowID(anchor.windowNumber)
        PrivateAPI.moveOwnWindow(windowID, toSpace: spaceID)
        guard SpaceService.spaces(ofWindow: windowID).contains(spaceID) else { return false }
        PrivateAPI.focus(pid: getpid(), windowID: windowID)
        NSApp.activate(ignoringOtherApps: true)
        anchor.makeKeyAndOrderFront(nil)
        return await waitForSpace(spaceID, displayID: displayID, timeout: 1.5)
    }

    private func viaDesktopShortcut(spaceID: UInt64, displayID: String, topology: SpaceTopology) async -> Bool {
        // Mission Control numbers desktops across displays; also try the per-display number in case it does not.
        var numbers: [Int] = []
        if let global = topology.globalDesktopNumber(of: spaceID) { numbers.append(global) }
        if let local = topology.space(id: spaceID)?.desktopNumber, !numbers.contains(local) { numbers.append(local) }
        for number in numbers {
            guard let hotkey = SymbolicHotkeys.desktop(number) else { continue }
            SymbolicHotkeys.post(hotkey)
            if await waitForSpace(spaceID, displayID: displayID, timeout: 1.2) { return true }
        }
        return false
    }

    private func viaArrows(spaceID: UInt64, displayID: String, displayFrame: CGRect?, topology: SpaceTopology, movePointer: Bool) async -> Bool {
        guard let display = topology.display(id: displayID),
              let target = display.spaces.firstIndex(where: { $0.id == spaceID }) else { return false }
        let originalPointer = CGEvent(source: nil)?.location
        if movePointer, let displayFrame, let pointer = originalPointer, !displayFrame.contains(pointer) {
            // Keyboard Space switching acts on the display under the pointer.
            CGWarpMouseCursorPosition(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        defer {
            if movePointer, let pointer = originalPointer, let displayFrame, !displayFrame.contains(pointer) {
                CGWarpMouseCursorPosition(pointer)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
        for _ in 0..<display.spaces.count {
            guard let current = SpaceService.currentSpace(displayID: displayID),
                  let from = display.spaces.firstIndex(where: { $0.id == current }) else { return false }
            if from == target { break }
            guard let hotkey = target > from ? SymbolicHotkeys.moveRight : SymbolicHotkeys.moveLeft else { return false }
            SymbolicHotkeys.post(hotkey)
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline, SpaceService.currentSpace(displayID: displayID) == current {
                guard await sleepUnlessCancelled(0.04) else { return false }
            }
            if SpaceService.currentSpace(displayID: displayID) == current { return false }
        }
        return await waitForSpace(spaceID, displayID: displayID, timeout: 1.0)
    }
}
