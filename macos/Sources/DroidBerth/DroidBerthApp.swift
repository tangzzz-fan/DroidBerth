import AppKit
import QuickLookUI
import SwiftUI

@main
enum EntryPoint {
    @MainActor
    static func main() {
        // 命令行入口都放在 SwiftUI 起来之前 —— 它们要能在**没有人操作界面**的情况下跑完，
        // 这样支持流程（以及自动化验收）才不需要开窗口。
        let arguments = CommandLine.arguments

        if arguments.contains("--spike-report") {
            SpikeReport.emit()
        }

        // 诊断相关的两个入口。先建日志与哨兵：这两个命令本身也该进日志。
        AppLog.start()
        CrashSentinel.begin()

        if arguments.contains("--diagnose") {
            DiagnosticsCLI.printSummary()
            // 命令行路径也要收尾 —— 否则每跑一次 `--diagnose` 都会给下一次留下
            // 「上次异常结束」的假警报。
            CrashSentinel.markCleanExit()
            exit(0)
        }
        // ⚠️ 匹配必须用**前缀**，不能写 `$0 == "--export-diagnostics"`。
        // 写成精确相等时，`--export-diagnostics=/tmp/x` 匹配不上 ⇒ 悄悄落到 GUI 分支，
        // 在终端里表现为「命令挂住不返回」（图形进程不会自己退出），而且**不报任何错**。
        // 这个坑真实发生过，排查花了一轮 —— 换成正则般的前缀匹配后两种写法都能认。
        if let index = arguments.firstIndex(where: {
            $0 == "--export-diagnostics" || $0.hasPrefix("--export-diagnostics=")
        }) {
            // 允许 `--export-diagnostics=<目录>` 或紧跟在后面的一个参数。
            var parent: URL?
            if let value = arguments[index].split(separator: "=", maxSplits: 1).dropFirst().first,
               !value.isEmpty {
                parent = URL(fileURLWithPath: String(value))
            } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                parent = URL(fileURLWithPath: arguments[index + 1])
            }
            DiagnosticsCLI.export(to: parent)
            CrashSentinel.markCleanExit()
            exit(0)
        }

        // 兜底：命令行里出现**没被识别的** `--xxx` 时，明说一句再继续。
        // 少这一条，一个拼错的开关会静默变成「打开界面」，没有任何反馈。
        let known: Set<String> = ["--spike-report", "--diagnose"]
        let unknown = arguments.dropFirst().filter { $0.hasPrefix("--") }.filter { argument in
            !known.contains(argument) && !argument.hasPrefix("--export-diagnostics")
        }
        if !unknown.isEmpty {
            FileHandle.standardError.write(
                Data("DroidBerth：未识别的命令行参数 \(unknown.joined(separator: " "))，将按普通启动处理。\n".utf8)
            )
        }

        DroidBerthApp.main()
    }
}

