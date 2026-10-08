import CoreGraphics
import Foundation

struct RestoreOptions: Sendable {
    var restoreSpaces = true
    var minimumMatchScore = WindowMatcher.defaultMinimumScore
}

struct PlannedMove: Hashable, Sendable {
    var bundleID: String
    var appName: String
    var windowID: UInt32
    var pid: Int32
    var title: String
    var currentFrame: CGRect
    var targetFrame: CGRect
    var targetDisplayUUID: String
    var currentSpaceID: UInt64?
    /// Set only when the window has to change Space.
    var targetSpaceID: UInt64?
    var targetSpaceDisplayID: String?
    var isMinimized: Bool

    var needsFrameChange: Bool { !FrameResolver.isAtTarget(currentFrame, targetFrame) }
    var needsSpaceChange: Bool { targetSpaceID != nil }
}

/// Decides which live windows go where. Pure so it can be unit tested.
enum RestorePlanner {
    static func plan(
        saved: AppLayout,
        live: [LiveWindowState],
        displays: [DisplayInfo],
        topology: SpaceTopology?,
        sessionID: String,
        options: RestoreOptions,
        excludingSaved alreadyRestored: Set<Int> = [],
        excludingLive alreadyHandled: Set<UInt32> = []
    ) -> (moves: [PlannedMove], matched: [(savedIndex: Int, windowID: UInt32)]) {
        let savedCandidates = saved.windows.enumerated().filter { !alreadyRestored.contains($0.offset) }
        let liveCandidates = live.filter { !alreadyHandled.contains($0.descriptor.windowID) }
        let pairs = WindowMatcher.match(
            saved: savedCandidates.map(\.element),
            live: liveCandidates.map(\.descriptor),
            sessionID: sessionID,
            displays: displays,
            minimumScore: options.minimumMatchScore)

        var moves: [PlannedMove] = []
        var matched: [(Int, UInt32)] = []
        for pair in pairs {
            let savedIndex = savedCandidates[pair.savedIndex].offset
            let record = savedCandidates[pair.savedIndex].element
            let window = liveCandidates[pair.liveIndex]
            matched.append((savedIndex, window.descriptor.windowID))
            if record.isFullscreen || window.isFullscreen || record.isSplitView || window.isSplitView { continue }
            guard let (target, display) = FrameResolver.targetFrame(for: record, in: displays) else { continue }

            var targetSpace: SpaceRef?
            if options.restoreSpaces, let topology, let savedSpace = record.space,
               !record.isOnAllSpaces, !savedSpace.isFullscreen, !window.isMinimized, window.spaceIDs.count == 1,
               let resolved = topology.resolve(savedSpace),
               resolved.displayID == topology.spaceDisplayID(forDisplayUUID: display.uuid),
               !window.spaceIDs.contains(resolved.id) {
                targetSpace = resolved
            }

            let move = PlannedMove(
                bundleID: saved.bundleID,
                appName: saved.appName,
                windowID: window.descriptor.windowID,
                pid: window.descriptor.pid,
                title: window.descriptor.title,
                currentFrame: window.descriptor.frame,
                targetFrame: target,
                targetDisplayUUID: display.uuid,
                currentSpaceID: window.spaceIDs.first,
                targetSpaceID: targetSpace?.id,
                targetSpaceDisplayID: targetSpace?.displayID,
                isMinimized: window.isMinimized)
            if move.needsFrameChange || move.needsSpaceChange { moves.append(move) }
        }
        return (moves, matched)
    }

    /// Orders Space moves so each display switches Space as few times as possible:
    /// moves into the currently visible Space first, then one group per remaining target Space.
    static func spaceGroups(_ moves: [PlannedMove], topology: SpaceTopology) -> [(displayID: String, spaceID: UInt64, moves: [PlannedMove])] {
        var groups: [(String, UInt64, [PlannedMove])] = []
        let byDisplay = Dictionary(grouping: moves.filter(\.needsSpaceChange)) { $0.targetSpaceDisplayID ?? "" }
        for display in topology.displays {
            guard let displayMoves = byDisplay[display.id] else { continue }
            let bySpace = Dictionary(grouping: displayMoves) { $0.targetSpaceID ?? 0 }
            let ordered = display.spaces.map(\.id).filter { bySpace[$0] != nil }
                .sorted { ($0 == display.currentSpaceID ? 0 : 1) < ($1 == display.currentSpaceID ? 0 : 1) }
            for spaceID in ordered { groups.append((display.id, spaceID, bySpace[spaceID] ?? [])) }
        }
        return groups
    }
}
