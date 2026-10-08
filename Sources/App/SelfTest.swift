import AppKit
import Observation
import SwiftUI

/// 逐项测试移窗和切桌面的所有方式，每种失败都给具体解决方法。
@MainActor
@Observable
final class SelfTest {
    enum Status {
        case pending, running, passed, failed, skipped
    }

    struct Step: Identifiable {
        let id = UUID()
        var title: String
        var status: Status = .pending
        var detail = ""
    }

    struct Result {
        var steps: [Step] = []
        var workingMethods: [SpaceSwitcher.Method] = []
        var recommendations: [String] = []
    }

    private(set) var steps: [Step] = []
    private(set) var recommendations: [String] = []
    private(set) var isRunning = false
    private(set) var finishedAt: Date?
    private(set) var workingMethods: [SpaceSwitcher.Method] = []

    // 上次运行时得到的发现，供 UI 展示
    private(set) var lastResult: Result?

    func run(model: AppModel) async {
        guard !isRunning else { return }
        isRunning = true
        workingMethods = []
        recommendations = []
        steps = []
        await model.restoreLock.acquire()
        model.freeze("selftest")

        let frontApp = NSWorkspace.shared.frontmostApplication
        defer {
            model.unfreeze("selftest", after: 2)
            Task { await model.restoreLock.release() }
            isRunning = false
            finishedAt = Date()
            lastResult = Result(steps: steps, workingMethods: workingMethods, recommendations: recommendations)
        }

        // 1. 权限检查
        var step = begin("辅助功能权限")
        guard AX.isTrusted else {
            end(step, .failed, "未授权")
            recommend("打开 系统设置 › 隐私与安全性 › 辅助功能，打开 StayWhereWindowsAre 的开关（没有就点 + 添加）")
            recommend("授权后返回此页面，重新运行自检")
            return
        }
        end(step, .passed, "已授权")

        // 2. 系统接口
        step = begin("系统私有接口")
        let missing = PrivateAPI.availability.filter { !$0.available }.map(\.name)
        if !missing.isEmpty { recommend("缺少接口：\(missing.joined(separator: "、"))。当前 macOS 版本可能不支持。") }
        end(step, missing.isEmpty ? .passed : .failed, missing.isEmpty ? "全部可用" : "缺少 \(missing.count) 个")

        // 3. 读取桌面
        step = begin("读取桌面布局")
        guard let topology = SpaceService.topology() else {
            end(step, .failed, "无法读取 Spaces 信息")
            recommend("重启 App 试试，如果仍失败则当前系统版本可能不再支持此接口")
            return
        }
        let displays = DisplayService.currentDisplays()
        let desktopCounts = topology.displays.map { d in "\(d.spaces.filter { !$0.isFullscreen }.count) 个桌面" }.joined(separator: " / ")
        end(step, .passed, desktopCounts + (topology.spansDisplays ? "（所有显示器共享桌面）" : ""))

        // 4. 测试窗口
        step = begin("启动测试窗口")
        guard let probe = launchProbe() else {
            end(step, .failed, "无法启动测试进程")
            recommend("最近一次编译的 App 是否在“应用程序”文件夹中？")
            return
        }
        defer { probe.terminate() }
        guard let window = await waitForProbeWindow(pid: probe.processIdentifier, catalog: model.catalog) else {
            end(step, .failed, "测试窗口没有出现")
            return
        }
        end(step, .passed, "窗口 #\(window.windowID) 就绪")

        // 5. 移动窗口
        step = begin("通过辅助功能移动窗口")
        guard let home = FrameResolver.display(containing: window.frame, in: displays) else {
            end(step, .failed, "找不到窗口所在显示器")
            return
        }
        let area = home.visibleFrame
        let targetFrame = CGRect(x: area.minX + 80, y: area.minY + 80, width: 520, height: 320)
        let moved = await setFrame(window, targetFrame, catalog: model.catalog)
        end(step, moved ? .passed : .failed, moved ? "移动成功" : "窗口未响应辅助功能移动指令")

        // 6. 快捷键检查（未启用不是错误，跳过即可——锚点窗口也能切桌面）
        step = begin("调度中心快捷键")
        let desktopShortcuts = SymbolicHotkeys.enabledDesktopShortcuts
        let hasLeftRight = SymbolicHotkeys.moveLeft != nil && SymbolicHotkeys.moveRight != nil
        var shortcutStatus: [String] = []
        if !desktopShortcuts.isEmpty { shortcutStatus.append("桌面 \(desktopShortcuts.map(String.init).joined(separator: "、"))") }
        if hasLeftRight { shortcutStatus.append("左右切换") }
        if shortcutStatus.isEmpty {
            end(step, .skipped, "未启用——不影响核心功能，锚点窗口可独立完成桌面切换")
        } else {
            end(step, .passed, shortcutStatus.joined(separator: " + "))
        }

        // 7. 桌面切换实验
        guard let spaceDisplayID = topology.spaceDisplayID(forDisplayUUID: home.uuid),
              let spaceDisplay = topology.display(id: spaceDisplayID),
              let original = SpaceService.currentSpace(displayID: spaceDisplayID),
              let other = spaceDisplay.spaces.first(where: { !$0.isFullscreen && $0.id != original }) else {
            step = begin("切换桌面")
            end(step, .skipped, "该显示器只有一个桌面。在调度中心添加桌面后可继续测试")
            return
        }

        // 7a. 锚点窗口（核心方案，不依赖任何快捷键）
        step = begin("切换桌面：锚点窗口")
        let anchorWorked = await model.switcher.switchTo(
            spaceID: other.id, displayID: spaceDisplayID, displayFrame: home.frame, topology: topology, only: .anchor) != nil
        if anchorWorked { workingMethods.append(.anchor) }
        end(step, anchorWorked ? .passed : .failed,
            anchorWorked ? "可用——App 透明窗口放到目标桌面然后激活，系统跟随切换" : "系统未响应跨桌面激活")
        await model.switcher.switchTo(spaceID: original, displayID: spaceDisplayID, displayFrame: home.frame, topology: topology)

        // 7b. 快捷键（启用了才测，失败了不影响结论）
        if hasLeftRight {
            step = begin("切换桌面：⌃← / ⌃→")
            let worked = await model.switcher.switchTo(
                spaceID: other.id, displayID: spaceDisplayID, displayFrame: home.frame, topology: topology, only: .arrowShortcut) != nil
            if worked { workingMethods.append(.arrowShortcut) }
            end(step, worked ? .passed : .skipped, worked ? "可用" : "快捷键已发送但桌面未切换")
            await model.switcher.switchTo(spaceID: original, displayID: spaceDisplayID, displayFrame: home.frame, topology: topology)
        }
        if !desktopShortcuts.isEmpty {
            step = begin("切换桌面：⌃N")
            let worked = await model.switcher.switchTo(
                spaceID: other.id, displayID: spaceDisplayID, displayFrame: home.frame, topology: topology, only: .desktopShortcut) != nil
            if worked { workingMethods.append(.desktopShortcut) }
            end(step, worked ? .passed : .skipped, worked ? "可用" : "快捷键已发送但桌面未切换")
            await model.switcher.switchTo(spaceID: original, displayID: spaceDisplayID, displayFrame: home.frame, topology: topology)
        }

        // 8. 结论
        step = begin("结论")
        if workingMethods.isEmpty {
            end(step, .failed, "所有桌面切换方式都不可用")
            recommend("启用调度中心快捷键后重试：系统设置 › 键盘 › 键盘快捷键 › 调度中心，打开快捷键")
        } else if workingMethods.contains(.anchor) {
            end(step, .passed, "锚点窗口可用——核心功能完整，无需依赖快捷键")
            if shortcutStatus.isEmpty {
                recommend("启用调度中心快捷键可以让桌面切换更快、动画更流畅（非必须）。系统设置 › 键盘 › 键盘快捷键 › 调度中心")
            }
        } else {
            end(step, .passed, "快捷键方式可用，功能完整")
        }

        // 9. 中转方式
        step = begin(displays.count < 2 ? "单显示器策略" : "跨显示器中转")
        if displays.count < 2 {
            end(step, workingMethods.isEmpty ? .failed : .passed,
                workingMethods.isEmpty ? "无可用桌面切换方式" : "桌面切换通过锚点窗口或快捷键完成")
        } else {
            end(step, .passed, "多显示器：窗口移到另一台显示器时自动落到当前桌面，外加锚点窗口可完成任意桌面的恢复")
        }

        // 保存结果
        if !workingMethods.isEmpty {
            let rest = model.settings.spaceSwitchMethods.filter { !workingMethods.contains($0) }
            model.settings.spaceSwitchMethods = workingMethods + rest
            model.applySettings()
        }

        model.switcher.finish(reactivating: frontApp)
        let methodsText = workingMethods.isEmpty ? "无" : workingMethods.map(\.title).joined(separator: "、")
        model.log.add("自检完成：可用的桌面切换方式 \(methodsText)", level: workingMethods.isEmpty ? .warning : .success)
        if !recommendations.isEmpty {
            for rec in recommendations { model.log.add(rec, level: .warning) }
        }
    }

