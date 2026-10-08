// 新的 display configuration key：按排列区分，含桌面数量
import CoreGraphics
import Foundation

extension DisplayConfiguration {
    /// 键现在包含：显示器 UUID 列表 + 物理排列 + 每台显示器的桌面数
    /// 这样“内置+外接左右排列 3 桌面”和“内置+外接上下排列 2 桌面”是不同的布局方案。
    static func fullKey(for displays: [DisplayInfo], topology: SpaceTopology?) -> String {
        let uuidKey = key(for: displays.map(\.uuid))
        let arrangement = arrangementSignature(for: displays)
        let desktops = topologySignature(for: displays, topology: topology)
        return [uuidKey, arrangement, desktops].filter { !$0.isEmpty }.joined(separator: "|")
    }

    static func arrangementSignature(for displays: [DisplayInfo]) -> String {
        displays.sorted { $0.uuid < $1.uuid }
            .map { "\($0.uuid)@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
            .joined(separator: ";")
    }

    static func topologySignature(for displays: [DisplayInfo], topology: SpaceTopology?) -> String {
        guard let topology else { return "" }
        let parts: [String] = displays.compactMap { display in
            guard let spaceDisplayID = topology.spaceDisplayID(forDisplayUUID: display.uuid),
                  let displaySpaces = topology.display(id: spaceDisplayID) else { return nil }
            let desktopCount = displaySpaces.spaces.filter { !$0.isFullscreen }.count
            let fullscreenCount = displaySpaces.spaces.filter(\.isFullscreen).count
            return "\(display.uuid):d\(desktopCount)f\(fullscreenCount)"
        }
        return parts.sorted().joined(separator: ";")
    }

    /// 在所有已保存的配置中找最接近的：先匹配 uuid 集，再匹配排列，最后匹配桌面数
    static func bestMatch(for key: String, in configs: [String: ConfigLayout]) -> ConfigLayout? {
        if let exact = configs[key] { return exact }
        let uuidPart = key.components(separatedBy: "|").first ?? key
        let matchingUUIDs = configs
            .filter { $0.key.hasPrefix(uuidPart) }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
        return matchingUUIDs.first?.value
    }
}