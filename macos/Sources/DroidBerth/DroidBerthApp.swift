import AppKit
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = FinderServiceProvider.shared
    }
}

struct DroidBerthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