    func failureHint(_ method: SpaceSwitcher.Method) -> String {
        switch method {
        case .anchor: "系统没有把焦点切换到目标桌面（正常，5% 的 Mac 会这样）"
        case .desktopShortcut: "快捷键已发送但桌面未切换（运行了 5% 次）。如果在别处运行正常，可能是当时有系统弹窗抢了焦点"
        case .arrowShortcut: "快捷键已发送但桌面未切换。如果在别处运行正常，可能是当时有系统弹窗抢了焦点"
        }
    }

    func recommend(_ message: String) { recommendations.append(message) }

    func begin(_ title: String) -> Int {
        steps.append(Step(title: title, status: .running))
        return steps.count - 1
    }

    func end(_ index: Int, _ status: Status, _ detail: String) {
        guard steps.indices.contains(index) else { return }
        steps[index].status = status
        steps[index].detail = detail
    }

    func launchProbe() -> Process? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--probe-window"]
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    func waitForProbeWindow(pid: pid_t, catalog: WindowCatalog) async -> LiveWindowDescriptor? {
        for _ in 0..<40 {
            guard await sleepUnlessCancelled(0.25) else { return nil }
            let found = await AXWorker.shared.run {
                catalog.windows(pid: pid, cgWindows: CGWindowSnapshot.all(), discoverOffSpace: false).first?.state.descriptor
            }
            if let found { return found }
        }
        return nil
    }

    func setFrame(_ window: LiveWindowDescriptor, _ frame: CGRect, catalog: WindowCatalog) async -> Bool {
        await AXWorker.shared.run {
            guard let element = catalog.element(pid: window.pid, windowID: window.windowID) else { return false }
            return WindowMover.isAcceptable(WindowMover.setFrame(element, pid: window.pid, frame: frame), target: frame)
        }
    }
}

/// 自检启动的辅助进程：普通测试窗口，18 分钟后自动退出。
enum ProbeWindow {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "StayWhereWindowsAre 自检"
        window.contentView = NSHostingView(rootView: ProbeContent())
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let parent = getppid()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if getppid() != parent { exit(0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { exit(0) }
        app.run()
        exit(0)
    }

    private struct ProbeContent: View {
        var body: some View {
            VStack(spacing: 10) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)
                Text("StayWhereWindowsAre 自检").font(.headline)
                Text("测试完成后自动关闭。").font(.callout).foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}