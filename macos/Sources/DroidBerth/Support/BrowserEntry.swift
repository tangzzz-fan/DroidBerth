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
}
