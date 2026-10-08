import AppKit

struct TrackedApp: Hashable, Sendable {
    var pid: pid_t
    var bundleID: String
    var name: String
}

enum LayoutCapturer {
    /// Captures the window layout of `apps`. Runs on the AX queue.
    ///
    /// Windows from `previous` that are still alive in this session but could not be reached through AX
    /// (typically windows on other Spaces) are carried over with their frame and Space refreshed from the WindowServer.
    static func capture(
        apps: [TrackedApp],
        catalog: WindowCatalog,
        displays: [DisplayInfo],
        topology: SpaceTopology?,
        sessionID: String,
        previous: ConfigLayout?,
        discoverOffSpace: Bool,
        now: Date = Date()
    ) -> [String: AppLayout] {
        let cgWindows = CGWindowSnapshot.all()
        if discoverOffSpace {
            catalog.allowDiscovery(for: 2.5, visibleSpaces: Set(topology?.displays.map(\.currentSpaceID) ?? []))
        }
        var result: [String: AppLayout] = [:]
        for app in apps {
            let live = catalog.windows(pid: app.pid, cgWindows: cgWindows, discoverOffSpace: discoverOffSpace)
            let previousSameSession = (previous?.apps[app.bundleID]?.windows ?? []).filter { $0.sessionID == sessionID && $0.pid == app.pid }
            let previousByID = Dictionary(previousSameSession.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

            var records: [WindowRecord] = live.map { window in
                var space = window.spaceIDs.count == 1 ? topology?.space(id: window.spaceIDs[0]) : nil
                if window.spaceIDs.isEmpty { space = previousByID[window.windowID]?.space }
                return makeRecord(
                    windowID: window.windowID, pid: app.pid, sessionID: sessionID, title: window.title, subrole: window.subrole,
                    frame: window.frame, displays: displays, space: space, isOnAllSpaces: window.spaceIDs.count > 1,
                    isMinimized: window.isMinimized, isFullscreen: window.isFullscreen, isSplitView: window.isSplitView, order: window.order, now: now)
            }

            let liveIDs = Set(live.map(\.windowID))
            for old in previousSameSession where !liveIDs.contains(old.windowID) {
                guard let cg = cgWindows.first(where: { $0.id == old.windowID && $0.pid == app.pid }) else { continue }
                let spaceIDs = SpaceService.spaces(ofWindow: old.windowID)
                let space = spaceIDs.count == 1 ? topology?.space(id: spaceIDs[0]) ?? old.space : old.space
                records.append(makeRecord(
                    windowID: old.windowID, pid: app.pid, sessionID: sessionID, title: old.title, subrole: old.subrole,
                    frame: old.isMinimized ? old.frame : cg.bounds, displays: displays, space: space,
                    isOnAllSpaces: spaceIDs.count > 1, isMinimized: old.isMinimized, isFullscreen: old.isFullscreen, isSplitView: old.isSplitView,
                    order: old.order, now: now))
            }
            records.sort { $0.order < $1.order }
            if var existing = result[app.bundleID] {
                // Several running instances of one app share a layout.
                existing.windows += records
                result[app.bundleID] = existing
            } else {
                result[app.bundleID] = AppLayout(bundleID: app.bundleID, appName: app.name, windows: records, updatedAt: now)
            }
        }
        return result
    }

    static func makeRecord(
        windowID: CGWindowID, pid: pid_t, sessionID: String, title: String, subrole: String, frame: CGRect,
        displays: [DisplayInfo], space: SpaceRef?, isOnAllSpaces: Bool, isMinimized: Bool, isFullscreen: Bool,
        isSplitView: Bool,
        order: Int, now: Date
    ) -> WindowRecord {
        let display = FrameResolver.display(containing: frame, in: displays)
        return WindowRecord(
            windowID: windowID,
            pid: pid,
            sessionID: sessionID,
            title: title,
            subrole: subrole,
            frame: frame,
            displayUUID: display?.uuid,
            relativeFrame: display.map { FrameResolver.relativeFrame(of: frame, on: $0) },
            displaySize: display?.frame.size,
            space: space,
            isOnAllSpaces: isOnAllSpaces,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isSplitView: isSplitView,
            order: order,
            capturedAt: now)
    }

    /// Cheap fingerprint of the WindowServer state for change detection without touching AX.
    static func fingerprint(pids: Set<pid_t>) -> Int {
        var hasher = Hasher()
        // Sorted by id: the list itself is in stacking order, which changes on every focus change.
        let windows = CGWindowSnapshot.all().filter { $0.layer == 0 && pids.contains($0.pid) }.sorted { $0.id < $1.id }
        for window in windows {
            hasher.combine(window.id)
            hasher.combine(Int(window.bounds.minX))
            hasher.combine(Int(window.bounds.minY))
            hasher.combine(Int(window.bounds.width))
            hasher.combine(Int(window.bounds.height))
            hasher.combine(window.isOnScreen)
        }
        return hasher.finalize()
    }
}
