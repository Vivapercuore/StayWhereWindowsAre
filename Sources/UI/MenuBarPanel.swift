import AppKit
import SwiftUI

struct MenuBarIcon: View {
    var model: AppModel

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("StayWhereWindowsAre：\(model.phase.title)")
    }

    private var symbol: String {
        switch model.phase {
        case .needsPermission: "exclamationmark.triangle"
        case .paused: "pause.rectangle"
        case .restoring: "arrow.triangle.2.circlepath"
        default: "macwindow.on.rectangle"
        }
    }
}

struct MenuBarPanel: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.isTrusted { permissionBanner }
            stats
            actions
            snapshots
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("StayWhereWindowsAre")
                    .font(.headline)
                Text(model.displays.isEmpty ? "未检测到显示器" : model.displaySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            StatusPill(phase: model.phase)
        }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("需要辅助功能权限")
                    .font(.subheadline.weight(.semibold))
                Text("没有它就无法读取和移动其他应用的窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("前往授权") { model.openSettings(.permissions) }
                    .controlSize(.small)
                    .adaptiveButton(prominent: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var stats: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    stat(value: "\(model.currentLayout?.apps.count ?? 0)", label: "个应用")
                    stat(value: "\(model.currentLayout?.windowCount ?? 0)", label: "个窗口")
                    stat(value: Formatting.relative(model.lastCaptureAt), label: "上次记录")
                }
                if let summary = model.lastRestoreSummary {
                    Label("\(Formatting.relative(model.lastRestoreAt))恢复：\(summary)", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                model.restoreNow()
            } label: {
                Label(model.isRestoring ? "正在恢复…" : "恢复窗口布局", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .adaptiveButton(prominent: true)
            .disabled(!model.isTrusted || model.isRestoring || model.currentLayout == nil)

            HStack(spacing: 8) {
                Button {
                    model.saveSnapshot()
                } label: {
                    Label("保存快照", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.isTrusted)
                Button {
                    model.togglePaused()
                } label: {
                    Label(model.settings.autoSaveEnabled ? "暂停记录" : "继续记录",
                          systemImage: model.settings.autoSaveEnabled ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .adaptiveButton()
        }
    }

    private var snapshots: some View {
        let recent = Array(model.store.history.filter { $0.configKey == model.configKey }.prefix(4))
        return VStack(alignment: .leading, spacing: 6) {
            Text("最近快照")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if recent.isEmpty {
                Text("还没有快照。会每隔一段时间自动保存，也可以手动保存。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(recent) { snapshot in
                    HStack(spacing: 8) {
                        Image(systemName: snapshot.kind.symbol)
                            .foregroundStyle(snapshot.kind.tint)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(snapshot.name).font(.callout).lineLimit(1)
                            Text("\(Formatting.dateTime(snapshot.createdAt)) · \(snapshot.windowCount) 个窗口")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.restoreSnapshot(snapshot)
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .help("恢复到这个快照")
                        .disabled(!model.isTrusted || model.isRestoring)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.openSettings()
            } label: {
                Label("设置…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

extension SnapshotKind {
    var symbol: String {
        switch self {
        case .automatic: "clock"
        case .manual: "star.fill"
        case .beforeRestore: "arrow.uturn.left.circle"
        }
    }

    var tint: Color {
        switch self {
        case .automatic: .secondary
        case .manual: .yellow
        case .beforeRestore: .blue
        }
    }

    var title: String {
        switch self {
        case .automatic: "自动"
        case .manual: "手动"
        case .beforeRestore: "恢复前"
        }
    }
}
