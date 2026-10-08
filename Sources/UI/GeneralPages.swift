import AppKit
import SwiftUI

struct SliderRow: View {
    var title: String
    var detail: String?
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value)) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct GeneralPage: View {
    var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("登录时自动启动")
                    Text("状态：\(LoginItem.statusText)")
                }
                if LoginItem.status == .requiresApproval {
                    Button("在系统设置中批准…") { LoginItem.openSystemSettings() }
                }
            } header: {
                Text("启动")
            }

            Section {
                Toggle(isOn: $settings.autoSaveEnabled) {
                    Text("自动记录窗口布局")
                    Text("持续记住每个窗口的位置、大小和所在桌面")
                }
                Toggle(isOn: $settings.discoverOffSpaceWindows) {
                    Text("记录其他桌面上的窗口")
                    Text("系统接口只返回当前桌面的窗口，开启后会额外查找其他桌面上的窗口")
                }
                Toggle(isOn: $settings.pauseWhenIdle) {
                    Text("长时间无操作时暂停记录")
                    Text("5 分钟没有键盘鼠标操作时，窗口变化通常不是你做的（例如显示器休眠后被系统挪动）")
                }
                SliderRow(title: "检测间隔", detail: "只比较窗口服务器的状态，变化时才读取窗口详情，开销很小",
                          value: $settings.pollInterval, range: 1...10, step: 1, unit: "秒")
                Picker("自动快照", selection: $settings.snapshotIntervalMinutes) {
                    Text("每 5 分钟").tag(5.0)
                    Text("每 15 分钟").tag(15.0)
                    Text("每 30 分钟").tag(30.0)
                    Text("每小时").tag(60.0)
                }
            } header: {
                Text("记录")
            }

            Section {
                Toggle(isOn: $settings.includeDialogs) {
                    Text("包括对话框类窗口")
                    Text("默认只处理标准窗口，不处理面板、弹窗和对话框")
                }
            } header: {
                Text("窗口")
            }

            Section {
                LabeledContent("布局数据") {
                    Button("在访达中显示") {
                        let url = model.store.fileURL
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(url.deletingLastPathComponent())
                        }
                    }
                }
                LabeledContent("设置") {
                    Button("恢复默认设置") {
                        settings.resetToDefaults()
                        model.applySettings()
                    }
                }
                LabeledContent("记录") {
                    Button("清除所有布局记录…", role: .destructive) { confirmClear = true }
                }
            } header: {
                Text("数据")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.pollInterval) { model.applySettings() }
        .onChange(of: settings.discoverOffSpaceWindows) { model.applySettings() }
        .onChange(of: settings.includeDialogs) { model.applySettings() }
        .onChange(of: settings.autoSaveEnabled) { model.updatePhase() }
        .onAppear { model.refreshLoginItemStatus() }
        .confirmationDialog("清除所有布局记录？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                model.store.removeAll()
                model.log.add("已清除所有布局记录", level: .warning)
            }
        } message: {
            Text("所有显示器组合的布局和快照都会被删除，之后会重新开始记录。")
        }
    }
}

struct RestorePage: View {
    var model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: $settings.restoreOnAppLaunch) {
                    Text("应用重新打开后")
                    Text("应用启动时观察它新出现的窗口，逐个放回上次的位置和桌面")
                }
                Toggle(isOn: $settings.restoreOnLogin) {
                    Text("开机或登录后")
                    Text("等系统和其他应用把窗口恢复出来，再统一摆回原位")
                }
                Toggle(isOn: $settings.restoreOnDisplayChange) {
                    Text("插拔显示器后")
                    Text("每种显示器组合各自记忆布局，换回某个组合时自动还原它的布局")
                }
                Toggle(isOn: $settings.restoreOnWake) {
                    Text("睡眠唤醒后")
                    Text("修正唤醒时被系统挪乱的窗口")
                }
            } header: {
                Text("何时自动恢复")
            }

            Section {
                Toggle(isOn: $settings.restoreSpaces) {
                    Text("把窗口送回原来的桌面")
                    Text("macOS 不允许直接把其他应用的窗口移到别的桌面，所以会先切换到目标桌面再放入窗口，恢复时屏幕会短暂切换桌面")
                }
                Toggle(isOn: $settings.allowDragFallback) {
                    Text("单显示器时使用模拟拖拽")
                    Text("没有第二台显示器可以中转时，按住窗口标题栏并切换桌面来搬运窗口，期间会短暂移动鼠标指针")
                }
                .disabled(!settings.restoreSpaces)
                ForEach(SpaceSwitcher.Method.allCases) { method in
                    Toggle(isOn: methodBinding(method, settings: settings)) {
                        Text(method.title)
                        Text(methodDetail(method))
                    }
                    .disabled(!settings.restoreSpaces)
                }
            } header: {
                Text("桌面（Spaces）")
            } footer: {
                Text("切换桌面的方式会按顺序尝试，每一步都会核对结果。在“诊断”页运行自检，可以测出这台 Mac 上哪种方式有效并自动调整顺序。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SliderRow(title: "显示器变化后等待", detail: "等显示器稳定、系统挪完窗口后再恢复",
                          value: $settings.displaySettleDelay, range: 1...10, step: 1, unit: "秒")
                SliderRow(title: "登录后等待", detail: "给系统和应用恢复窗口的时间",
                          value: $settings.loginRestoreDelay, range: 3...40, step: 1, unit: "秒")
                SliderRow(title: "“刚登录”的时间范围", detail: "App 在登录后这段时间内启动，才会执行开机恢复",
                          value: $settings.loginWindowMinutes, range: 2...30, step: 1, unit: "分钟")
                SliderRow(title: "应用启动后观察", detail: "在这段时间内出现的窗口会被放回原处",
                          value: $settings.appLaunchWatchSeconds, range: 5...60, step: 5, unit: "秒")
            } header: {
                Text("时机")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.allowDragFallback) { model.applySettings() }
        .onChange(of: settings.spaceSwitchMethods) { model.applySettings() }
    }

    private func methodBinding(_ method: SpaceSwitcher.Method, settings: AppSettings) -> Binding<Bool> {
        Binding {
            settings.spaceSwitchMethods.contains(method)
        } set: { enabled in
            if enabled {
                if !settings.spaceSwitchMethods.contains(method) { settings.spaceSwitchMethods.append(method) }
            } else {
                settings.spaceSwitchMethods.removeAll { $0 == method }
            }
        }
    }

    private func methodDetail(_ method: SpaceSwitcher.Method) -> String {
        switch method {
        case .anchor:
            return "把一个透明的小窗口放到目标桌面并激活它，系统会随之切换桌面。不需要任何快捷键"
        case .desktopShortcut:
            let enabled = SymbolicHotkeys.enabledDesktopShortcuts
            return enabled.isEmpty ? "未启用。可在 系统设置 › 键盘 › 键盘快捷键 › 调度中心 中开启" : "已启用桌面 \(enabled.map(String.init).joined(separator: "、"))"
        case .arrowShortcut:
            return SymbolicHotkeys.moveRight == nil ? "未启用" : "使用 ⌃← / ⌃→ 一步步切换"
        }
    }
}
