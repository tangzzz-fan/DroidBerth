import AppKit

@MainActor
final class FinderServiceProvider: NSObject {
    static let shared = FinderServiceProvider()

    private var handler: (([URL]) -> Void)?
    private var pending: [[URL]] = []

    func install(_ handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        let queued = pending
        pending = []
        for urls in queued {
            handler(urls)
        }
    }

    @objc nonisolated func sendToDevice(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = Self.fileURLs(from: pboard)
        guard !urls.isEmpty else {
            error.pointee = "没有从 Finder 收到文件" as NSString
            return
        }
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
