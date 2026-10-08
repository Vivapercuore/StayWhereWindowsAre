import AppKit
import SwiftUI

struct AppsPage: View {
    var model: AppModel
    @State private var search = ""

    private struct Row: Identifiable {
        var bundleID: String
        var name: String
        var savedWindows: Int
        var isRunning: Bool
        var id: String { bundleID }
    }

    private var rows: [Row] {
        var map: [String: Row] = [:]
        for app in model.store.knownApps {
            map[app.bundleID] = Row(bundleID: app.bundleID, name: app.name, savedWindows: 0, isRunning: false)
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { continue }
            map[bundleID, default: Row(bundleID: bundleID, name: app.localizedName ?? bundleID, savedWindows: 0, isRunning: true)].isRunning = true
        }
        for key in map.keys { map[key]?.savedWindows = model.currentLayout?.apps[key]?.windows.count ?? 0 }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return map.values
            .filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query) }
            .sorted { ($0.isRunning ? 0 : 1, $0.name.lowercased()) < ($1.isRunning ? 0 : 1, $1.name.lowercased()) }
    }

    var body: some View {
        let rows = self.rows
        Form {
            Section {
                if rows.isEmpty {
                    Text(search.isEmpty ? "还没有记录到任何应用" : "没有匹配的应用").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        AppIconView(bundleID: row.bundleID, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(row.name)
                                if row.isRunning {
                                    Circle().fill(.green).frame(width: 6, height: 6).help("正在运行")
                                }
                            }
                            Text(row.bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(row.savedWindows > 0 ? "已记录 \(row.savedWindows) 个窗口" : "未记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("记录", isOn: Binding(
                            get: { !model.settings.isExcluded(row.bundleID) },
                            set: { model.settings.setExcluded(row.bundleID, !$0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .contextMenu {
                        Button("清除该应用的布局记录") {
                            model.store.removeApp(bundleID: row.bundleID)
                            model.log.add("已清除「\(row.name)」的布局记录")
                        }
                    }
                }
            } header: {
                Text("关闭开关的应用不会被记录，也不会被移动。右键可以清除某个应用的记录。")
            }
        }
        .formStyle(.grouped)
        .searchable(text: $search, prompt: "搜索应用")
    }
}

struct LayoutsPage: View {
    var model: AppModel
    @State private var snapshotName = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var pendingDeletion: ConfigLayout?

    var body: some View {
        Form {
            Section {
                let configs = model.store.configs.values.sorted { lhs, rhs in
                    if (lhs.key == model.configKey) != (rhs.key == model.configKey) { return lhs.key == model.configKey }
                    return lhs.updatedAt > rhs.updatedAt
                }
                if configs.isEmpty {
                    Text("还没有记录。授权后会自动开始记录当前显示器组合的布局。").foregroundStyle(.secondary)
                }
                ForEach(configs) { config in
                    ConfigRow(model: model, config: config, onDelete: { pendingDeletion = config })
                }
            } header: {
                Text("显示器组合")
            } footer: {
                Text("每种显示器组合分别保存一份布局：拔掉外接显示器时用“单屏布局”，接回来时自动换回“双屏布局”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("快照名称（可选）", text: $snapshotName)
                        .textFieldStyle(.roundedBorder)
                    Button("保存当前布局") {
                        model.saveSnapshot(named: snapshotName)
                        snapshotName = ""
                    }
                    .disabled(!model.isTrusted)
                }
                if model.store.history.isEmpty {
                    Text("暂无快照").foregroundStyle(.secondary)
                }
                ForEach(model.store.history) { snapshot in
                    snapshotRow(snapshot)
                }
            } header: {
                Text("快照")
            } footer: {
                Text("自动快照会定期保存（只保留最近一部分），手动快照会一直保留。手动恢复前会自动保存一份“恢复前的布局”，方便撤销。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("删除这个显示器组合的布局？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("删除", role: .destructive) {
                if let config = pendingDeletion { model.store.removeConfig(key: config.key) }
                pendingDeletion = nil
            }
        } message: {
            Text(pendingDeletion?.summary ?? "")
        }
    }

    @ViewBuilder
    private func snapshotRow(_ snapshot: LayoutSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: snapshot.kind.symbol)
                .foregroundStyle(snapshot.kind.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                if renamingID == snapshot.id {
                    TextField("名称", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            model.store.renameSnapshot(id: snapshot.id, to: renameText)
                            renamingID = nil
                        }
                } else {
                    Text(snapshot.name)
                }
                Text("\(Formatting.dateTime(snapshot.createdAt)) · \(snapshot.kind.title) · \(snapshot.windowCount) 个窗口 · \(snapshot.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if snapshot.configKey != model.configKey {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .help("来自其他显示器组合，只会恢复仍连接的显示器上的窗口")
            }
            Button("恢复") { model.restoreSnapshot(snapshot) }
                .disabled(!model.isTrusted || model.isRestoring)
            Menu {
                Button("重命名并保留") {
                    renameText = snapshot.name
                    renamingID = snapshot.id
                }
                Button("删除", role: .destructive) { model.store.removeSnapshot(id: snapshot.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct ConfigRow: View {
    var model: AppModel
    var config: ConfigLayout
    var onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(config.apps.values.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }, id: \.bundleID) { app in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        AppIconView(bundleID: app.bundleID, size: 18)
                        Text(app.appName).font(.callout.weight(.medium))
                        Spacer()
                        Text("\(app.windows.count) 个窗口").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(app.windows.enumerated()), id: \.offset) { _, window in
                        Text(windowLine(window))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 26)
                    }
                }
                .padding(.vertical, 2)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: config.displays.count > 1 ? "display.2" : (config.displays.first?.symbol ?? "display"))
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(config.summary.isEmpty ? "未知显示器" : config.summary)
                        if config.key == model.configKey {
                            Text("当前")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                    }
                    Text("\(config.apps.count) 个应用 · \(config.windowCount) 个窗口 · 更新于 \(Formatting.relative(config.updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("恢复") { model.restoreConfig(config) }
                    .disabled(!model.isTrusted || model.isRestoring)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除这个组合的布局")
            }
        }
    }

    private func windowLine(_ window: WindowRecord) -> String {
        var parts = [window.title.isEmpty ? "（无标题）" : window.title]
        if let space = window.space {
            parts.append(space.isFullscreen ? "全屏" : "桌面 \(space.desktopNumber ?? space.index)")
        }
        if let display = config.displays.first(where: { $0.uuid == window.displayUUID }) {
            parts.append(display.name)
        }
        parts.append(Formatting.size(window.frame.size))
        if window.isMinimized { parts.append("已最小化") }
        return parts.joined(separator: " · ")
    }
}
