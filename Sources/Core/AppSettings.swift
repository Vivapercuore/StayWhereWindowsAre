import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var autoSaveEnabled: Bool { didSet { defaults.set(autoSaveEnabled, forKey: Keys.autoSave) } }
    var restoreOnAppLaunch: Bool { didSet { defaults.set(restoreOnAppLaunch, forKey: Keys.onAppLaunch) } }
    var restoreOnDisplayChange: Bool { didSet { defaults.set(restoreOnDisplayChange, forKey: Keys.onDisplayChange) } }
    var restoreOnLogin: Bool { didSet { defaults.set(restoreOnLogin, forKey: Keys.onLogin) } }
    var restoreOnWake: Bool { didSet { defaults.set(restoreOnWake, forKey: Keys.onWake) } }
    var restoreSpaces: Bool { didSet { defaults.set(restoreSpaces, forKey: Keys.restoreSpaces) } }
    var allowDragFallback: Bool { didSet { defaults.set(allowDragFallback, forKey: Keys.allowDrag) } }
    var discoverOffSpaceWindows: Bool { didSet { defaults.set(discoverOffSpaceWindows, forKey: Keys.offSpace) } }
    var includeDialogs: Bool { didSet { defaults.set(includeDialogs, forKey: Keys.dialogs) } }
    var pauseWhenIdle: Bool { didSet { defaults.set(pauseWhenIdle, forKey: Keys.pauseWhenIdle) } }
    var pollInterval: Double { didSet { defaults.set(pollInterval, forKey: Keys.pollInterval) } }
    var displaySettleDelay: Double { didSet { defaults.set(displaySettleDelay, forKey: Keys.displaySettle) } }
    var loginRestoreDelay: Double { didSet { defaults.set(loginRestoreDelay, forKey: Keys.loginDelay) } }
    var loginWindowMinutes: Double { didSet { defaults.set(loginWindowMinutes, forKey: Keys.loginWindow) } }
    var appLaunchWatchSeconds: Double { didSet { defaults.set(appLaunchWatchSeconds, forKey: Keys.appWatch) } }
    var snapshotIntervalMinutes: Double { didSet { defaults.set(snapshotIntervalMinutes, forKey: Keys.snapshotInterval) } }
    var excludedBundleIDs: Set<String> { didSet { defaults.set(Array(excludedBundleIDs).sorted(), forKey: Keys.excluded) } }
    var spaceSwitchMethods: [SpaceSwitcher.Method] {
        didSet { defaults.set(spaceSwitchMethods.map(\.rawValue), forKey: Keys.switchMethods) }
    }
    var hasLaunchedBefore: Bool { didSet { defaults.set(hasLaunchedBefore, forKey: Keys.launchedBefore) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: key) as? Double ?? fallback }
        autoSaveEnabled = bool(Keys.autoSave, true)
        restoreOnAppLaunch = bool(Keys.onAppLaunch, true)
        restoreOnDisplayChange = bool(Keys.onDisplayChange, true)
        restoreOnLogin = bool(Keys.onLogin, true)
        restoreOnWake = bool(Keys.onWake, true)
        restoreSpaces = bool(Keys.restoreSpaces, true)
        allowDragFallback = bool(Keys.allowDrag, true)
        discoverOffSpaceWindows = bool(Keys.offSpace, true)
        includeDialogs = bool(Keys.dialogs, false)
        pauseWhenIdle = bool(Keys.pauseWhenIdle, true)
        pollInterval = double(Keys.pollInterval, 3)
        displaySettleDelay = double(Keys.displaySettle, 3)
        loginRestoreDelay = double(Keys.loginDelay, 8)
        loginWindowMinutes = double(Keys.loginWindow, 10)
        appLaunchWatchSeconds = double(Keys.appWatch, 25)
        snapshotIntervalMinutes = double(Keys.snapshotInterval, 15)
        excludedBundleIDs = Set(defaults.stringArray(forKey: Keys.excluded) ?? [])
        let methods = (defaults.stringArray(forKey: Keys.switchMethods) ?? []).compactMap(SpaceSwitcher.Method.init(rawValue:))
        spaceSwitchMethods = methods.isEmpty ? SpaceSwitcher.Method.allCases : methods
        hasLaunchedBefore = bool(Keys.launchedBefore, false)
    }

    func isExcluded(_ bundleID: String) -> Bool { excludedBundleIDs.contains(bundleID) }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        if excluded { excludedBundleIDs.insert(bundleID) } else { excludedBundleIDs.remove(bundleID) }
    }

    func resetToDefaults() {
        for key in Keys.all { defaults.removeObject(forKey: key) }
        let fresh = AppSettings(defaults: defaults)
        autoSaveEnabled = fresh.autoSaveEnabled
        restoreOnAppLaunch = fresh.restoreOnAppLaunch
        restoreOnDisplayChange = fresh.restoreOnDisplayChange
        restoreOnLogin = fresh.restoreOnLogin
        restoreOnWake = fresh.restoreOnWake
        restoreSpaces = fresh.restoreSpaces
        allowDragFallback = fresh.allowDragFallback
        discoverOffSpaceWindows = fresh.discoverOffSpaceWindows
        includeDialogs = fresh.includeDialogs
        pauseWhenIdle = fresh.pauseWhenIdle
        pollInterval = fresh.pollInterval
        displaySettleDelay = fresh.displaySettleDelay
        loginRestoreDelay = fresh.loginRestoreDelay
        loginWindowMinutes = fresh.loginWindowMinutes
        appLaunchWatchSeconds = fresh.appLaunchWatchSeconds
        snapshotIntervalMinutes = fresh.snapshotIntervalMinutes
        spaceSwitchMethods = fresh.spaceSwitchMethods
    }

    private enum Keys {
        static let autoSave = "autoSaveEnabled"
        static let onAppLaunch = "restoreOnAppLaunch"
        static let onDisplayChange = "restoreOnDisplayChange"
        static let onLogin = "restoreOnLogin"
        static let onWake = "restoreOnWake"
        static let restoreSpaces = "restoreSpaces"
        static let allowDrag = "allowDragFallback"
        static let offSpace = "discoverOffSpaceWindows"
        static let dialogs = "includeDialogs"
        static let pauseWhenIdle = "pauseWhenIdle"
        static let pollInterval = "pollInterval"
        static let displaySettle = "displaySettleDelay"
        static let loginDelay = "loginRestoreDelay"
        static let loginWindow = "loginWindowMinutes"
        static let appWatch = "appLaunchWatchSeconds"
        static let snapshotInterval = "snapshotIntervalMinutes"
        static let excluded = "excludedBundleIDs"
        static let switchMethods = "spaceSwitchMethods"
        static let launchedBefore = "hasLaunchedBefore"
        static let all = [autoSave, onAppLaunch, onDisplayChange, onLogin, onWake, restoreSpaces, allowDrag, offSpace, dialogs,
                          pauseWhenIdle, pollInterval, displaySettle, loginDelay, loginWindow, appWatch, snapshotInterval, switchMethods]
    }
}

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// `.notFound` is also what a never-registered app reports on some macOS versions.
    static var isUnregistered: Bool { status == .notRegistered || status == .notFound }

    static var statusText: String {
        switch status {
        case .enabled: "已开启"
        case .requiresApproval: "等待你在系统设置中批准"
        case .notRegistered: "未开启"
        case .notFound: "未开启"
        @unknown default: "未知"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
