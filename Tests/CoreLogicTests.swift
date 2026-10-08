import CoreGraphics
import XCTest

enum Fixtures {
    static let main = DisplayInfo(uuid: "MAIN", name: "Main", frame: CGRect(x: 0, y: 0, width: 3008, height: 1692),
                                  visibleFrame: CGRect(x: 0, y: 31, width: 3008, height: 1661), isMain: true, isBuiltin: false)
    static let side = DisplayInfo(uuid: "SIDE", name: "Side", frame: CGRect(x: 3008, y: 0, width: 1692, height: 3008),
                                  visibleFrame: CGRect(x: 3008, y: 0, width: 1692, height: 3008), isMain: false, isBuiltin: false)

    static func space(_ id: UInt64, _ display: String, _ index: Int, fullscreen: Bool = false, desktop: Int? = nil) -> SpaceRef {
        SpaceRef(id: id, uuid: "U\(id)", displayID: display, index: index,
                 desktopNumber: fullscreen ? nil : (desktop ?? index), isFullscreen: fullscreen)
    }

    static let topology = SpaceTopology(displays: [
        .init(id: "MAIN", currentSpaceID: 7, spaces: [space(4, "MAIN", 1), space(5, "MAIN", 2), space(6, "MAIN", 3), space(7, "MAIN", 4)]),
        .init(id: "SIDE", currentSpaceID: 52, spaces: [space(52, "SIDE", 1)]),
    ])

    static func record(
        id: UInt32, pid: Int32 = 100, session: String = "S1", title: String, frame: CGRect,
        display: DisplayInfo = main, space: SpaceRef? = nil, order: Int = 0, subrole: String = "AXStandardWindow"
    ) -> WindowRecord {
        WindowRecord(
            windowID: id, pid: pid, sessionID: session, title: title, subrole: subrole, frame: frame,
            displayUUID: display.uuid, relativeFrame: frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY),
            displaySize: display.frame.size, space: space, isOnAllSpaces: false, isMinimized: false, isFullscreen: false,
            isSplitView: false,
            order: order, capturedAt: Date(timeIntervalSince1970: 0))
    }

    static func live(
        id: UInt32, pid: Int32 = 100, title: String, frame: CGRect, spaces: [UInt64] = [7], order: Int = 0,
        subrole: String = "AXStandardWindow", minimized: Bool = false
    ) -> LiveWindowState {
        LiveWindowState(
            descriptor: LiveWindowDescriptor(windowID: id, pid: pid, title: title, subrole: subrole, frame: frame, order: order),
            spaceIDs: spaces, isMinimized: minimized, isFullscreen: false, isSplitView: false)
    }
}

final class WindowMatcherTests: XCTestCase {
    func testSameSessionMatchesByIdentityEvenWhenTitlesDiffer() {
        let saved = [Fixtures.record(id: 10, title: "Inbox", frame: CGRect(x: 0, y: 0, width: 800, height: 600))]
        let live = [
            LiveWindowDescriptor(windowID: 11, pid: 100, title: "Inbox", subrole: "AXStandardWindow", frame: saved[0].frame, order: 0),
            LiveWindowDescriptor(windowID: 10, pid: 100, title: "Drafts", subrole: "AXStandardWindow", frame: .zero, order: 1),
        ]
        let pairs = WindowMatcher.match(saved: saved, live: live, sessionID: "S1", displays: [])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].liveIndex, 1)
        XCTAssertTrue(pairs[0].isIdentity)
    }

    func testAfterRestartMatchesByTitle() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let saved = [
            Fixtures.record(id: 1, title: "项目计划 - 飞书文档", frame: frame, order: 0),
            Fixtures.record(id: 2, title: "GitHub - Pull requests", frame: frame, order: 1),
        ]
        let live = [
            LiveWindowDescriptor(windowID: 90, pid: 200, title: "GitHub - Pull requests", subrole: "AXStandardWindow", frame: frame, order: 0),
            LiveWindowDescriptor(windowID: 91, pid: 200, title: "项目计划 - 飞书文档", subrole: "AXStandardWindow", frame: frame, order: 1),
        ]
        let pairs = WindowMatcher.match(saved: saved, live: live, sessionID: "S2", displays: [])
        XCTAssertEqual(pairs.map(\.liveIndex), [1, 0])
        XCTAssertFalse(pairs.contains(where: \.isIdentity))
    }

    func testSingleUntitledWindowStillMatches() {
        let saved = [Fixtures.record(id: 1, title: "", frame: CGRect(x: 0, y: 0, width: 900, height: 600))]
        let live = [LiveWindowDescriptor(windowID: 5, pid: 3, title: "", subrole: "AXStandardWindow",
                                         frame: CGRect(x: 40, y: 40, width: 900, height: 600), order: 0)]
        XCTAssertEqual(WindowMatcher.match(saved: saved, live: live, sessionID: "S9", displays: []).count, 1)
    }

    func testDifferentSubroleAndTitleDoNotMatch() {
        let saved = [Fixtures.record(id: 1, title: "Preferences", frame: CGRect(x: 0, y: 0, width: 400, height: 300))]
        let live = [LiveWindowDescriptor(windowID: 5, pid: 3, title: "Open File", subrole: "AXDialog",
                                         frame: CGRect(x: 0, y: 0, width: 1200, height: 900), order: 3)]
        XCTAssertTrue(WindowMatcher.match(saved: saved, live: live, sessionID: "S9", displays: []).isEmpty)
    }

    func testAliveSavedWindowIsNotClaimedByAnotherWindow() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let saved = [Fixtures.record(id: 10, title: "Notes", frame: frame)]
        let live = [
            LiveWindowDescriptor(windowID: 10, pid: 100, title: "Something else", subrole: "AXStandardWindow", frame: frame, order: 1),
            LiveWindowDescriptor(windowID: 12, pid: 100, title: "Notes", subrole: "AXStandardWindow", frame: frame, order: 0),
        ]
        let pairs = WindowMatcher.match(saved: saved, live: live, sessionID: "S1", displays: [])
        XCTAssertEqual(pairs.map(\.liveIndex), [0])
    }

    func testTitleNormalization() {
        XCTAssertEqual(WindowMatcher.normalizeTitle("(3) Inbox — Edited"), "inbox")
        XCTAssertEqual(WindowMatcher.normalizeTitle("  [12]  Slack  |  General "), "slack | general")
        XCTAssertEqual(WindowMatcher.normalizeTitle("● main.swift"), "main.swift")
    }

    func testSimilarityPrefersRelatedTitles() {
        let related = WindowMatcher.textSimilarity("readme.md — staywherewindowsare", "models.swift — staywherewindowsare")
        let unrelated = WindowMatcher.textSimilarity("readme.md — staywherewindowsare", "微信")
        XCTAssertGreaterThan(related, unrelated)
        XCTAssertEqual(WindowMatcher.levenshteinRatio("abc", "abc"), 1)
        XCTAssertGreaterThan(WindowMatcher.tokenOverlap("周报 草稿", "周报 定稿"), 0.3)
    }
}

