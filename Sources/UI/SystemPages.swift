import AppKit
import SwiftUI

struct PermissionsPage: View {
    var model: AppModel
    @State private var resetMessage: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    BadgeIcon(symbol: "accessibility", tint: .blue, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("辅助功能").font(.headline)
                        Text("读取窗口的标题、位置和大小，并把窗口移回原处").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isTrusted {
                        Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("未授权", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                if !model.isTrusted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. 点击下方“打开系统设置”")
                        Text("2. 在“辅助功能”列表中打开 StayWhereWindowsAre 的开关（没有的话点 + 添加本 App）")
                        Text("3. 回到这里，授权后会自动开始工作，无需重启")
                    }
                    .font(.callout)
                    HStack {
                        Button("打开系统设置") { Self.openAccessibilitySettings() }
                            .adaptiveButton(prominent: true)
                        Button("再次请求授权") { AX.requestTrust() }
                            .adaptiveButton()
                    }
                }
                DisclosureGroup("开关已经打开，却仍显示未授权？") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("自己编译的 App 每次重新编译后签名都会变化，系统会认为它是一个新的 App，旧的授权随之失效。先重置授权记录，再重新打开开关即可。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("重置授权记录") { resetAuthorization() }
                            if let resetMessage {
                                Text(resetMessage).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text("必需权限")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录时自动启动")
                        Text(LoginItem.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Button("打开“登录项”设置") { LoginItem.openSystemSettings() }
            } header: {
                Text("开机自启")
            }

            Section {
                Label("不联网，不上传任何数据", systemImage: "network.slash")
                Label("不需要屏幕录制权限，不读取窗口内容", systemImage: "eye.slash")
                Label("布局只保存在本机的“应用程序支持”文件夹中", systemImage: "internaldrive")
            } header: {
                Text("隐私")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshLoginItemStatus() }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func resetAuthorization() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            resetMessage = process.terminationStatus == 0 ? "已重置，请重新打开开关" : "重置失败（\(process.terminationStatus)）"
            if process.terminationStatus == 0 { AX.requestTrust() }
        } catch {
            resetMessage = "重置失败：\(error.localizedDescription)"
        }
    }
}

struct DiagnosticsPage: View {
    var model: AppModel

    var body: some View {
        let test = model.selfTest
        Form {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("检测这台 Mac 上哪些移窗方式有效")
                        Text("会打开一个测试窗口并短暂切换桌面，大约需要 15 秒。测试期间请不要操作。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(test.isRunning ? "正在检测…" : "运行自检") {
                        Task { await test.run(model: model) }
                    }
                    .adaptiveButton(prominent: true)
                    .disabled(test.isRunning || !model.isTrusted || model.isRestoring)
                }
                ForEach(test.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        stepIcon(step.status)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                            if !step.detail.isEmpty {
                                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let last = test.lastResult, !last.recommendations.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("需要你的操作", systemImage: "hand.point.up.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        ForEach(Array(last.recommendations.enumerated()), id: \.offset) { _, rec in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                Text(rec).font(.callout)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("自检")
            }

            Section {
                let desktops = SymbolicHotkeys.enabledDesktopShortcuts
                HStack {
                    LabeledContent("切换到桌面 N") {
                        Text(desktops.isEmpty ? "未启用（不影响核心功能）" : "已启用 \(desktops.count) 个（桌面 \(desktops.map(String.init).joined(separator: "、"))）")
                    }
                    if desktops.isEmpty {
                        Button("去设置") {
                            openKeyboardSettings()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                    }
                }
                HStack {
                    LabeledContent("向左/右移动一个空间") {
                        Text(SymbolicHotkeys.moveLeft != nil && SymbolicHotkeys.moveRight != nil ? "已启用" : "未启用（不影响核心功能）")
                    }
                    if SymbolicHotkeys.moveLeft == nil || SymbolicHotkeys.moveRight == nil {
                        Button("去设置") {
                            openKeyboardSettings()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                    }
                }
                Button("打开键盘快捷键设置") {
                    openKeyboardSettings()
                }
            } header: {
                Text("调度中心快捷键")
            } footer: {
                Text("这些快捷键是切换桌面最快最可靠的方式。App 先用自己的锚点窗口切桌面，不行时才会用快捷键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(PrivateAPI.availability, id: \.name) { item in
                    LabeledContent(item.name) {
                        Image(systemName: item.available ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(item.available ? .green : .red)
                    }
                    .font(.callout.monospaced())
                }
            } header: {
                Text("系统接口")
            }

            Section {
                LabeledContent("显示器组合标识") {
                    Text(model.configKey).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                }
                LabeledContent("登录时间") {
                    Text(AppModel.sessionStartDate().formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("当前生效的切换方式顺序") {
                    Text(model.settings.spaceSwitchMethods.map(\.title).joined(separator: " → "))
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("运行状态")
            }
        }
        .formStyle(.grouped)
    }

    private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func stepIcon(_ status: SelfTest.Status) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}

extension ActivityLog.Level {
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

struct LogRow: View {
    var entry: ActivityLog.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.level.symbol)
                .foregroundStyle(entry.level.tint)
                .frame(width: 16)
            Text(entry.message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct LogPage: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.log.entries.isEmpty {
                ContentUnavailableView("暂无活动", systemImage: "list.bullet.rectangle", description: Text("记录和恢复窗口时会在这里留下记录。"))
            } else {
                List(model.log.entries.reversed()) { entry in
                    LogRow(entry: entry)
                }
            }
            Divider()
            HStack {
                Text("\(model.log.entries.count) 条记录").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("在访达中显示日志文件") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.log.logFileURL])
                }
                Button("清空") { model.log.clear() }
            }
            .padding(10)
        }
    }
}

struct AboutPage: View {
    var model: AppModel

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0")（\(info?["CFBundleVersion"] as? String ?? "1")）"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                VStack(spacing: 4) {
                    Text("StayWhereWindowsAre")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("版本 \(version)").foregroundStyle(.secondary)
                }
                Text("让窗口待在它该在的地方。")
                    .font(.title3)
                Card(title: "它是怎么工作的", symbol: "lightbulb") {
                    VStack(alignment: .leading, spacing: 8) {
                        bullet("持续记录每个应用窗口的位置、大小、所在显示器和桌面，并按“显示器组合”分别保存。")
                        bullet("应用重新打开、开机登录、插拔显示器、睡眠唤醒后，把匹配到的窗口放回原处：同一次登录内按窗口编号精确匹配，重启后按标题、大小和顺序匹配。")
                        bullet("macOS 不允许直接把其他应用的窗口移到别的桌面。这里利用“窗口移到另一台显示器时会进入它当前的桌面”这一特性：先把目标显示器切换到原来的桌面，再把窗口放过去；只有一台显示器时，模拟按住标题栏切换桌面。")
                        bullet("记录过程只比较窗口服务器状态，变化时才读取窗口详情；显示器变化、睡眠、锁屏和恢复期间暂停记录，避免把被打乱的布局存下来。")
                    }
                }
                .frame(maxWidth: 560)
            }
            .padding(30)
            .frame(maxWidth: .infinity)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(.tint).frame(width: 5, height: 5)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
