import CoreGraphics
import Foundation

// All frames use global Quartz coordinates: origin at the top-left corner of the primary display,
// y grows downward. This is the coordinate space of both the Accessibility API and CGWindowList.

struct DisplayInfo: Codable, Hashable, Identifiable, Sendable {
    var uuid: String
    var name: String
    var frame: CGRect
    var visibleFrame: CGRect
    var isMain: Bool
    var isBuiltin: Bool

    var id: String { uuid }
}

struct DisplayConfiguration: Codable, Hashable, Sendable {
    var displays: [DisplayInfo]

    static func key(for uuids: [String]) -> String { uuids.sorted().joined(separator: "+") }

    var key: String { Self.key(for: displays.map(\.uuid)) }

    /// Changes when displays are rearranged or change resolution even if the set of displays is the same.
    var arrangementSignature: String {
        displays.sorted { $0.uuid < $1.uuid }
            .map { "\($0.uuid)@\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))x\(Int($0.frame.height))" }
            .joined(separator: ";")
    }

    func display(uuid: String) -> DisplayInfo? { displays.first { $0.uuid == uuid } }

    var summary: String { Self.summary(of: displays) }

    static func summary(of displays: [DisplayInfo]) -> String {
        displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            .map(\.name).joined(separator: " + ")
    }
}

struct SpaceRef: Codable, Hashable, Sendable {
    /// ManagedSpaceID. Only stable while the WindowServer session lives; `uuid` survives reboots.
    var id: UInt64
    var uuid: String
    /// WindowServer "Display Identifier": the display UUID, or "Main" when Spaces span all displays.
    var displayID: String
    /// 1-based position among all Spaces of the display, in Mission Control order.
    var index: Int
    /// 1-based position among regular desktops of the display (full-screen Spaces excluded).
    var desktopNumber: Int?
    var isFullscreen: Bool
}

struct SpaceTopology: Codable, Hashable, Sendable {
    struct Display: Codable, Hashable, Sendable {
        var id: String
        var currentSpaceID: UInt64
        var spaces: [SpaceRef]
    }

    var displays: [Display]

    var spansDisplays: Bool { displays.count == 1 && displays[0].id == "Main" }

    func space(id: UInt64) -> SpaceRef? {
        for display in displays { if let s = display.spaces.first(where: { $0.id == id }) { return s } }
        return nil
    }

    func display(id: String) -> Display? { displays.first { $0.id == id } }

    func currentSpace(displayID: String) -> UInt64? { display(id: displayID)?.currentSpaceID }

    /// The WindowServer display identifier that owns Spaces for the given physical display.
    func spaceDisplayID(forDisplayUUID uuid: String) -> String? {
        if spansDisplays { return displays.first?.id }
        return display(id: uuid)?.id
    }

    /// Finds the live Space matching a saved one: by persistent uuid first, then by desktop number on the same display.
    func resolve(_ saved: SpaceRef) -> SpaceRef? {
        if !saved.uuid.isEmpty, let match = displays.lazy.flatMap(\.spaces).first(where: { $0.uuid == saved.uuid }) {
            return match
        }
        guard !saved.isFullscreen, let number = saved.desktopNumber else { return nil }
        let displayID = spansDisplays ? displays.first?.id : saved.displayID
        return displays.first { $0.id == displayID }?.spaces.first { $0.desktopNumber == number }
    }

    /// Mission Control "Desktop N" number counted across displays, as used by the "Switch to Desktop N" shortcuts.
    func globalDesktopNumber(of spaceID: UInt64) -> Int? {
        var count = 0
        for display in displays {
            for space in display.spaces where !space.isFullscreen {
                count += 1
                if space.id == spaceID { return count }
            }
        }
        return nil
    }

    var totalDesktopCount: Int { displays.reduce(0) { $0 + $1.spaces.filter { !$0.isFullscreen }.count } }
}

struct WindowRecord: Codable, Hashable, Sendable {
    var windowID: UInt32
    var pid: Int32
    /// Login-session identifier at capture time; window ids are only meaningful within one session.
    var sessionID: String
    var title: String
    var subrole: String
    var frame: CGRect
    var displayUUID: String?
    /// Frame relative to the display's top-left corner.
    var relativeFrame: CGRect?
    var displaySize: CGSize?
    var space: SpaceRef?
    var isOnAllSpaces: Bool
    var isMinimized: Bool
    var isFullscreen: Bool
    var isSplitView: Bool
    var order: Int
    var capturedAt: Date

    /// Compares the parts of a record that matter for restoring, ignoring timestamps.
    func isEquivalent(to other: WindowRecord) -> Bool {
        windowID == other.windowID && sessionID == other.sessionID && title == other.title
            && frame.integral == other.frame.integral && displayUUID == other.displayUUID
            && space?.uuid == other.space?.uuid && space?.id == other.space?.id
            && isMinimized == other.isMinimized && isFullscreen == other.isFullscreen && isOnAllSpaces == other.isOnAllSpaces
    }
}

struct AppLayout: Codable, Hashable, Sendable {
    var bundleID: String
    var appName: String
    var windows: [WindowRecord]
    var updatedAt: Date

    /// Ignores stacking order, which changes every time the user switches between the app's windows.
    func isEquivalent(to other: AppLayout) -> Bool {
        guard windows.count == other.windows.count else { return false }
        let byIdentity: (WindowRecord, WindowRecord) -> Bool = { ($0.sessionID, $0.windowID) < ($1.sessionID, $1.windowID) }
        return zip(windows.sorted(by: byIdentity), other.windows.sorted(by: byIdentity)).allSatisfy { $0.isEquivalent(to: $1) }
    }
}

struct ConfigLayout: Codable, Sendable, Identifiable {
    var key: String
    var displays: [DisplayInfo]
    var apps: [String: AppLayout]
    var createdAt: Date
    var updatedAt: Date

    var id: String { key }
    var windowCount: Int { apps.values.reduce(0) { $0 + $1.windows.count } }
    var summary: String { DisplayConfiguration.summary(of: displays) }
}

enum SnapshotKind: String, Codable, Sendable {
    case automatic
    case manual
    case beforeRestore
}

struct LayoutSnapshot: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: SnapshotKind
    var createdAt: Date
    var configKey: String
    var displays: [DisplayInfo]
    var apps: [String: AppLayout]

    var windowCount: Int { apps.values.reduce(0) { $0 + $1.windows.count } }
    var summary: String { DisplayConfiguration.summary(of: displays) }
}

/// The part of a live window the matcher needs.
struct LiveWindowDescriptor: Hashable, Sendable {
    var windowID: UInt32
    var pid: Int32
    var title: String
    var subrole: String
    var frame: CGRect
    var order: Int
    var displayUUID: String?
}

/// A live window as the restore planner sees it.
struct LiveWindowState: Hashable, Sendable {
    var descriptor: LiveWindowDescriptor
    var spaceIDs: [UInt64]
    var isMinimized: Bool
    var isFullscreen: Bool
    var isSplitView: Bool
}
