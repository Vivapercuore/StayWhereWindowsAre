import Foundation
import Observation

/// Remembers the last known layout of every app for every display configuration, plus a history of snapshots.
@MainActor
@Observable
final class LayoutStore {
    private struct ConfigsFile: Codable {
        var version: Int
        var configs: [String: ConfigLayout]
    }

    private struct HistoryFile: Codable {
        var version: Int
        var history: [LayoutSnapshot]
    }

    private(set) var configs: [String: ConfigLayout] = [:]
    private(set) var history: [LayoutSnapshot] = []
    private(set) var lastSavedAt: Date?

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored var maxAutomaticSnapshots = 48
    @ObservationIgnored var maxBeforeRestoreSnapshots = 10
    @ObservationIgnored var staleAppLifetime: TimeInterval = 90 * 24 * 3600
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var configsDirty = false
    @ObservationIgnored private var historyDirty = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("StayWhereWindowsAre", isDirectory: true).appendingPathComponent("layouts.json")
    }

    /// Snapshots live in their own file so frequent layout updates do not rewrite the whole history.
    var historyURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("history.json") }

    func load() {
        configs = decode(ConfigsFile.self, from: fileURL)?.configs ?? [:]
        history = (decode(HistoryFile.self, from: historyURL)?.history ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            onError?("\(url.lastPathComponent) 无法解析，已备份为 \(backup.lastPathComponent)：\(error.localizedDescription)")
            return nil
        }
    }

    func layout(for key: String) -> ConfigLayout? {
        if let exact = configs[key] { return exact }
        let uuidKey = key.components(separatedBy: "|").first ?? key
        return configs
            .filter { $0.key.hasPrefix(uuidKey) }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .first?.value
    }

    /// Records freshly captured app layouts. Apps in `frozen` keep their saved layout, and an app that currently
    /// shows no windows keeps its last known layout so it can be restored when its windows come back.
    @discardableResult
    func merge(configKey: String, displays: [DisplayInfo], captured: [String: AppLayout], frozen: Set<String>, now: Date = Date()) -> Bool {
        var config = configs[configKey] ?? ConfigLayout(key: configKey, displays: displays, apps: [:], createdAt: now, updatedAt: now)
        var changed = configs[configKey] == nil || config.displays != displays
        config.displays = displays
        for (bundleID, layout) in captured where !frozen.contains(bundleID) && !layout.windows.isEmpty {
            if let existing = config.apps[bundleID], existing.isEquivalent(to: layout),
               now.timeIntervalSince(existing.updatedAt) < 24 * 3600 { continue }
            config.apps[bundleID] = layout
            changed = true
        }
        let cutoff = now.addingTimeInterval(-staleAppLifetime)
        let before = config.apps.count
        config.apps = config.apps.filter { $0.value.updatedAt >= cutoff }
        changed = changed || config.apps.count != before
        guard changed else { return false }
        config.updatedAt = now
        configs[configKey] = config
        scheduleSave()
        return true
    }

    func addSnapshot(_ snapshot: LayoutSnapshot) {
        history.insert(snapshot, at: 0)
        pruneHistory()
        scheduleSave(configs: false, history: true)
    }

    /// Adds an automatic snapshot unless nothing changed since the previous automatic one for that configuration.
    @discardableResult
    func addAutomaticSnapshotIfChanged(from config: ConfigLayout, now: Date = Date()) -> Bool {
        if let previous = history.first(where: { $0.kind == .automatic && $0.configKey == config.key }),
           previous.apps.count == config.apps.count,
           previous.apps.allSatisfy({ key, value in config.apps[key].map { $0.isEquivalent(to: value) } ?? false }) {
            return false
        }
        addSnapshot(LayoutSnapshot(
            id: UUID(), name: "自动快照", kind: .automatic, createdAt: now, configKey: config.key,
            displays: config.displays, apps: config.apps))
        return true
    }

    func renameSnapshot(id: UUID, to name: String) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].name = name
        history[index].kind = .manual
        scheduleSave(configs: false, history: true)
    }

    func removeSnapshot(id: UUID) {
        history.removeAll { $0.id == id }
        scheduleSave(configs: false, history: true)
    }

    func removeConfig(key: String) {
        configs[key] = nil
        scheduleSave()
    }

    func removeApp(bundleID: String) {
        for key in configs.keys { configs[key]?.apps[bundleID] = nil }
        scheduleSave()
    }

    func removeAll() {
        configs = [:]
        history = []
        scheduleSave(configs: true, history: true)
    }

    /// Every app that appears in any saved layout, newest first.
    var knownApps: [(bundleID: String, name: String, windowCount: Int, updatedAt: Date)] {
        var result: [String: (String, Int, Date)] = [:]
        for config in configs.values {
            for (bundleID, app) in config.apps {
                let current = result[bundleID]
                result[bundleID] = (app.appName, max(current?.1 ?? 0, app.windows.count), max(current?.2 ?? .distantPast, app.updatedAt))
            }
        }
        return result.map { ($0.key, $0.value.0, $0.value.1, $0.value.2) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func pruneHistory() {
        var automatic = 0, beforeRestore = 0
        history = history.filter { snapshot in
            switch snapshot.kind {
            case .manual: return true
            case .automatic: automatic += 1; return automatic <= maxAutomaticSnapshots
            case .beforeRestore: beforeRestore += 1; return beforeRestore <= maxBeforeRestoreSnapshots
            }
        }
    }

    func scheduleSave(configs: Bool = true, history: Bool = false) {
        configsDirty = configsDirty || configs
        historyDirty = historyDirty || history
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if configsDirty {
                try JSONEncoder().encode(ConfigsFile(version: 1, configs: configs)).write(to: fileURL, options: .atomic)
                configsDirty = false
            }
            if historyDirty {
                try JSONEncoder().encode(HistoryFile(version: 1, history: history)).write(to: historyURL, options: .atomic)
                historyDirty = false
            }
            lastSavedAt = Date()
        } catch {
            onError?("保存布局失败：\(error.localizedDescription)")
        }
    }
}
