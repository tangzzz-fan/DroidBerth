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

struct DroidBerthApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("DroidBerth") {
            MainView(model: model)
                .frame(minWidth: 900, minHeight: 600)
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
                        model.showCutUnsupported()
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
