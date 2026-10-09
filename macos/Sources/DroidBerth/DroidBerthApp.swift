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
                Button("聚焦 Mac 窗格") { model.focus = .mac }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("聚焦设备窗格") { model.focus = .device }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }

            // 空格本身由 PaneKeyMonitor 的本地事件监听处理，这里刻意不挂菜单快捷键：
            // 无修饰键的菜单快捷键会先于文本框拿到事件，会把输入框里的空格吃掉。
            // 菜单项只负责「可发现」与启用态，键位见 PRD §22。
            CommandGroup(after: .toolbar) {
                Button("快速查看") { model.quickLookFocusedSelection() }
                    .disabled(!model.canQuickLook)
            }
        }
    }
}

extension Notification.Name {
    static let droidBerthNewFolder = Notification.Name("DroidBerth.newFolder")
    static let droidBerthDeleteSelection = Notification.Name("DroidBerth.deleteSelection")
}
