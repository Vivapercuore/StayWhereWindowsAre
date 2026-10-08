import AppKit

enum DisplayService {
    @MainActor
    static func currentDisplays() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return DisplayInfo(
                uuid: uuidString(for: displayID) ?? "display-\(displayID)",
                name: screen.localizedName,
                frame: CGDisplayBounds(displayID),
                visibleFrame: flip(screen.visibleFrame, primaryHeight: primaryHeight),
                isMain: CGDisplayIsMain(displayID) != 0,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0)
        }
    }

    static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Converts between AppKit's bottom-left screen space and Quartz's top-left space (the transform is its own inverse).
    static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    @MainActor
    static func appKitRect(fromQuartz rect: CGRect) -> NSRect {
        flip(rect, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }
}

enum SpaceService {
    static func topology() -> SpaceTopology? {
        let raw = PrivateAPI.copyManagedDisplaySpaces()
        var displays: [SpaceTopology.Display] = []
        for entry in raw {
            guard let displayID = entry["Display Identifier"] as? String,
                  let rawSpaces = entry["Spaces"] as? [[String: Any]], !rawSpaces.isEmpty else { continue }
            var spaces: [SpaceRef] = []
            var desktopNumber = 0
            for (offset, rawSpace) in rawSpaces.enumerated() {
                let id = (rawSpace["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (rawSpace["id64"] as? NSNumber)?.uint64Value ?? 0
                let isFullscreen = ((rawSpace["type"] as? NSNumber)?.intValue ?? 0) != 0
                if !isFullscreen { desktopNumber += 1 }
                spaces.append(SpaceRef(
                    id: id,
                    uuid: rawSpace["uuid"] as? String ?? "",
                    displayID: displayID,
                    index: offset + 1,
                    desktopNumber: isFullscreen ? nil : desktopNumber,
                    isFullscreen: isFullscreen))
            }
            let current = ((entry["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            displays.append(.init(id: displayID, currentSpaceID: current ?? spaces[0].id, spaces: spaces))
        }
        return displays.isEmpty ? nil : SpaceTopology(displays: displays)
    }

    static func currentSpace(displayID: String) -> UInt64? { PrivateAPI.currentSpace(displayIdentifier: displayID) }

    static func spaces(ofWindow windowID: CGWindowID) -> [UInt64] { PrivateAPI.spaces(forWindow: windowID) }

    static func spaceType(_ spaceID: UInt64) -> Int? {
        for display in PrivateAPI.copyManagedDisplaySpaces() {
            for space in (display["Spaces"] as? [[String: Any]]) ?? [] {
                if (space["ManagedSpaceID"] as? NSNumber)?.uint64Value == spaceID {
                    return (space["type"] as? NSNumber)?.intValue
                }
            }
        }
        return nil
    }

    /// 在已保存的配置中匹配当前显示器和桌面布局，缺失桌面时自动截断，
    /// 多余桌面时自动忽略"已不存在"的桌面上的窗口。
    static func layoutKey(for displays: [DisplayInfo], topology: SpaceTopology?) -> String {
        DisplayConfiguration.fullKey(for: displays, topology: topology)
    }
}

enum SessionInfo {
    /// Unique per login session; CGWindowIDs are only comparable within one session.
    static let sessionID: String = {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        return dict?["CGSSessionUniqueSessionUUID"] as? String ?? UUID().uuidString
    }()

    static var isScreenLocked: Bool {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (dict?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    static var secondsSinceLastInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
