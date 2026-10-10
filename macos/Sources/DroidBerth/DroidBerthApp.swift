import AppKit
import QuickLookUI
import SwiftUI

@main
enum EntryPoint {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--spike-report") {
            SpikeReport.emit()
        }
        DroidBerthApp.main()
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