/// 诊断的命令行入口。
///
/// 为什么用命令行而不是只做界面：**用户报障时最省事的一步是「把这个命令跑一下，把输出发我」**，
/// 而界面那条路要求对方先找到按钮、再找到文件、再想办法发出来。两条都留着，
/// 命令行那条同时也是验收手段（不需要人来点）。
enum DiagnosticsCLI {
    @MainActor
    static func printSummary() {
        var out: [String] = []
        out.append("DroidBerth 诊断摘要")
        out.append("时间：\(ISO8601DateFormatter().string(from: Date()))")
        out.append("版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
                   + " (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
        out.append("bundle：\(Bundle.main.bundlePath)")
        out.append("在 /Applications：\(Bundle.main.bundlePath.hasPrefix("/Applications/") ? "是" : "否")")
        out.append("日志目录：\(AppPaths.logsDirectory.path)")
        out.append("")

        if let previous = CrashSentinel.readPreviousSession() {
            out.append("上次会话：**异常结束**（pid \(previous.session.pid)，开始于 \(previous.session.startedAt)）")
            out.append("  窗口内系统崩溃报告：\(previous.crashReportNames.isEmpty ? "无" : previous.crashReportNames.joined(separator: "、"))")
            if let exception = previous.lastException {
                out.append("  未捕获异常记录：")
                for line in exception.split(separator: "\n").prefix(4) {
                    out.append("    \(line)")
                }
            }
        } else {
            out.append("上次会话：正常结束（或没有记录）")
        }
        out.append("")

        let reports = CrashSentinel.recentSystemCrashReports(within: 7 * 86_400, limit: 5)
        out.append("最近 7 天的系统崩溃报告：\(reports.count) 份")
        for url in reports { out.append("  \(url.lastPathComponent)") }
        out.append("")

        if let adb = ADBBinary.shared.resolve()?.path {
            let version = ProcessRunner.run(URL(fileURLWithPath: adb), ["version"], timeout: 15)
            out.append("adb：\(adb)")
            out.append("  \(version.stdout.split(separator: "\n").first.map(String.init) ?? "?")")
        } else {
            out.append("adb：**没找到**")
        }

        out.append("")
        out.append("最近日志（尾部 40 行）：")
        for line in AppLog.tail(limit: 40).split(separator: "\n") {
            out.append("  \(line)")
        }

        print(AppLog.redact(out.joined(separator: "\n")))
    }

    static func export(to parent: URL?) {
        let outcome = DiagnosticsExporter.collect(into: parent)
        var lines: [String] = []
        lines.append("诊断包已生成：\(outcome.zipURL.path)")
        lines.append("目录：\(outcome.directory.path)")
        lines.append("含 \(outcome.items.count) 项：")
        for item in outcome.items { lines.append("  · \(item)") }
        if !outcome.warnings.isEmpty {
            lines.append("警告 \(outcome.warnings.count) 条：")
            for warning in outcome.warnings { lines.append("  ! \(warning)") }
        }
        print(AppLog.redact(lines.joined(separator: "\n")))
    }
}

/// 把 Quick Look 面板接进响应者链。
///
/// `QLPreviewPanel` 只认响应者链上第一个 `acceptsPreviewPanelControl:` 返回 true 的
/// 对象；**没有它，`makeKeyAndOrderFront` 不会带上数据源，面板是空的。**
///
/// 挂在 App 代理而不是某个视图上：代理是**每条响应者链的终点**。挂在视图上要先保证
/// 那个视图是当前 first responder 的祖先（`.background` 放的兄弟节点根本不在链上），
/// 而且面板自己成为 key window 时链路会重新搜索 —— 终点不会掉出去。
@MainActor
final class DroidBerthAppDelegate: NSObject, NSApplicationDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 未捕获异常处理器要在「可能出事之前」装好，所以放在这里而不是按需。
        CrashSentinel.installExceptionHandler()
        // Finder「服务」菜单的接收端（PRD §P1）。系统按响应者链找 `NSApp.servicesProvider`，
        // 所以挂在 App 代理上、在启动时装上。这里的时机 09-26 在真机上验证过 ——
        // `pbs -dump` 能登记到它、`NSPerformService` 两条路径都通。
        // ⚠️ 要求 app 装在 `/Applications`，构建目录里启动不会被系统登记（详见该类注释）。
        NSApp.servicesProvider = FinderServiceProvider.shared
        AppLog.notice("应用启动完成（界面已就绪）", .app)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 会话哨兵的收尾。**强退与崩溃走不到这里** —— 那正是它能当判据的原因。
        CrashSentinel.markCleanExit()
    }

    // 这三个是 `NSObject (QLPreviewPanelController)` 里的**非隔离**方法，覆写后本方法
    // 也变成非隔离，于是碰不到 MainActor 上的 `QuickLookPresenter`。
    // AppKit 保证它们只在主线程调用，所以 `assumeIsolated` 是成立的断言，不是掩护。
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookPresenter.shared
            panel.delegate = QuickLookPresenter.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

