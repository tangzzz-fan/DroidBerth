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
        }
    }
}

extension Notification.Name {
    static let droidBerthNewFolder = Notification.Name("DroidBerth.newFolder")
}
