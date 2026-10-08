import AppKit

struct RestoreReport: Sendable {
    var planned = 0
    var moved = 0
    var spaceMoved = 0
    var spaceFailed = 0
    var failed = 0

    mutating func add(_ other: RestoreReport) {
        planned += other.planned
        moved += other.moved
        spaceMoved += other.spaceMoved
        spaceFailed += other.spaceFailed
        failed += other.failed
    }

    var summary: String {
        var parts = ["移动 \(moved) 个窗口"]
        if spaceMoved > 0 { parts.append("\(spaceMoved) 个回到原桌面") }
        if spaceFailed > 0 { parts.append("\(spaceFailed) 个未能切换桌面") }
        if failed > 0 { parts.append("\(failed) 个失败") }
        return parts.joined(separator: "，")
    }
}

/// Carries out planned moves. Space changes are grouped per display so each display switches as rarely as possible,
/// and every step is verified against the WindowServer before moving on.
@MainActor
final class RestoreEngine {
    let catalog: WindowCatalog
    let switcher: SpaceSwitcher
    let dragger: WindowDragger
    var allowDrag = true
    var log: ((String) -> Void)?

    init(catalog: WindowCatalog, switcher: SpaceSwitcher) {
        self.catalog = catalog
        self.switcher = switcher
        self.dragger = WindowDragger(switcher: switcher, catalog: catalog)
    }

    func execute(_ moves: [PlannedMove], displays: [DisplayInfo], topology: SpaceTopology?) async -> RestoreReport {
        var report = RestoreReport(planned: moves.count)
        for move in moves where !move.needsSpaceChange || topology == nil {
            if await applyFrame(move) { report.moved += 1 } else { report.failed += 1 }
        }
        let spaceMoves = moves.filter(\.needsSpaceChange)
        guard let topology, !spaceMoves.isEmpty else { return report }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let originalSpaces = topology.displays.map { ($0.id, SpaceService.currentSpace(displayID: $0.id) ?? $0.currentSpaceID) }
        let canHop = !topology.spansDisplays && displays.count > 1
        var dragQueue: [PlannedMove] = []

        for group in RestorePlanner.spaceGroups(spaceMoves, topology: topology) {
            let targetDisplay = displays.first { $0.uuid == group.moves[0].targetDisplayUUID }
            let switched = await switcher.switchTo(
                spaceID: group.spaceID, displayID: group.displayID, displayFrame: targetDisplay?.frame, topology: topology) != nil
            for move in group.moves {
                let current = SpaceService.spaces(ofWindow: move.windowID)
                if current == [group.spaceID] {
                    count(await applyFrame(move), into: &report, spaceMoved: true)
                    continue
                }
                guard switched else {
                    // Still put the window on the right display and position, just not the right desktop.
                    _ = await applyFrame(move)
                    report.spaceFailed += 1
                    continue
                }
                let currentDisplayID = current.first.flatMap { topology.space(id: $0)?.displayID }
                if currentDisplayID != group.displayID && !topology.spansDisplays {
                    // Arriving from another display: it joins the visible Space, which is now the target.
                    let framed = await applyFrame(move)
                    let landed = await waitForSpace(move.windowID, group.spaceID)
                    count(framed, into: &report, spaceMoved: landed)
                } else if canHop, let parkingDisplay = displays.first(where: { $0.uuid != move.targetDisplayUUID }) {
                    let landed = await hop(move, via: parkingDisplay, expectedSpace: group.spaceID)
                    let framed: Bool
                    if landed { framed = await applyFrameMatches(move) } else { framed = await applyFrame(move) }
                    count(framed, into: &report, spaceMoved: landed)
                } else if allowDrag {
                    dragQueue.append(move)
                } else {
                    _ = await applyFrame(move)
                    report.spaceFailed += 1
                }
            }
        }

        for move in dragQueue {
            guard let display = displays.first(where: { $0.uuid == move.targetDisplayUUID }) else { continue }
            let landed = await dragger.drag(move, display: display, topology: topology)
            count(await applyFrame(move), into: &report, spaceMoved: landed)
        }

        for (displayID, spaceID) in originalSpaces where SpaceService.currentSpace(displayID: displayID) != spaceID {
            let frame = displays.first { topology.spaceDisplayID(forDisplayUUID: $0.uuid) == displayID }?.frame
            await switcher.switchTo(spaceID: spaceID, displayID: displayID, displayFrame: frame, topology: topology)
        }
        switcher.finish(reactivating: frontApp)
        return report
    }

    private func count(_ framed: Bool, into report: inout RestoreReport, spaceMoved: Bool) {
        if spaceMoved { report.spaceMoved += 1 } else { report.spaceFailed += 1 }
        if framed { report.moved += 1 } else { report.failed += 1 }
    }

    func applyFrame(_ move: PlannedMove) async -> Bool {
        let catalog = self.catalog
        return await AXWorker.shared.run {
            guard let element = catalog.element(pid: move.pid, windowID: move.windowID) else { return false }
            var actual = WindowMover.setFrame(element, pid: move.pid, frame: move.targetFrame)
            if !WindowMover.isAcceptable(actual, target: move.targetFrame) {
                usleep(150_000)
                actual = WindowMover.setFrame(element, pid: move.pid, frame: move.targetFrame)
            }
            return WindowMover.isAcceptable(actual, target: move.targetFrame)
        }
    }

    private func applyFrameMatches(_ move: PlannedMove) async -> Bool {
        let catalog = self.catalog
        return await AXWorker.shared.run {
            WindowMover.isAcceptable(catalog.element(pid: move.pid, windowID: move.windowID)?.frame, target: move.targetFrame)
        }
    }

    private func hop(_ move: PlannedMove, via display: DisplayInfo, expectedSpace: UInt64) async -> Bool {
        let catalog = self.catalog
        let parking = FrameResolver.parkingFrame(for: move.targetFrame.size, on: display)
        return await AXWorker.shared.run {
            guard let element = catalog.element(pid: move.pid, windowID: move.windowID) else { return false }
            return WindowMover.hop(element, pid: move.pid, windowID: move.windowID, parking: parking,
                                   target: move.targetFrame, expectedSpace: expectedSpace)
        }
    }

    private func waitForSpace(_ windowID: CGWindowID, _ spaceID: UInt64) async -> Bool {
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            if SpaceService.spaces(ofWindow: windowID) == [spaceID] { return true }
            guard await sleepUnlessCancelled(0.04) else { break }
        }
        return SpaceService.spaces(ofWindow: windowID) == [spaceID]
    }
}
