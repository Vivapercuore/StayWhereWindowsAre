import AppKit

/// Frame changes through Accessibility. Call only on the AX queue.
enum WindowMover {
    /// Sets size, position, then size again: the first resize lets a window fit on a smaller destination display,
    /// the second applies the exact size once the window sits on its target display.
    @discardableResult
    static func setFrame(_ element: AXUIElement, pid: pid_t, frame: CGRect) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        // With enhanced UI on (set by assistive apps), many apps animate every frame change and drop later ones.
        let enhanced = app.bool("AXEnhancedUserInterface") == true
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) } }
        element.setSize(frame.size)
        element.setPosition(frame.origin)
        element.setSize(frame.size)
        return element.frame
    }

    static func isAcceptable(_ actual: CGRect?, target: CGRect) -> Bool {
        guard let actual else { return false }
        return FrameResolver.isAtTarget(actual, target)
    }

    /// Moves a window to the visible Space of its target display by parking it on another display first:
    /// a window that arrives on a display always joins that display's visible Space.
    static func hop(_ element: AXUIElement, pid: pid_t, windowID: CGWindowID, parking: CGRect, target: CGRect, expectedSpace: UInt64) -> Bool {
        let before = SpaceService.spaces(ofWindow: windowID)
        setFrame(element, pid: pid, frame: parking)
        if !waitUntil(timeout: 0.6, { SpaceService.spaces(ofWindow: windowID) != before }) { return false }
        setFrame(element, pid: pid, frame: target)
        return waitUntil(timeout: 0.6) { SpaceService.spaces(ofWindow: windowID) == [expectedSpace] }
    }

    static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            usleep(30_000)
        } while Date() < deadline
        return condition()
    }
}

/// Last resort when there is no second display to hop through: grab the window by its title bar and switch Space
/// while holding it, which is how a person would carry a window to another desktop.
@MainActor
final class WindowDragger {
    let switcher: SpaceSwitcher
    let catalog: WindowCatalog
    var log: ((String) -> Void)?

    init(switcher: SpaceSwitcher, catalog: WindowCatalog) {
        self.switcher = switcher
        self.catalog = catalog
    }

    func drag(_ move: PlannedMove, display: DisplayInfo, topology: SpaceTopology) async -> Bool {
        guard let targetSpace = move.targetSpaceID, let displayID = move.targetSpaceDisplayID else { return false }
        let catalog = self.catalog
        let pid = move.pid, windowID = move.windowID

        // Bring the window forward; this also switches to its Space when it is not visible.
        await AXWorker.shared.run { _ = catalog.element(pid: pid, windowID: windowID)?.perform(kAXRaiseAction) }
        PrivateAPI.focus(pid: pid, windowID: windowID)
        let visible = await poll(timeout: 1.5) {
            CGWindowSnapshot.all(onScreenOnly: true).contains { $0.id == windowID }
        }
        guard visible else { log?("拖拽：窗口未能显示到前台"); return false }

        let geometry: (frame: CGRect, close: CGRect?)? = await AXWorker.shared.run {
            guard let element = catalog.element(pid: pid, windowID: windowID), let frame = element.frame else { return nil }
            return (frame, element.element(kAXCloseButtonAttribute)?.frame)
        }
        guard let geometry, let close = geometry.close, close.width > 0 else { log?("拖拽：找不到标题栏按钮"); return false }
        let frame = geometry.frame
        let grab = CGPoint(x: frame.minX + max(3, (close.minX - frame.minX) / 2), y: close.midY)
        guard topWindow(at: grab) == windowID else { log?("拖拽：抓取点被其他窗口遮挡"); return false }
        guard await waitForUserIdle() else { log?("拖拽：用户正在操作，已跳过"); return false }

        let original = CGEvent(source: nil)?.location
        // Once the button is down it must be released, so these waits ignore cancellation.
        post(.mouseMoved, at: grab)
        usleep(40_000)
        post(.leftMouseDown, at: grab)
        usleep(80_000)
        for step in 1...4 {
            post(.leftMouseDragged, at: CGPoint(x: grab.x + CGFloat(step * 2), y: grab.y))
            usleep(20_000)
        }
        let switched = await switcher.switchTo(
            spaceID: targetSpace, displayID: displayID, displayFrame: display.frame, topology: topology,
            allowAnchor: false, movePointer: false) != nil
        let release = CGPoint(x: grab.x + 8, y: grab.y)
        post(.leftMouseDragged, at: release)
        usleep(60_000)
        post(.leftMouseUp, at: release)
        if let original { CGWarpMouseCursorPosition(original); CGAssociateMouseAndMouseCursorPosition(1) }
        guard switched else { return false }
        return await poll(timeout: 1.0) { SpaceService.spaces(ofWindow: windowID) == [targetSpace] }
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    /// The front-most window under a point, ignoring our own windows.
    private func topWindow(at point: CGPoint) -> CGWindowID? {
        let ownPID = getpid()
        return CGWindowSnapshot.all(onScreenOnly: true).first {
            $0.pid != ownPID && $0.alpha > 0.01 && $0.layer < 1000 && $0.bounds.contains(point)
        }?.id
    }

    private func waitForUserIdle() async -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if SessionInfo.secondsSinceLastInput > 0.6 { return true }
            guard await sleepUnlessCancelled(0.15) else { return false }
        }
        return false
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            guard await sleepUnlessCancelled(0.05) else { break }
        }
        return condition()
    }
}
