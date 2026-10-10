import Foundation

struct BrowserEntry: Identifiable, Hashable, Sendable {
    enum Origin: Sendable {
        case local
        case remote
        case photo
    }

    let id: String
    let origin: Origin
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64?
    let modified: Date?
    let kindLabel: String
    let systemImage: String
    let photoIdentifier: String?
    let isVideo: Bool

    /// 供列表排序用的**非可空**投影。
    ///
    /// `TableColumn(_:value:)` 要求 `V: Comparable`，而 Swift 故意不给 `Optional`
    /// 定义 `Comparable`（nil 的次序没有自然定义）。所以可空字段在这里投影成非可空：
    /// 未知大小按 -1、未知日期按 `.distantPast`，两者都落在升序的最前面，与
    /// 「未知就先看」的直觉一致。文件夹本来就靠 `foldersFirst` 单独分组，不受影响。
    var sortableSize: Int64 { size ?? -1 }
    var sortableModified: Date { modified ?? .distantPast }

    init(
        origin: Origin,
        name: String,
        path: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        size: Int64?,
        modified: Date?,
        kindLabel: String,
        systemImage: String,
        photoIdentifier: String? = nil,
        isVideo: Bool = false
    ) {
        self.id = path
        self.origin = origin
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
        self.kindLabel = kindLabel
        self.systemImage = systemImage
        self.photoIdentifier = photoIdentifier
        self.isVideo = isVideo
    }

    init(remote: RemoteEntry) {
        self.init(
            origin: .remote,
            name: remote.name,
            path: remote.path,
            isDirectory: remote.isDirectory,
            isSymlink: remote.isSymlink,
            size: remote.size,
            modified: remote.modified,
            kindLabel: remote.kindLabel,
            systemImage: remote.systemImage
        )
    }

    /// 还原成设备端条目。
    ///
    /// 为什么要能反着转：列视图与预览窗格手上只有 `BrowserEntry`（统一的展示类型），
    /// 而打开 / 预览 / 移动这些动作要的是 `RemoteEntry`。有了它就不必再去
    /// `remoteEntries` 里按 id 反查 —— 那个列表里**没有子目录里的条目**。
    var asRemoteEntry: RemoteEntry {
        RemoteEntry(
            name: name,
            path: path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: size,
            modified: modified
        )
    }

    var asLocalEntry: LocalEntry {
        LocalEntry(
            name: name,
            url: URL(fileURLWithPath: path),
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: size,
            modified: modified
        )
    }
}
