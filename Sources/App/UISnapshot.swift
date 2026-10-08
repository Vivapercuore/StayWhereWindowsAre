#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: renders the menu bar panel and every settings page to PNG files for visual review.
/// Usage: StayWhereWindowsAre --snapshot-ui <output-dir>
@MainActor
enum UISnapshot {
    static func run(outputDirectory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "StayWhereWindowsAre.snapshot")!
        defaults.removePersistentDomain(forName: "StayWhereWindowsAre.snapshot")
        let store = LayoutStore(fileURL: output.appendingPathComponent("layouts.json"))
        let model = AppModel(settings: AppSettings(defaults: defaults), store: store, log: ActivityLog(fileURL: output.appendingPathComponent("snapshot.log")))
        model.refreshDisplays()
        populate(model)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let navigation = SettingsNavigation()
            for page in SettingsPage.allCases {
                navigation.selection = page
                render(SettingsRootView(model: model, navigation: navigation), size: NSSize(width: 880, height: 620),
                       appearance: appearance, to: output.appendingPathComponent("settings-\(page.rawValue)-\(suffix).png"))
            }
            render(MenuBarPanel(model: model).background(.background), size: NSSize(width: 340, height: 520),
                   appearance: appearance, to: output.appendingPathComponent("menubar-\(suffix).png"))
        }
        print("UI snapshots written to \(output.path)")
        exit(0)
    }

    private static func populate(_ model: AppModel) {
        let displays = model.displays
        guard let main = displays.first else { return }
        let session = SessionInfo.sessionID
        let topology = model.topology
        let samples: [(String, String, [String])] = [
            ("com.google.Chrome", "Google Chrome", ["GitHub · Pull requests", "飞书文档 - 项目计划"]),
            ("com.apple.Safari", "Safari", ["Apple Developer Documentation"]),
            ("com.googlecode.iterm2", "iTerm2", ["~/code/self/StayWhereWindowsAre"]),
            ("com.apple.finder", "访达", ["下载", "应用程序"]),
        ]
        var apps: [String: AppLayout] = [:]
        var order = 0
        for (index, sample) in samples.enumerated() {
            let display = displays[index % displays.count]
            let windows = sample.2.enumerated().map { offset, title -> WindowRecord in
                order += 1
                let frame = CGRect(x: display.visibleFrame.minX + CGFloat(60 + offset * 80), y: display.visibleFrame.minY + CGFloat(40 + offset * 60),
                                   width: min(1200, display.visibleFrame.width - 120), height: min(800, display.visibleFrame.height - 120))
                let space = topology?.display(id: topology?.spaceDisplayID(forDisplayUUID: display.uuid) ?? "")?.spaces.first
                return LayoutCapturer.makeRecord(
                    windowID: UInt32(1000 + order), pid: 1, sessionID: session, title: title, subrole: "AXStandardWindow",
                    frame: frame, displays: displays, space: space, isOnAllSpaces: false, isMinimized: false,
                    isFullscreen: false, isSplitView: false, order: offset, now: Date())
            }
            apps[sample.0] = AppLayout(bundleID: sample.0, appName: sample.1, windows: windows, updatedAt: Date())
        }
        model.store.merge(configKey: model.configKey, displays: displays, captured: apps, frozen: [])
        let single = [main]
        model.store.merge(configKey: DisplayConfiguration.key(for: [main.uuid]), displays: single,
                          captured: apps.filter { $0.key != "com.apple.Safari" }, frozen: [], now: Date().addingTimeInterval(-86400))
        if let config = model.currentLayout {
            model.store.addSnapshot(LayoutSnapshot(id: UUID(), name: "工作布局", kind: .manual, createdAt: Date().addingTimeInterval(-3600),
                                                   configKey: config.key, displays: config.displays, apps: config.apps))
            model.store.addAutomaticSnapshotIfChanged(from: config)
        }
        model.lastRestoreSummary = "移动 6 个窗口，2 个回到原桌面"
        model.lastRestoreAt = Date().addingTimeInterval(-420)
        model.log.add("已启动，当前显示器：\(model.displaySummary)")
        model.log.add("显示器配置变化：\(model.displaySummary)")
        model.log.add("显示器变化：移动 6 个窗口，2 个回到原桌面", level: .success)
        model.log.add("切换桌面方式「“切换到桌面 N”快捷键」未生效", level: .warning)
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
