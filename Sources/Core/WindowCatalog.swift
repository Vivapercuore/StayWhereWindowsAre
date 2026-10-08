import AppKit

struct CGWindowSnapshot: Sendable {
    var id: CGWindowID
    var pid: pid_t
    var layer: Int
    var bounds: CGRect
    var isOnScreen: Bool
    var alpha: Double
    /// Position in the global front-to-back list.
    var zIndex: Int

    static func all(onScreenOnly: Bool = false) -> [CGWindowSnapshot] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { index, info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return CGWindowSnapshot(
                id: id,
                pid: pid,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                zIndex: index)
        }
    }
}

struct LiveWindow {
    var windowID: CGWindowID
    var pid: pid_t
    var element: AXUIElement
    var title: String
    var subrole: String
    var frame: CGRect
    var isMinimized: Bool
    var isFullscreen: Bool
    var isSplitView: Bool
    var spaceIDs: [UInt64]
    var isOnScreen: Bool
    var order: Int

    var state: LiveWindowState {
        LiveWindowState(
            descriptor: LiveWindowDescriptor(windowID: windowID, pid: pid, title: title, subrole: subrole, frame: frame, order: order),
            spaceIDs: spaceIDs,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isSplitView: isSplitView)
    }
}

/// Keeps AX elements for app windows, including windows on other Spaces that `kAXWindowsAttribute` omits.
/// Not thread-safe: use only on `AXWorker.shared.queue`.
final class WindowCatalog: @unchecked Sendable {
    var allowedSubroles: Set<String> = [kAXStandardWindowSubrole]
    var offSpaceDiscoveryEnabled = true

    private var elements: [pid_t: [CGWindowID: AXUIElement]] = [:]
    /// When a complete probe of the app last finished, and which windows it was looking for.
    private var lastCompleteScan: [pid_t: (date: Date, wanted: Set<CGWindowID>)] = [:]
    /// Where an interrupted probe resumes.
    private var scanCursor: [pid_t: UInt64] = [:]
    /// Windows a complete probe could not find (panels and helper windows); not probed again.
    private var unresolvable: [pid_t: Set<CGWindowID>] = [:]
    private static let maxElementID: UInt64 = 2000
    private var discoveryDeadline = Date.distantPast
    private var visibleSpaces: Set<UInt64> = []

