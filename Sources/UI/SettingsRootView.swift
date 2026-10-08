import AppKit
import SwiftUI

struct SettingsRootView: View {
    var model: AppModel
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    ForEach([SettingsPage.overview]) { row($0) }
                }
                Section {
                    ForEach([SettingsPage.general, .restore, .apps, .layouts]) { row($0) }
                }
                Section {
                    ForEach([SettingsPage.permissions, .diagnostics, .log, .about]) { row($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .navigationTitle(navigation.selection.title)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var selection: Binding<SettingsPage?> {
        Binding(get: { navigation.selection }, set: { if let page = $0 { navigation.selection = page } })
    }

    private func row(_ page: SettingsPage) -> some View {
        Label {
            HStack {
                Text(page.title)
                if page == .permissions && !model.isTrusted {
                    Spacer()
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            }
        } icon: {
            BadgeIcon(symbol: page.symbol, tint: page.tint)
        }
        .tag(page)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .overview: OverviewPage(model: model, navigation: navigation)
        case .general: GeneralPage(model: model)
        case .restore: RestorePage(model: model)
        case .apps: AppsPage(model: model)
        case .layouts: LayoutsPage(model: model)
        case .permissions: PermissionsPage(model: model)
        case .diagnostics: DiagnosticsPage(model: model)
        case .log: LogPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}

struct OverviewPage: View {
    var model: AppModel
    var navigation: SettingsNavigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if !model.isTrusted { permissionCard }
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        displaysCard
                        spacesCard
                    }
                    GridRow {
                        recordCard
                        restoreCard
                    }
                }
                activityCard
            }
            .padding(24)
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text("StayWhereWindowsAre")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("记住每个窗口的位置、大小和所在桌面；重启、插拔显示器或应用重开后自动放回原处。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                StatusPill(phase: model.phase)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    model.restoreNow()
                } label: {
                    Label(model.isRestoring ? "正在恢复…" : "恢复窗口布局", systemImage: "arrow.uturn.backward")
                        .frame(minWidth: 150)
                }
                .controlSize(.large)
                .adaptiveButton(prominent: true)
                .disabled(!model.isTrusted || model.isRestoring || model.currentLayout == nil)
                Button {
                    model.saveSnapshot()
                } label: {
                    Label("保存快照", systemImage: "camera.viewfinder")
                        .frame(minWidth: 150)
                }
                .controlSize(.large)
                .adaptiveButton()
                .disabled(!model.isTrusted)
            }
        }
    }

    private var permissionCard: some View {
        Card {
            HStack(spacing: 12) {
                BadgeIcon(symbol: "hand.raised.fill", tint: .orange, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("还差一步：授予辅助功能权限").font(.headline)
                    Text("StayWhereWindowsAre 需要它来读取和移动其他应用的窗口。授权后会自动开始工作。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("前往授权") { navigation.selection = .permissions }
                    .adaptiveButton(prominent: true)
            }
        }
    }

    private var displaysCard: some View {
        Card(title: "当前显示器", symbol: "display.2", fillHeight: true) {
            ForEach(model.displays) { display in
                HStack(spacing: 8) {
                    Image(systemName: display.symbol)
                        .frame(width: 20)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(display.name).font(.callout.weight(.medium))
                        Text(Formatting.size(display.frame.size) + (display.isMain ? " · 主显示器" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if model.displays.isEmpty {
                Text("未检测到显示器").foregroundStyle(.secondary)
            }
        }
    }

    private var spacesCard: some View {
        Card(title: "桌面（Spaces）", symbol: "square.stack.3d.up", fillHeight: true) {
            if let topology = model.topology {
                ForEach(topology.displays, id: \.id) { display in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(displayName(for: display.id))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(display.spaces, id: \.id) { space in
                                SpaceChip(space: space, isCurrent: space.id == display.currentSpaceID)
                            }
                        }
                    }
                }
                if topology.spansDisplays {
                    Text("“显示器具有单独的空间”已关闭，所有显示器共享桌面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("无法读取桌面信息").foregroundStyle(.secondary)
            }
        }
    }

    private var recordCard: some View {
        Card(title: "已记录", symbol: "tray.full", fillHeight: true) {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(model.currentLayout?.windowCount ?? 0)")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("个窗口 · \(model.currentLayout?.apps.count ?? 0) 个应用")
                            .foregroundStyle(.secondary)
                    }
                    Text("上次记录：\(Formatting.relative(model.lastCaptureAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("已知显示器组合：\(model.store.configs.count) 种")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var restoreCard: some View {
        Card(title: "最近一次恢复", symbol: "clock.arrow.circlepath", fillHeight: true) {
            if let summary = model.lastRestoreSummary {
                Text(summary).font(.callout)
                Text(Formatting.relative(model.lastRestoreAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("本次启动后还没有恢复过").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var activityCard: some View {
        Card(title: "最近活动", symbol: "list.bullet") {
            let recent = model.log.entries.suffix(6).reversed()
            if recent.isEmpty {
                Text("暂无活动").foregroundStyle(.secondary)
            }
            ForEach(Array(recent)) { entry in
                LogRow(entry: entry)
            }
            Button("查看全部日志") { navigation.selection = .log }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func displayName(for spaceDisplayID: String) -> String {
        if spaceDisplayID == "Main" { return "所有显示器" }
        return model.displays.first { $0.uuid == spaceDisplayID }?.name ?? "显示器"
    }
}

struct SpaceChip: View {
    var space: SpaceRef
    var isCurrent: Bool

    var body: some View {
        Group {
            if space.isFullscreen {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
            } else {
                Text("\(space.desktopNumber ?? space.index)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .frame(minWidth: 24, minHeight: 20)
        .padding(.horizontal, 3)
        .foregroundStyle(isCurrent ? Color.white : Color.primary)
        .background(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(space.isFullscreen ? "全屏应用空间" : "桌面 \(space.desktopNumber ?? space.index)\(isCurrent ? "（当前）" : "")")
    }
}
