import CoreGraphics
import XCTest

final class RestorePlannerTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 700)

    private func layout(_ records: [WindowRecord]) -> AppLayout {
        AppLayout(bundleID: "com.example.app", appName: "Example", windows: records, updatedAt: Date())
    }

    func testWindowAlreadyInPlaceNeedsNoMove() {
        let saved = layout([Fixtures.record(id: 1, title: "Doc", frame: frame, space: Fixtures.space(7, "MAIN", 4))])
        let live = [Fixtures.live(id: 1, title: "Doc", frame: frame, spaces: [7])]
        let plan = RestorePlanner.plan(saved: saved, live: live, displays: [Fixtures.main, Fixtures.side],
                                       topology: Fixtures.topology, sessionID: "S1", options: RestoreOptions())
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.matched.count, 1)
    }

    func testMovedWindowOnWrongSpaceGetsFrameAndSpace() {
        let saved = layout([Fixtures.record(id: 1, title: "Doc", frame: frame, space: Fixtures.space(5, "MAIN", 2))])
        let live = [Fixtures.live(id: 1, title: "Doc", frame: CGRect(x: 3100, y: 50, width: 800, height: 600), spaces: [52])]
        let plan = RestorePlanner.plan(saved: saved, live: live, displays: [Fixtures.main, Fixtures.side],
                                       topology: Fixtures.topology, sessionID: "S1", options: RestoreOptions())
        XCTAssertEqual(plan.moves.count, 1)
        let move = plan.moves[0]
        XCTAssertEqual(move.targetFrame, frame)
        XCTAssertEqual(move.targetSpaceID, 5)
        XCTAssertEqual(move.targetSpaceDisplayID, "MAIN")
        XCTAssertTrue(move.needsFrameChange)
    }

    func testSpacesCanBeTurnedOff() {
        let saved = layout([Fixtures.record(id: 1, title: "Doc", frame: frame, space: Fixtures.space(5, "MAIN", 2))])
        let live = [Fixtures.live(id: 1, title: "Doc", frame: frame, spaces: [7])]
        var options = RestoreOptions()
        options.restoreSpaces = false
        let plan = RestorePlanner.plan(saved: saved, live: live, displays: [Fixtures.main], topology: Fixtures.topology,
                                       sessionID: "S1", options: options)
        XCTAssertTrue(plan.moves.isEmpty)
    }

    func testMinimizedAndStickyWindowsKeepTheirSpace() {
        var sticky = Fixtures.record(id: 2, title: "Sticky", frame: frame, space: Fixtures.space(5, "MAIN", 2))
        sticky.isOnAllSpaces = true
        let saved = layout([Fixtures.record(id: 1, title: "Mini", frame: frame, space: Fixtures.space(5, "MAIN", 2)), sticky])
        let live = [
            Fixtures.live(id: 1, title: "Mini", frame: frame, spaces: [7], minimized: true),
            Fixtures.live(id: 2, title: "Sticky", frame: frame, spaces: [4, 5, 6, 7], order: 1),
        ]
        let plan = RestorePlanner.plan(saved: saved, live: live, displays: [Fixtures.main], topology: Fixtures.topology,
                                       sessionID: "S1", options: RestoreOptions())
        XCTAssertTrue(plan.moves.isEmpty)
    }

    func testExclusionsSkipAlreadyHandledWindows() {
        let saved = layout([
            Fixtures.record(id: 1, title: "A", frame: frame, order: 0),
            Fixtures.record(id: 2, title: "B", frame: frame, order: 1),
        ])
        let live = [
            Fixtures.live(id: 30, title: "A", frame: .init(x: 0, y: 0, width: 1000, height: 700)),
            Fixtures.live(id: 31, title: "B", frame: .init(x: 0, y: 0, width: 1000, height: 700), order: 1),
        ]
        let plan = RestorePlanner.plan(saved: saved, live: live, displays: [Fixtures.main], topology: nil, sessionID: "S2",
                                       options: RestoreOptions(), excludingSaved: [0], excludingLive: [30])
        XCTAssertEqual(plan.matched.map(\.savedIndex), [1])
        XCTAssertEqual(plan.moves.map(\.windowID), [31])
    }

    func testSpaceGroupsVisitVisibleSpaceFirst() {
        func move(_ id: UInt32, space: UInt64, display: String) -> PlannedMove {
            PlannedMove(bundleID: "b", appName: "b", windowID: id, pid: 1, title: "", currentFrame: .zero, targetFrame: .zero,
                        targetDisplayUUID: display, currentSpaceID: nil, targetSpaceID: space, targetSpaceDisplayID: display, isMinimized: false)
        }
        let groups = RestorePlanner.spaceGroups(
            [move(1, space: 5, display: "MAIN"), move(2, space: 7, display: "MAIN"), move(3, space: 52, display: "SIDE"), move(4, space: 5, display: "MAIN")],
            topology: Fixtures.topology)
        XCTAssertEqual(groups.map(\.spaceID), [7, 5, 52])
        XCTAssertEqual(groups[1].moves.map(\.windowID), [1, 4])
    }
}

