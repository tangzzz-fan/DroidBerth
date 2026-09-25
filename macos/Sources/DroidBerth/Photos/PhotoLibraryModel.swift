@preconcurrency import Photos
import Foundation

struct PhotoAlbum: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case all
        case favorites
        case videos
        case screenshots
        case user
        case smart
    }

    let id: String
    let title: String
    let count: Int
    let kind: Kind
    let localIdentifier: String?
}

struct PhotoItem: Identifiable, Hashable, Sendable {
    let id: String
    let localIdentifier: String
    let filename: String
    let isVideo: Bool
    let width: Int
    let height: Int
    let duration: Double
    let creationDate: Date?
    let byteCount: Int64?

    var asBrowserEntry: BrowserEntry {
        BrowserEntry(
            origin: .photo,
            name: filename,
            path: localIdentifier,
            isDirectory: false,
            isSymlink: false,
            size: byteCount,
            modified: creationDate,
            kindLabel: isVideo ? "视频" : "照片",
            systemImage: isVideo ? "film" : "photo",
            photoIdentifier: localIdentifier,
            isVideo: isVideo
        )
    }
}

@MainActor
@Observable
final class PhotoLibraryModel {
    enum Access: Sendable {
        case unknown
        case denied
        case restricted
        case limited
        case authorized

        var isUsable: Bool { self == .authorized || self == .limited }
    }

    private(set) var access: Access = .unknown
    private(set) var albums: [PhotoAlbum] = []
    private(set) var items: [PhotoItem] = []
    private(set) var loadingAlbums = false
    private(set) var loadingItems = false
    private(set) var loadError: String?

    var selectedAlbumID: String? {
        didSet {
            guard selectedAlbumID != oldValue else { return }
            Task { await loadItems() }
        }
    }

    var selectedAlbum: PhotoAlbum? {
        albums.first { $0.id == selectedAlbumID }
    }

    func refreshAccess() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: access = .authorized
        case .limited: access = .limited
        case .denied: access = .denied
        case .restricted: access = .restricted
        case .notDetermined: access = .unknown
        @unknown default: access = .unknown
        }
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized: access = .authorized
        case .limited: access = .limited
        case .denied: access = .denied
        case .restricted: access = .restricted
        default: access = .unknown
        }
        if access.isUsable {
            await loadAlbums()
        }
    }

    func loadAlbums() async {
        guard access.isUsable else { return }
        loadingAlbums = true
        defer { loadingAlbums = false }

        let result = await Task.detached(priority: .userInitiated) { () -> [PhotoAlbum] in
            var albums: [PhotoAlbum] = []

            let allCount = PHAsset.fetchAssets(with: nil).count
            albums.append(PhotoAlbum(id: "all", title: "所有照片", count: allCount, kind: .all, localIdentifier: nil))

            let smartOptions = PHFetchOptions()
            smartOptions.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]

            let smartCollections = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: .any,
                options: smartOptions
            )
            smartCollections.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: nil).count
                guard count > 0 else { return }
                let kind: PhotoAlbum.Kind
                switch collection.assetCollectionSubtype {
                case .smartAlbumFavorites: kind = .favorites
                case .smartAlbumVideos: kind = .videos
                case .smartAlbumScreenshots: kind = .screenshots
                default: kind = .smart
                }
                albums.append(PhotoAlbum(
                    id: "smart-\(collection.localIdentifier)",
                    title: collection.localizedTitle ?? "智能相簿",
                    count: count,
                    kind: kind,
                    localIdentifier: collection.localIdentifier
                ))
            }

            let userCollections = PHAssetCollection.fetchAssetCollections(
                with: .album,
                subtype: .any,
                options: smartOptions
            )
            userCollections.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: nil).count
                guard count > 0 else { return }
                albums.append(PhotoAlbum(
                    id: "user-\(collection.localIdentifier)",
                    title: collection.localizedTitle ?? "相簿",
                    count: count,
                    kind: .user,
                    localIdentifier: collection.localIdentifier
                ))
            }

            return albums
        }.value

        albums = result
        if selectedAlbumID == nil || !result.contains(where: { $0.id == selectedAlbumID }) {
            selectedAlbumID = result.first?.id
        }
    }

    func loadItems(limit: Int = 2000) async {
        guard access.isUsable, let album = selectedAlbum else {
            items = []
            return
        }

        loadingItems = true
        loadError = nil
        defer { loadingItems = false }

        let albumKind = album.kind
        let albumIdentifier = album.localIdentifier

        let result = await Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = limit

            let fetched: PHFetchResult<PHAsset>
            switch albumKind {
            case .all:
                fetched = PHAsset.fetchAssets(with: options)
            case .videos:
                options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
                fetched = PHAsset.fetchAssets(with: options)
            default:
                if let identifier = albumIdentifier,
                   let collection = PHAssetCollection.fetchAssetCollections(
                       withLocalIdentifiers: [identifier],
                       options: nil
                   ).firstObject {
                    fetched = PHAsset.fetchAssets(in: collection, options: options)
                } else {
                    fetched = PHAsset.fetchAssets(with: options)
                }
            }

            var output: [PhotoItem] = []
            output.reserveCapacity(fetched.count)
            fetched.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                let primary = resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
                    ?? resources.first { $0.type == .photo || $0.type == .video }
                    ?? resources.first
                let filename = primary?.originalFilename ?? "\(asset.localIdentifier.replacingOccurrences(of: "/", with: "_")).jpg"
                let byteCount = (primary?.value(forKey: "fileSize") as? NSNumber)?.int64Value
                output.append(PhotoItem(
                    id: asset.localIdentifier,
                    localIdentifier: asset.localIdentifier,
                    filename: filename,
                    isVideo: asset.mediaType == .video,
                    width: asset.pixelWidth,
                    height: asset.pixelHeight,
                    duration: asset.duration,
                    creationDate: asset.creationDate,
                    byteCount: byteCount
                ))
            }
            return output
        }.value

        items = result
    }
}
