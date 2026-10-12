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
        // 符号链接先判 —— 与 `RemoteEntry.kindLabel` **保持同一个顺序与同一个词**。
        //
        // ⚠️ 设备侧一直是对的（`if isSymlink { return "替身" }`），本地侧漏了这一支，
        // 于是**同一个概念在两个窗格里显示得不一样**（这台项目反复栽的那一类）。
        // 2026-10-12 在沙盒版里量到它的具体后果：容器里那五个符号链接
        // （`Desktop`/`Downloads`/… 指向真实目录）显示成 **「文稿」**，
        // 因为沙盒下 `isDirectoryKey` 不跟随链接 ⇒ 掉进了「按扩展名判种类」的兜底分支。
        if isSymlink { return "替身" }
        if isDirectory { return "文件夹" }
        let ext = name.pathExtensionLowercased
        if ext.isEmpty { return "文稿" }
        return ext.uppercased() + " 文稿"
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
            systemImage: FileTypeIcon.symbol(forName: name, isDirectory: isDirectory)
        )
    }
}

enum LocalFileSystem {
    enum ListingResult: Sendable {
        case success([LocalEntry])
        case failure(String)
    }

    /// 侧边栏的「位置」。
    ///
    /// 沙盒版会把「名字在、其实用不了」的那些剔掉 —— 判据在 `LocalPlacePolicy`，那里写了为什么。
    /// 侧载版行为与从前完全一致。
    ///
    /// ⚠️ 结果**算一次就缓存**：这个函数在 `MainView` 的 `body` 里被调用，而沙盒下取证要用
    /// 「真去列一次目录」，放进 `body` 会每帧都做 IO。位置在一个进程的生命周期内不会变。
    /// （E7 加入「用户授权过的目录」之后要一并处理这个缓存 —— 那时列表会变。）
    static func places() -> [LocalPlace] { cachedPlaces }

    private static let cachedPlaces: [LocalPlace] = computePlaces()

    private static func computePlaces() -> [LocalPlace] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        // 两个都先解析符号链接：容器可能落在 `/var` → `/private/var` 这类链接后面，
        // 而 `isInside` 是纯文本的按分量比较，拿没解析的路径比会漏判。
        let container = AppPaths.containerDirectory.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }

        var result: [LocalPlace] = []

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
            guard isUsablePlace(url, container: container) else { continue }
            // 返回**解析后**的 URL，而不是容器里那个符号链接名。
            //
            // 2026-10-12 实测（F3）：URL 版 `contentsOfDirectory(at:includingPropertiesForKeys:)`
            // 对 `<容器>/Downloads` 报 `NSFileReadNoPermissionError`，而**解析后的真实路径**能列。
            // 判据（`isUsablePlace`）用的就是解析后的路径，那返回的就必须是同一个 ——
            // 否则会出现「过了判据、点开却打不开」，而那种失败最容易被当成随机问题。
            result.append(LocalPlace(
                id: folder,
                name: title,
                url: url.resolvingSymlinksInPath(),
                systemImage: symbol
            ))
        }

        // 这两个也过同一套判据：沙盒下 `home` 就是容器本身（列出来的是容器里的东西，
        // 不是用户的个人文件夹），而 `/` 能列、也真在容器外，照旧保留。
        if isUsablePlace(home, container: container) {
            result.append(LocalPlace(id: "home", name: "个人文件夹", url: home, systemImage: "house"))
        }
        let root = URL(fileURLWithPath: "/")
        if isUsablePlace(root, container: container) {
            result.append(LocalPlace(id: "root", name: "Macintosh HD", url: root, systemImage: "internaldrive"))
        }
        return result
    }

    /// 「名字在」不等于「能用」。两条判据在 `LocalPlacePolicy`，这里只负责**取证**。
    private static func isUsablePlace(_ url: URL, container: String?) -> Bool {
        // 不在沙盒里时「能不能列」是显然的，**不去碰磁盘** —— 侧载版是今天的常态路径，
        // 不该为了一条只对 MAS 生效的判据每次都去列几个目录。
        let canList: Bool
        if container == nil {
            canList = true
        } else {
            // ⚠️ 必须**真的开一次目录**：实测沙盒下 `fileExists` 对这四项返回 **true**，
            // 只有真去列才报 `errno 257`。拿 `fileExists` / `isReadableFile` 代替会把它们全判成能用。
            // （`opendir` 按理更省，但「沙盒下它是否同样被拒」**没实测过** —— 不拿没量过的东西当判据。）
            canList = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
        }
        return LocalPlacePolicy.isUsable(
            resolvedPath: url.resolvingSymlinksInPath().path,
            containerPath: container,
            canList: canList
        )
    }

    static func list(_ directory: URL, showHidden: Bool) -> ListingResult {
        let fileManager = FileManager.default

        // ── 保护：**不进自己容器里的东西** ─────────────────────────────────
        // 沙盒里 `NSHomeDirectory()` 就是 App 自己的容器，里面有 `Library` / `SystemData` /
        // `tmp` / `Documents` 这些管道。2026-10-12 实测：沙盒版**开局就站在那里**，
        // 列表把它们原样列了出来，而当时这一层**没有任何保护**。
        //
        // 判据与 `places()` 同一条（`LocalPlacePolicy`），守在这里而不是只在 `navigateLocal`：
        // 这个函数是**列目录的唯一入口**，放这儿所有调用点一起受保护。
        //
        // ⚠️ 必须**先解析符号链接**：<容器>/Downloads 解析后是真实家目录下的 Downloads，
        //    在容器**之外** ⇒ 那是用户的文件夹，要放行。
        let container = AppPaths.containerDirectory.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        if !LocalPlacePolicy.isBrowsable(
            resolvedPath: directory.resolvingSymlinksInPath().path,
            containerPath: container
        ) {
            AppLog.warning("拒绝列出容器内部路径：\(directory.path)", .transfer)
            return .failure("这个位置是 DroidBerth 自己的容器，不是你的文件。请从「位置」里选目录。")
        }

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
                let isLink = values.isSymbolicLink ?? false
                let isDir = values.isDirectory ?? false
                return LocalEntry(
                    name: url.lastPathComponent,
                    url: url,
                    isDirectory: isDir,
                    isSymlink: isLink,
                    // 符号链接**不报大小**：`fileSizeKey` 给的是**链接自身**的长度。
                    // 实测 `Desktop → ../../../../Desktop` 报 **19 B**、`Downloads` 报 **21 B** ——
                    // 那正是目标路径字符串的字节数。它既不是文件大小也不是目录大小，
                    // 摆在那儿只会让人以为那是个十几字节的文件。
                    size: (isDir || isLink) ? nil : values.fileSize.flatMap { Int64($0) },
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