    private static let attributeNames = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXMinimizedAttribute, "AXFullScreen",
    ]

    /// Allows probing for off-Space windows during the next `seconds`, shared by all apps of one pass.
    func allowDiscovery(for seconds: TimeInterval, visibleSpaces: Set<UInt64>) {
        discoveryDeadline = Date().addingTimeInterval(seconds)
        self.visibleSpaces = visibleSpaces
    }

    func windows(pid: pid_t, cgWindows: [CGWindowSnapshot], discoverOffSpace: Bool) -> [LiveWindow] {
        let appElement = AXUIElementCreateApplication(pid)
        var known = elements[pid] ?? [:]
        for element in appElement.elements(kAXWindowsAttribute) {
            if let id = element.windowID { known[id] = element }
        }

        let appWindows = cgWindows.filter { $0.pid == pid && $0.layer == 0 }
        let alive = Dictionary(appWindows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        known = known.filter { alive[$0.key] != nil }

        if discoverOffSpace && offSpaceDiscoveryEnabled && PrivateAPI.canCreateRemoteElements && Date() < discoveryDeadline {
            let skip = unresolvable[pid] ?? []
            // Windows on visible Spaces are already reported by kAXWindowsAttribute; anything else that is
            // visible but unreported is a panel or helper window, not worth probing for.
            let wanted = Set(appWindows.filter { window in
                guard known[window.id] == nil, !skip.contains(window.id), !window.isOnScreen, window.alpha > 0,
                      window.bounds.width >= 100, window.bounds.height >= 80 else { return false }
                let spaces = SpaceService.spaces(ofWindow: window.id)
                return !spaces.isEmpty && spaces.allSatisfy { !visibleSpaces.contains($0) }
            }.map(\.id))
            // After a complete probe, wait a minute before probing again unless new windows showed up.
            let recentlyScanned = lastCompleteScan[pid].map {
                Date().timeIntervalSince($0.date) < 60 && wanted.isSubset(of: $0.wanted)
            } ?? false
            if !wanted.isEmpty && !recentlyScanned {
                let deadline = min(discoveryDeadline, Date().addingTimeInterval(1.0))
                let (found, complete, fromStart) = discover(pid: pid, wanted: wanted, deadline: deadline)
                known.merge(found) { current, _ in current }
                // Only a probe that covered every id in one go may conclude a window cannot be found.
                if complete && fromStart {
                    lastCompleteScan[pid] = (Date(), wanted)
                    unresolvable[pid, default: []].formUnion(wanted.subtracting(found.keys))
                }
            }
        }
        elements[pid] = known

        var result: [LiveWindow] = []
        for (id, element) in known {
            let values = element.values(Self.attributeNames)
            guard (values[kAXRoleAttribute] as? String) == kAXWindowRole,
                  let subrole = values[kAXSubroleAttribute] as? String, allowedSubroles.contains(subrole) else { continue }
            let axFrame: CGRect? = {
                guard let position = AX.point(values[kAXPositionAttribute]), let size = AX.size(values[kAXSizeAttribute]) else { return nil }
                return CGRect(origin: position, size: size)
            }()
            guard let frame = axFrame ?? alive[id]?.bounds, frame.width >= 40, frame.height >= 40 else { continue }
            let isFS = (values["AXFullScreen"] as? NSNumber)?.boolValue ?? false
            let spaceIDs = SpaceService.spaces(ofWindow: id)
            // Split View: lives on a fullscreen (type=4) space but AXFullScreen is false.
            let isSV = !isFS && !spaceIDs.isEmpty && spaceIDs.allSatisfy { s in SpaceService.spaceType(s) == 4 }
            result.append(LiveWindow(
                windowID: id,
                pid: pid,
                element: element,
                title: values[kAXTitleAttribute] as? String ?? "",
                subrole: subrole,
                frame: frame,
                isMinimized: (values[kAXMinimizedAttribute] as? NSNumber)?.boolValue ?? false,
                isFullscreen: isFS,
                isSplitView: isSV,
                spaceIDs: SpaceService.spaces(ofWindow: id),
                isOnScreen: alive[id]?.isOnScreen ?? false,
                order: alive[id]?.zIndex ?? Int.max))
        }
        result.sort { $0.order < $1.order }
        for index in result.indices { result[index].order = index }
        return result
    }

    func element(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        if let element = elements[pid]?[windowID] { return element }
        let appElement = AXUIElementCreateApplication(pid)
        for element in appElement.elements(kAXWindowsAttribute) where element.windowID == windowID {
            elements[pid, default: [:]][windowID] = element
            return element
        }
        return nil
    }

    func forget(pid: pid_t) {
        elements[pid] = nil
        lastCompleteScan[pid] = nil
        scanCursor[pid] = nil
        unresolvable[pid] = nil
    }

    func prune(alive pids: Set<pid_t>) {
        for pid in Set(elements.keys).union(unresolvable.keys) where !pids.contains(pid) { forget(pid: pid) }
    }

    /// Finds window elements by probing element ids, which also reaches windows on other Spaces.
    /// A probe cut short by the deadline resumes where it stopped on the next call; `complete` is true once
    /// every wanted window was found or every id was tried.
    private func discover(pid: pid_t, wanted: Set<CGWindowID>, deadline: Date)
        -> (found: [CGWindowID: AXUIElement], complete: Bool, fromStart: Bool) {
        var found: [CGWindowID: AXUIElement] = [:]
        let start = scanCursor[pid] ?? 0
        var elementID = start
        while elementID < Self.maxElementID {
            if found.count == wanted.count { break }
            if Date() > deadline {
                scanCursor[pid] = elementID
                return (found, false, start == 0)
            }
            if let element = PrivateAPI.remoteElement(pid: pid, elementID: elementID),
               element.string(kAXRoleAttribute) == kAXWindowRole,
               let id = element.windowID, wanted.contains(id) {
                found[id] = element
            }
            elementID += 1
        }
        scanCursor[pid] = nil
        return (found, true, start == 0)
    }
}
