import AppKit
import Foundation
import QuickLookThumbnailing

/// 缩略图相关的常量。
///
/// 刻意放在**非 actor 的 enum** 里而不是 `ThumbnailStore` 的 static：`ThumbnailStore`
/// 是 `@MainActor`，它的 `static let` 会隐式继承 MainActor 隔离，在
/// `Task.detached` 的 `@Sendable` 闭包里读不到。
private enum ThumbnailConstants {
    /// 远端只拉这么多字节（PRD §13.3 的「图片前 64 KB」）。
    static let remoteHeaderBytes = 64 * 1024
    /// 缓存条目上限。超出按最旧插入顺序淘汰。
    static let capacity = 600
    /// 远端同时进行的取头任务数。设备侧 adb 本来就要排队，开太多只会互相拖慢。
    static let maxConcurrentRemote = 4
    /// 远端待取队列上限。滚动很快时不做无界堆积。
    static let queueLimit = 64
    /// 生成尺寸（像素，最长边）。取图标上限 240pt × 2x = 480，512 足够覆盖所有档位，
    /// 因此一套缩略图能服务所有图标大小，⌘+ / ⌘- 不会触发重新生成。
    static let maxPixelSize = 512
}

/// 网格视图的缩略图缓存与生成（PRD §13.3）。
///
/// 两条生成路径：
/// - **本地**：直接把文件 URL 交给 `QLThumbnailGenerator`。
/// - **远端**：先只拉前 64 KB（`DeviceShell.fetchHeader`）落成临时文件，再交给
///   `QLThumbnailGenerator`。**刻意不下载完整文件** —— 一个 4 GB 的视频只为看一眼
///   缩略图而全量拉取，是整个功能里最不能接受的开销。
///
/// **哪些类型走这条路由 `ThumbnailPolicy` 决定**，两侧的判据不同（远端只做图片，
/// 因为 64 KB 这条通道对视频实测必失败 —— 理由与数据在那个类型上）。
///
/// 生成失败一律落到 `.unavailable`，由视图回退类型图标（PRD §13.3 明文要求
/// 「生成失败时显示类型图标，不留空白」）。缩略图拿不到不是错误，不该往界面抛。
@MainActor
@Observable
final class ThumbnailStore {
    enum State {
        case idle
        case loading
        case loaded(NSImage)
        /// 生成失败，或该类型不生成缩略图。
        case unavailable
    }

    private var states: [String: State] = [:]
    /// 插入顺序，用于容量淘汰。同一 key 只会入队一次（`request` 有去重）。
    private var recency: [String] = []
    /// 远端缩略图的临时落地文件，淘汰 / 重置时要一并删掉。
    private var scratchFiles: [String: URL] = [:]

    private var remoteInFlight = 0
    private var remoteQueue: [(entry: BrowserEntry, key: String)] = []

    private var shell: DeviceShell?
    private var deviceSerial: String?
    /// 换设备 / 重置时自增；在途任务据此丢弃过期结果。
    private var generation = 0

    // MARK: - 查询

    func state(for entry: BrowserEntry) -> State {
        states[Self.cacheKey(entry)] ?? .idle
    }

    /// 会生成缩略图的类型。**判据在 `ThumbnailPolicy` 里** —— 两侧的能力不同，
    /// 远端只做图片（理由与实测数据在那个类型上）。这里只负责把条目的来源分派过去。
    static func isThumbnailable(_ entry: BrowserEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        switch entry.origin {
        case .local:
            return ThumbnailPolicy.allowsLocalFile(named: entry.name)
        case .remote:
            return ThumbnailPolicy.allowsRemoteFile(named: entry.name)
        case .photo:
            // 照片图库条目的 path 是 localIdentifier，不是文件路径；其缩略图要走
            // PhotoKit（PHImageManager），不在本轮范围内，见改造方案 §4.1 的执行状态。
            return false
        }
    }

    /// 缓存键带上修改时间与大小：覆盖上传 / 同名替换后自动失效，不需要手动清缓存。
    private static func cacheKey(_ entry: BrowserEntry) -> String {
        let stamp = entry.modified?.timeIntervalSince1970 ?? 0
        return "\(entry.id)|\(stamp)|\(entry.size ?? -1)"
    }

    // MARK: - 设备切换

    func updateDevice(shell: DeviceShell?, serial: String?) {
        if serial != deviceSerial {
            deviceSerial = serial
            reset()
        }
        self.shell = shell
    }

    func reset() {
        generation += 1
        for url in scratchFiles.values {
            try? FileManager.default.removeItem(at: url)
        }
        states.removeAll()
        recency.removeAll()
        scratchFiles.removeAll()
        remoteQueue.removeAll()
    }

    // MARK: - 请求

    func request(_ entry: BrowserEntry) {
        guard Self.isThumbnailable(entry) else { return }
        let key = Self.cacheKey(entry)
        // 已在缓存或正在生成：不重复发起。
        guard states[key] == nil else { return }

        states[key] = .loading
        recency.append(key)

        switch entry.origin {
        case .local:
            startLocal(entry, key: key)
        case .remote:
            enqueueRemote(entry, key: key)
        case .photo:
            // isThumbnailable 已挡掉，这里只为穷尽 switch。
            states[key] = .unavailable
        }
    }

