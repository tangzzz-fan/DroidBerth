import AppKit

/// Finder「服务」菜单的接收端（PRD §P1 的「Services 菜单入口」）。
///
/// `Info.plist` 里的 `NSServices` 声明把 `sendToDevice:` 暴露到 Finder 的「右键 → 服务」里。
/// 系统在用户点它时按响应者链找 `NSApp.servicesProvider` —— 所以它必须在启动时装上
/// （见 `DroidBerthAppDelegate.applicationDidFinishLaunching`）。
///
/// App **没在运行**时，系统会按 `NSPortName` 拉起一个新实例，此时投递可能早于
/// `AppModel.start()` —— 所以这里留了一个 `pending` 队列，等 handler 装上再补投。
///
/// ⚠️ **前置条件：App 必须装在 `/Applications`（或其子目录里）。** Apple 对 services 的要求
/// 原文是 "install it in the Applications folder (or a subfolder)"，放在构建目录里系统不会
/// 登记它。装完若菜单里还是没有，执行一次
/// `/System/Library/CoreServices/pbs -update`（`pbs` 在 macOS 27 上参数已变，
/// 不是老文档里的 `-dump_pboard`）；仍不出现就注销重新登录 —— 服务列表在登录时构建。
///
/// 自检是否被系统登记：
/// ```bash
/// /System/Library/CoreServices/pbs -dump | grep -A8 -i droidberth
/// ```
/// 应能看到 `NSBundlePath = "/Applications/DroidBerth.app"` 与 `NSMessage = sendToDevice`。
@MainActor
final class FinderServiceProvider: NSObject {
    static let shared = FinderServiceProvider()

    private var handler: (([URL]) -> Void)?
    private var pending: [[URL]] = []

    /// 由 `AppModel.start()` 调用。装上之前到达的请求会在这里**补投**。
    func install(_ handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        let queued = pending
        pending = []
        for urls in queued {
            handler(urls)
        }
    }

    /// ⚠️ 方法名与签名必须与 `Info.plist` 的 `NSMessage` 以及 Apple 的 services 约定
    /// **逐字一致**：`- (void)sendToDevice:(NSPasteboard *)pboard userData:(NSString *)userData
    /// error:(NSString **)error`。改一处就得改另一处 —— 不匹配时菜单项是灰的，而且**不会有
    /// 任何报错**，只会表现为「点了没反应」。
    @objc nonisolated func sendToDevice(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = Self.fileURLs(from: pboard)
        // 这一层**没有任何错误可以外传**（services 的失败只会表现为「菜单项没反应」），
        // 所以解析结果必须落日志 —— 否则「没送达」与「送达了但解析出 0 个文件」无法区分。
        AppLog.notice("Finder 服务：sendToDevice 解析出 \(urls.count) 个项目"
                      + "（剪贴板类型：\(pboard.types?.map(\.rawValue).joined(separator: ",") ?? "无")）",
                      .transfer)
        guard !urls.isEmpty else {
            error.pointee = "没有从 Finder 收到文件" as NSString
            return
        }
        // AppKit 保证 services 只在主线程投递，所以这是一条成立的断言，不是掩护。
        MainActor.assumeIsolated {
            FinderServiceProvider.shared.receive(urls)
        }
    }

    private func receive(_ urls: [URL]) {
        if let handler {
            handler(urls)
        } else {
            pending.append(urls)
        }
    }

    /// 两种取法都要试：新的 UTType 路径，以及老的 `NSFilenamesPboardType`。
    /// 老 Finder 行为不一定走前者，而这一层失败**不会报错**，只会表现为「收到 0 个文件」。
    private nonisolated static func fileURLs(from pboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            return urls
        }
        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let names = pboard.propertyList(forType: legacy) as? [String] {
            return names.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}
