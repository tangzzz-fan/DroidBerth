import Foundation

struct LocalPlace: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let systemImage: String
}

struct LocalEntry: Identifiable, Hashable, Sendable {
    let name: String
    let url: URL
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64?
    let modified: Date?

    var id: String { url.path }

    var kindLabel: String {
        if isDirectory { return "文件夹" }
        let ext = name.pathExtensionLowercased
        if ext.isEmpty { return "文稿" }
        return ext.uppercased() + " 文稿"
    }

    var systemImage: String {
        if isDirectory { return "folder.fill" }
        if name.isVideoFile { return "film" }
        if name.isImageFile { return "photo" }
        if name.isAudioFile { return "music.note" }
        switch name.pathExtensionLowercased {
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "app": return "app"
        case "pdf": return "doc.richtext"
        case "txt", "md", "log", "json", "xml", "csv": return "doc.text"
        default: return "doc"
        }
    }

    var asBrowserEntry: BrowserEntry {
        BrowserEntry(
            origin: .local,
            name: name,
            path: url.path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: size,
            modified: modified,
            kindLabel: kindLabel,
            systemImage: systemImage
        )
    }
}

enum LocalFileSystem {
    enum ListingResult: Sendable {
        case success([LocalEntry])
        case failure(String)
    }

    static func places() -> [LocalPlace] {
        let fileManager = FileManager.default
        var result: [LocalPlace] = []
        let home = fileManager.homeDirectoryForCurrentUser

        let candidates: [(String, String, String)] = [
            ("Desktop", "桌面", "menubar.dock.rectangle"),
            ("Documents", "文稿", "doc"),
            ("Downloads", "下载", "arrow.down.circle"),
            ("Movies", "影片", "film"),
            ("Pictures", "图片", "photo"),
            ("Music", "音乐", "music.note"),
        ]

        for (folder, title, symbol) in candidates {
            let url = home.appendingPathComponent(folder, isDirectory: true)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            result.append(LocalPlace(id: folder, name: title, url: url, systemImage: symbol))
        }

        result.append(LocalPlace(id: "home", name: "个人文件夹", url: home, systemImage: "house"))
        result.append(LocalPlace(id: "root", name: "Macintosh HD", url: URL(fileURLWithPath: "/"), systemImage: "internaldrive"))
        return result
    }

    static func list(_ directory: URL, showHidden: Bool) -> ListingResult {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .nameKey,
        ]

        do {
            var urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
            if !showHidden {
                urls.removeAll { $0.lastPathComponent.hasPrefix(".") }
            }

            let entries: [LocalEntry] = urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return LocalEntry(
                    name: url.lastPathComponent,
                    url: url,
                    isDirectory: values.isDirectory ?? false,
                    isSymlink: values.isSymbolicLink ?? false,
                    size: values.isDirectory == true ? nil : values.fileSize.flatMap { Int64($0) },
                    modified: values.contentModificationDate
                )
            }
            return .success(entries)
        } catch {
            return .failure((error as NSError).localizedDescription)
        }
    }

    static func uniqueDestination(in directory: URL, name: String) -> URL {
        let fileManager = FileManager.default
        let target = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: target.path) else { return target }

        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 1
        while true {
            let candidateName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
