import AppKit

enum AccessibilityReset {
    /// 每次请求授权前先重置旧的授权记录，这样用户只需要打开一次开关，不用先移除再加回来。
    static func resetIfNeeded() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // 静默失败：即使 tccutil 不可用，用户仍然可以手动操作
        }
    }
}