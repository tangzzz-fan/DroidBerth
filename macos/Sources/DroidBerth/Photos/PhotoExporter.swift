@preconcurrency import Photos
import Foundation

enum PhotoExporter {
    struct Result: Sendable {
        let localIdentifier: String
        let filename: String
        let url: URL?
        let error: String?
    }

    static func export(identifiers: [String], to directory: URL) -> AsyncStream<Result> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                var byIdentifier: [String: PHAsset] = [:]
                byIdentifier.reserveCapacity(fetched.count)
                fetched.enumerateObjects { asset, _, _ in
                    byIdentifier[asset.localIdentifier] = asset
                }

                for identifier in identifiers {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    guard let asset = byIdentifier[identifier] else {
                        continuation.yield(Result(
                            localIdentifier: identifier,
                            filename: identifier,
                            url: nil,
                            error: "照片库中找不到该资源"
                        ))
                        continue
                    }

                    let resources = PHAssetResource.assetResources(for: asset)
                    guard let resource = resources.first(where: {
                        $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
                    }) ?? resources.first(where: {
                        $0.type == .photo || $0.type == .video
                    }) ?? resources.first else {
                        continuation.yield(Result(
                            localIdentifier: identifier,
                            filename: identifier,
                            url: nil,
                            error: "该资源没有可导出的原始文件"
                        ))
                        continue
                    }

                    let filename = resource.originalFilename
                    let target = LocalFileSystem.uniqueDestination(in: directory, name: filename)
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = true

                    do {
                        try await PHAssetResourceManager.default().writeData(
                            for: resource,
                            toFile: target,
                            options: options
                        )
                        continuation.yield(Result(
                            localIdentifier: identifier,
                            filename: filename,
                            url: target,
                            error: nil
                        ))
                    } catch {
                        continuation.yield(Result(
                            localIdentifier: identifier,
                            filename: filename,
                            url: nil,
                            error: (error as NSError).localizedDescription
                        ))
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