struct DroidBerthApp: App {
    @NSApplicationDelegateAdaptor(DroidBerthAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("DroidBerth") {
            MainView(model: model)
                // 预览栏占一栏常驻宽度，窗口下限要跟着抬 —— 否则 900 减去预览栏会把
                // 两个窗格压到各自 340pt 的下限之下（宽度分配本身没有弹性）。
                .frame(minWidth: model.settings.showPreviewPane ? 1180 : 900, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("上传到设备") {
                    Task { await model.uploadSelection() }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button("下载到 Mac") {
                    Task { await model.downloadSelection() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("新建文件夹") {
                    NotificationCenter.default.post(name: .droidBerthNewFolder, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            // ⌘C / ⌘V 在本产品里必须被占用（跨栏 = 传输，PRD §22）。
            // 焦点在文本框里时逐个转发回系统文本语义，见 TextEditingRelay。
            CommandGroup(replacing: .pasteboard) {
                Button("剪切") {
                    if !TextEditingRelay.forwardIfEditing(#selector(NSText.cut(_:))) {
                        model.cutSelection()
                    }
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("拷贝") {
                    if !TextEditingRelay.forwardIfEditing(#selector(NSText.copy(_:))) {
                        model.copySelection()
                    }
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("粘贴") {
                    if !TextEditingRelay.forwardIfEditing(#selector(NSText.paste(_:))) {
                        model.pasteIntoFocus()
                    }
                }
                .keyboardShortcut("v", modifiers: .command)

                Divider()

                Button("全选") {
                    if !TextEditingRelay.forwardIfEditing(#selector(NSText.selectAll(_:))) {
                        model.selectAllInFocusedPane()
                    }
                }
                .keyboardShortcut("a", modifiers: .command)

                Button("删除…") {
                    if !TextEditingRelay.forwardIfEditing(#selector(NSText.delete(_:))) {
                        NotificationCenter.default.post(name: .droidBerthDeleteSelection, object: nil)
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canDeleteSelection)
            }

            CommandMenu("前往") {
                Button("返回") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                Button("前进") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
                Button("上一层文件夹") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("刷新") { model.refreshFocusedPane() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Divider()
                Button("聚焦左侧窗格") { model.focusLeftPane() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("聚焦右侧窗格") { model.focusRightPane() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }

            // 显示菜单（PRD §22）。
            // 空格本身由 PaneKeyMonitor 的本地事件监听处理，这里刻意不挂菜单快捷键：
            // 无修饰键的菜单快捷键会先于文本框拿到事件，会把输入框里的空格吃掉。
            // 菜单项只负责「可发现」与启用态。
            CommandGroup(after: .toolbar) {
                Button("快速查看") { model.quickLookFocusedSelection() }
                    .disabled(!model.canQuickLook)

                Button("搜索") {
                    NotificationCenter.default.post(name: .droidBerthFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Toggle("显示隐藏文件", isOn: $model.showHiddenFiles)
                    .keyboardShortcut(".", modifiers: [.command, .shift])

                Toggle("显示预览窗格", isOn: Bindable(model.settings).showPreviewPane)
                    .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("交换两侧") { model.swapPanes() }
                    .keyboardShortcut("x", modifiers: [.command, .shift])

                Divider()

                // PRD §11 View 菜单：列表 ⌘1 / 分栏 ⌘2 / 网格 ⌘3。三段随 Phase 3.2 齐了。
                Button("列表视图") { model.setViewMode(.list, for: model.focus) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("分栏视图") { model.setViewMode(.column, for: model.focus) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("网格视图") { model.setViewMode(.grid, for: model.focus) }
                    .keyboardShortcut("3", modifiers: .command)

                Divider()

                Button("放大图标") { model.enlargeGridIcons() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(!model.canEnlargeGridIcons)
                Button("缩小图标") { model.shrinkGridIcons() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!model.canShrinkGridIcons)
            }

            // PRD §11 Device 菜单。此前这些动作只散落在工具栏的「设备」下拉与「⋯」里，
            // 进菜单是为了可发现性 —— 用键盘的人不会去翻工具栏。
            //
            // **「连接设备…」（主动连接向导）刻意缺席**：它需要一套输入 IP / 配对的
            // 交互，尚未实现。与工具栏只放能用的段、⌘2 补不上就不挂是同一条判据 ——
            // 摆一个永远灰着的项是假可用。
            CommandMenu("设备") {
                Button("设备信息…") {
                    Task { await model.showDeviceInfo() }
                }
                .disabled(model.activeDevice == nil)

                Button("启用无线连接") {
                    Task { await model.enableWireless() }
                }
                .disabled(model.activeDevice == nil
                          || model.activeDevice?.isWireless == true
                          || model.wireless.busy)

                Button("断开连接") {
                    Task { await model.disconnectDevice() }
                }
                .disabled(model.activeDevice == nil)

                Divider()

                Button("重新检测设备") {
                    Task { await model.monitor.refresh() }
                }

                Button("重新扫描媒体库") {
                    Task { await model.scanRemoteSelection() }
                }
                .disabled(model.activeDevice == nil || model.remoteSelection.isEmpty)
            }

            // ⌘, 打开设置。工具栏不再放齿轮 —— 设置属于 app 菜单，放两处只会让人犹豫。
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    NotificationCenter.default.post(name: .droidBerthOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // 帮助菜单只放两件事，都是**排障路径**上的动作，不是「关于」类的装饰。
            // 「导出诊断报告…」与命令行 `--export-diagnostics` 是同一条代码路径 ——
            // 用户报障时，开发者可以让对方点这个按钮，也可以让对方跑那条命令。
            CommandGroup(replacing: .help) {
                Button("导出诊断报告…") {
                    Task { await model.exportDiagnostics() }
                }
                .disabled(model.diagnosticsExporting)

                Button("在访达中显示日志") { model.revealLogs() }
            }
        }
    }
}

extension Notification.Name {
    static let droidBerthNewFolder = Notification.Name("DroidBerth.newFolder")
    static let droidBerthDeleteSelection = Notification.Name("DroidBerth.deleteSelection")
    /// 菜单命令 → `MainView` 的桥。`showSettings` 与搜索焦点都是 `MainView` 的
    /// `@State` / `@FocusState`，菜单命令拿不到，只能靠通知转一手。
    static let droidBerthOpenSettings = Notification.Name("DroidBerth.openSettings")
    static let droidBerthFocusSearch = Notification.Name("DroidBerth.focusSearch")
}
