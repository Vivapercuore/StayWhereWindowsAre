import AppKit
import SwiftUI

struct StayWhereWindowsAreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: appDelegate.model)
        } label: {
            MenuBarIcon(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel = {
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["SWWA_SANDBOX_DIR"] {
            let base = URL(fileURLWithPath: directory)
            let model = AppModel(
                settings: AppSettings(defaults: UserDefaults(suiteName: "StayWhereWindowsAre.sandbox")!),
                store: LayoutStore(fileURL: base.appendingPathComponent("layouts.json")),
                log: ActivityLog(fileURL: base.appendingPathComponent("activity.log")))
            model.isSandboxed = true
            return model
        }
        #endif
        return AppModel()
    }()
    private lazy var settingsWindow = SettingsWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.openSettingsHandler = { [weak self] page in self?.settingsWindow.show(page: page) }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    /// Opening the app again from Finder or Launchpad shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show(page: nil)
        return true
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsPage = .overview
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show(page: SettingsPage?) {
        if let page { navigation.selection = page }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRootView(model: model, navigation: navigation))
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: hosting)
            window.title = "StayWhereWindowsAre"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 880, height: 620))
            window.minSize = NSSize(width: 780, height: 540)
            window.center()
            window.setFrameAutosaveName("StayWhereWindowsAre.Settings")
            self.window = window
        }
        // Show in the Dock and app switcher while the window is open, like a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