final class FrameResolverTests: XCTestCase {
    func testSameDisplaySizeKeepsExactFrame() {
        let frame = CGRect(x: 3100, y: 200, width: 900, height: 1200)
        let record = Fixtures.record(id: 1, title: "x", frame: frame, display: Fixtures.side)
        // The side display moved to the left of the main one; the window follows it.
        var moved = Fixtures.side
        moved.frame.origin = CGPoint(x: -1692, y: -500)
        let result = FrameResolver.targetFrame(for: record, in: [Fixtures.main, moved])
        XCTAssertEqual(result?.display.uuid, "SIDE")
        XCTAssertEqual(result?.frame, CGRect(x: -1692 + 92, y: -500 + 200, width: 900, height: 1200))
    }

    func testResolutionChangeScalesAndClamps() {
        let record = Fixtures.record(id: 1, title: "x", frame: CGRect(x: 1504, y: 31, width: 1504, height: 1661))
        var smaller = Fixtures.main
        smaller.frame = CGRect(x: 0, y: 0, width: 1504, height: 846)
        smaller.visibleFrame = CGRect(x: 0, y: 25, width: 1504, height: 821)
        let frame = FrameResolver.targetFrame(for: record, in: [smaller])!.frame
        XCTAssertEqual(frame.minX, 752, accuracy: 1)
        XCTAssertEqual(frame.width, 752, accuracy: 1)
        XCTAssertGreaterThanOrEqual(frame.minY, 25)
        XCTAssertLessThanOrEqual(frame.maxY, 846)
    }

    func testMissingDisplayYieldsNil() {
        let record = Fixtures.record(id: 1, title: "x", frame: CGRect(x: 3100, y: 0, width: 500, height: 500), display: Fixtures.side)
        XCTAssertNil(FrameResolver.targetFrame(for: record, in: [Fixtures.main]))
    }

    func testDisplayContainingPicksLargestOverlapThenNearest() {
        let straddling = CGRect(x: 2900, y: 100, width: 600, height: 400)
        XCTAssertEqual(FrameResolver.display(containing: straddling, in: [Fixtures.main, Fixtures.side])?.uuid, "SIDE")
        let offscreen = CGRect(x: 9000, y: 100, width: 100, height: 100)
        XCTAssertEqual(FrameResolver.display(containing: offscreen, in: [Fixtures.main, Fixtures.side])?.uuid, "SIDE")
    }

    func testClampKeepsWindowInsideVisibleArea() {
        let visible = CGRect(x: 0, y: 25, width: 1000, height: 800)
        let clamped = FrameResolver.clamp(CGRect(x: 900, y: 0, width: 1200, height: 300), to: visible)
        XCTAssertEqual(clamped, CGRect(x: 0, y: 25, width: 1000, height: 300))
    }
}

final class TopologyTests: XCTestCase {
    func testResolveByUUIDThenByDesktopNumber() {
        let topology = Fixtures.topology
        XCTAssertEqual(topology.resolve(Fixtures.space(5, "MAIN", 2))?.id, 5)
        let renumbered = SpaceRef(id: 999, uuid: "gone", displayID: "MAIN", index: 3, desktopNumber: 3, isFullscreen: false)
        XCTAssertEqual(topology.resolve(renumbered)?.id, 6)
        let fullscreen = SpaceRef(id: 998, uuid: "gone-too", displayID: "MAIN", index: 2, desktopNumber: nil, isFullscreen: true)
        XCTAssertNil(topology.resolve(fullscreen))
    }

    func testGlobalDesktopNumberCountsAcrossDisplays() {
        XCTAssertEqual(Fixtures.topology.globalDesktopNumber(of: 7), 4)
        XCTAssertEqual(Fixtures.topology.globalDesktopNumber(of: 52), 5)
        XCTAssertEqual(Fixtures.topology.spaceDisplayID(forDisplayUUID: "SIDE"), "SIDE")
    }

    func testSpansDisplaysUsesSingleMainEntry() {
        let topology = SpaceTopology(displays: [.init(id: "Main", currentSpaceID: 1, spaces: [Fixtures.space(1, "Main", 1)])])
        XCTAssertTrue(topology.spansDisplays)
        XCTAssertEqual(topology.spaceDisplayID(forDisplayUUID: "ANY"), "Main")
    }
}