@MainActor
final class LayoutStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("swwa-tests-\(UUID().uuidString)/layouts.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func app(_ bundleID: String, _ windows: [WindowRecord], at date: Date = Date()) -> AppLayout {
        AppLayout(bundleID: bundleID, appName: bundleID, windows: windows, updatedAt: date)
    }

    func testMergeRespectsFrozenAppsAndEmptyCaptures() {
        let store = LayoutStore(fileURL: url)
        let original = Fixtures.record(id: 1, title: "A", frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        store.merge(configKey: "K", displays: [Fixtures.main], captured: ["a": app("a", [original]), "b": app("b", [original])], frozen: [])

        var moved = original
        moved.frame = CGRect(x: 900, y: 900, width: 500, height: 500)
        store.merge(configKey: "K", displays: [Fixtures.main],
                    captured: ["a": app("a", [moved]), "b": app("b", [])], frozen: ["a"])
        XCTAssertEqual(store.layout(for: "K")?.apps["a"]?.windows.first?.frame, original.frame, "frozen app keeps its layout")
        XCTAssertEqual(store.layout(for: "K")?.apps["b"]?.windows.count, 1, "app without windows keeps its last layout")
    }

    func testEquivalentCaptureDoesNotCountAsChange() {
        let store = LayoutStore(fileURL: url)
        let record = Fixtures.record(id: 1, title: "A", frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        XCTAssertTrue(store.merge(configKey: "K", displays: [Fixtures.main], captured: ["a": app("a", [record])], frozen: []))
        var later = record
        later.capturedAt = Date()
        XCTAssertFalse(store.merge(configKey: "K", displays: [Fixtures.main], captured: ["a": app("a", [later])], frozen: []))
    }

    func testStaleAppsArePruned() {
        let store = LayoutStore(fileURL: url)
        let record = Fixtures.record(id: 1, title: "A", frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        let old = Date().addingTimeInterval(-200 * 24 * 3600)
        store.merge(configKey: "K", displays: [Fixtures.main], captured: ["old": app("old", [record], at: old)], frozen: [], now: old)
        store.merge(configKey: "K", displays: [Fixtures.main], captured: ["new": app("new", [record])], frozen: [])
        XCTAssertNil(store.layout(for: "K")?.apps["old"])
        XCTAssertNotNil(store.layout(for: "K")?.apps["new"])
    }

    func testPersistenceRoundTripAndHistoryLimits() {
        let store = LayoutStore(fileURL: url)
        store.maxAutomaticSnapshots = 2
        let record = Fixtures.record(id: 1, title: "A", frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        store.merge(configKey: "K", displays: [Fixtures.main], captured: ["a": app("a", [record])], frozen: [])
        let config = store.layout(for: "K")!
        XCTAssertTrue(store.addAutomaticSnapshotIfChanged(from: config))
        XCTAssertFalse(store.addAutomaticSnapshotIfChanged(from: config), "unchanged layout is not snapshotted twice")
        for index in 0..<3 {
            var changed = config
            changed.apps["a"]?.windows[0].frame.origin.x = CGFloat(100 * (index + 1))
            store.addAutomaticSnapshotIfChanged(from: changed)
        }
        store.addSnapshot(LayoutSnapshot(id: UUID(), name: "Mine", kind: .manual, createdAt: Date(), configKey: "K",
                                         displays: config.displays, apps: config.apps))
        XCTAssertEqual(store.history.filter { $0.kind == .automatic }.count, 2)
        XCTAssertEqual(store.history.filter { $0.kind == .manual }.count, 1)
        store.saveNow()

        let reloaded = LayoutStore(fileURL: url)
        reloaded.load()
        XCTAssertEqual(reloaded.layout(for: "K")?.apps["a"]?.windows.first?.title, "A")
        XCTAssertEqual(reloaded.history.count, 3)
        XCTAssertEqual(reloaded.knownApps.map(\.bundleID), ["a"])
    }

    func testCorruptFileIsSetAside() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = LayoutStore(fileURL: url)
        var message: String?
        store.onError = { message = $0 }
        store.load()
        XCTAssertNotNil(message)
        XCTAssertTrue(store.configs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

final class ReviewRegressionTests: XCTestCase {
    func testGridRoundedWindowIsNotMovedAgain() {
        let target = CGRect(x: 100, y: 100, width: 800, height: 600)
        let saved = AppLayout(bundleID: "term", appName: "Terminal",
                              windows: [Fixtures.record(id: 1, title: "zsh", frame: target)], updatedAt: Date())
        // The terminal snapped the height to its character grid after the last restore.
        let live = [Fixtures.live(id: 1, title: "zsh", frame: CGRect(x: 100, y: 100, width: 801, height: 589))]
        let plan = RestorePlanner.plan(saved: saved, live: live, displays: [Fixtures.main], topology: nil,
                                       sessionID: "S1", options: RestoreOptions())
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertFalse(FrameResolver.isAtTarget(CGRect(x: 120, y: 100, width: 800, height: 600), target))
    }

    func testStackingOrderDoesNotChangeEquivalence() {
        let a = Fixtures.record(id: 1, title: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300), order: 0)
        let b = Fixtures.record(id: 2, title: "B", frame: CGRect(x: 50, y: 50, width: 400, height: 300), order: 1)
        let first = AppLayout(bundleID: "x", appName: "x", windows: [a, b], updatedAt: Date())
        let swapped = AppLayout(bundleID: "x", appName: "x", windows: [b, a], updatedAt: Date())
        XCTAssertTrue(first.isEquivalent(to: swapped))
        var moved = b
        moved.frame.origin.x = 300
        XCTAssertFalse(first.isEquivalent(to: AppLayout(bundleID: "x", appName: "x", windows: [moved, a], updatedAt: Date())))
    }

    @MainActor
    func testHistoryIsStoredInItsOwnFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swwa-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(fileURL: directory.appendingPathComponent("layouts.json"))
        store.addSnapshot(LayoutSnapshot(id: UUID(), name: "s", kind: .manual, createdAt: Date(), configKey: "K",
                                         displays: [Fixtures.main], apps: [:]))
        store.saveNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.historyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "layouts untouched when only history changed")
    }
}
