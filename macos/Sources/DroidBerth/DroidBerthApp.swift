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

                Divider()

                Button("删除…") {
                    NotificationCenter.default.post(name: .droidBerthDeleteSelection, object: nil)
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
        }
    }
}

extension Notification.Name {
    static let droidBerthNewFolder = Notification.Name("DroidBerth.newFolder")
    static let droidBerthDeleteSelection = Notification.Name("DroidBerth.deleteSelection")
}