    private func startLocal(_ entry: BrowserEntry, key: String) {
        let url = URL(fileURLWithPath: entry.path)
        let currentGeneration = generation
        Task {
            let image = await Self.generate(from: url).image
            guard generation == currentGeneration else { return }
            finish(key: key, image: image, scratch: nil)
        }
    }

    private func enqueueRemote(_ entry: BrowserEntry, key: String) {
        if remoteInFlight < ThumbnailConstants.maxConcurrentRemote {
            startRemote(entry, key: key)
        } else if remoteQueue.count < ThumbnailConstants.queueLimit {
            remoteQueue.append((entry, key))
        } else {
            // 队列满了：直接判不可用，避免快速滚动时的无界堆积。
            states[key] = .unavailable
        }
    }

    private func startRemote(_ entry: BrowserEntry, key: String) {
        remoteInFlight += 1
        let currentGeneration = generation
        let shell = self.shell
        let remotePath = entry.path
        let name = entry.name

        Task {
            // 取头 + 落盘都在主线外：一次 64 KB 的 adb exec-out 不该占住主线程。
            let scratch = await Task.detached(priority: .utility) { () -> URL? in
                guard let shell,
                      let data = shell.fetchHeader(remotePath, maxBytes: ThumbnailConstants.remoteHeaderBytes)
                else { return nil }
                let target = AppPaths.makeThumbnailScratchFile(named: name)
                do {
                    try data.write(to: target)
                } catch {
                    return nil
                }
                return target
            }.value

            let image: NSImage?
            if let scratch {
                image = await Self.generate(from: scratch).image
            } else {
                image = nil
            }

            remoteInFlight -= 1
            guard generation == currentGeneration else {
                if let scratch { try? FileManager.default.removeItem(at: scratch) }
                return
            }
            finish(key: key, image: image, scratch: scratch)
        }
    }

    private func finish(key: String, image: NSImage?, scratch: URL?) {
        if let image {
            states[key] = .loaded(image)
            if let scratch { scratchFiles[key] = scratch }
        } else {
            states[key] = .unavailable
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
        }
        evictIfNeeded()
        drainRemoteQueue()
    }

    private func drainRemoteQueue() {
        while remoteInFlight < ThumbnailConstants.maxConcurrentRemote, !remoteQueue.isEmpty {
            let next = remoteQueue.removeFirst()
            // 期间可能换过目录 / 换过设备，条目已不在缓存里 —— 丢弃。
            guard let state = states[next.key], case .loading = state else { continue }
            startRemote(next.entry, key: next.key)
        }
    }

    private func evictIfNeeded() {
        while recency.count > ThumbnailConstants.capacity, !recency.isEmpty {
            let oldest = recency.removeFirst()
            guard states.removeValue(forKey: oldest) != nil else { continue }
            if let scratch = scratchFiles.removeValue(forKey: oldest) {
                try? FileManager.default.removeItem(at: scratch)
            }
        }
    }

    // MARK: - 生成

    /// 交给 Quick Look 生成，返回 `NSImage`。
    ///
    /// `nonisolated` + 只经 `CGImage` 过界：`NSImage` 不是 `Sendable`，直接把
    /// `QLThumbnailRepresentation` 或 `NSImage` 从非隔离上下文带回 MainActor
    /// 在严格并发下过不了编译。`CGImage` 是不变值，可以安全跨界。
    /// 把缩略图从后台线程交回主线程的载体。
    ///
    /// **为什么需要它**：`NSImage` 至今不是 `Sendable` —— 但不同 SDK 上的判定不一样，
    /// 于是出现「本地编译过、CI 编译不过」：同一份代码在较新的 SDK 上不报，
    /// 而 CI 的 Xcode 16.4 明确报
    /// `non-sendable result type 'NSImage?' cannot be sent from nonisolated context`。
    /// （`ThumbnailStore` 是 `@MainActor`，而 `generate` 是 `nonisolated`，
    /// 结果要跨回主 actor，因此要求 `Sendable`。）
    ///
    /// 这里标 `@unchecked Sendable` 是**断言**而不是掩盖，依据有两条：
    /// ① `QLThumbnailGenerator` 给的是 `CGImage`，本身不可变；
    /// ② 生成的图片交给主线程后**没有任何地方再修改它** —— `finish` 只把它存进缓存并通知视图。
    ///
    /// 另一条路是「后台编成 PNG 字节、主线程再解成 NSImage」（`Data` 天然 `Sendable`），
    /// 但那要给每张缩略图加一次编解码往返，而网格滚动时这个开销是实打实的。不划算。
    private struct ThumbnailImage: @unchecked Sendable {
        let image: NSImage?
    }

    private nonisolated static func generate(from url: URL) async -> ThumbnailImage {
        guard let cgImage = await generateCGImage(from: url) else { return ThumbnailImage(image: nil) }
        return ThumbnailImage(
            image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        )
    }

    private nonisolated static func generateCGImage(from url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: ThumbnailConstants.maxPixelSize, height: ThumbnailConstants.maxPixelSize),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return representation.cgImage
    }
}
