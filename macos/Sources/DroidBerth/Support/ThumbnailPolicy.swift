import Foundation

/// 哪一类条目值得去生成缩略图（PRD §13.3）。
///
/// 判据**按来源分叉，因为两侧的能力真的不同** —— 这是这个类型存在的全部理由：
///
/// - **本地**：文件真实存在，`QLThumbnailGenerator` 对图片**和视频**都能出图
///   （实测完整文件 8/8 全通过）。所以本地全做。
/// - **远端**：只能靠 `DeviceShell.fetchHeader` 拉 **64 KB 文件头**。实测
///   （Android 17 / API 37，`docs/1011_01_device-acceptance-report.md` §1）：
///
///   | 类型 | 64 KB 头 | 要多少才够 |
///   | --- | --- | --- |
///   | jpg / png / heic | **能出图** | 64 KB |
///   | gif | 不能 | 1 MB |
///   | tiff | 不能 | 整个文件（实测那个 15.7 MB） |
///   | 视频（mp4 / mov …） | 不能 | faststart 要 1 MB，`moov` 在文件尾要整个文件 |
///
///   ⇒ 远端**只做图片**，并且**不试**那三个已知必失败的类型。
///
/// ## 为什么远端不做视频（这是刻意的产品决定，不是漏做）
///
/// 视频能不能出图取决于容器里 `moov` box 的位置 —— 用户**既看不见也猜不到**。
/// 后果是同一批视频里「有的有缩略图、有的没有」，而且看起来完全随机。
/// **稳定地没有，好过不稳定地有**：前者用户能建立预期（视频就是类型图标），
/// 后者只会让人觉得这个 app 时好时坏。要恢复视频预览，应该另开一条**能保证成功**的
/// 通道（例如按需下载完整文件），而不是把取头量往上加着碰运气。
///
/// ## 为什么连 gif / tiff 都不试
///
/// 失败是**结构性**的（GIF 要读到 trailer、TIFF 的 strip 数据在尾部），不是数据个例，
/// 所以是「已知就不试」而不是「试了再说」。省下的不只是一次 64 KB 往返：
/// `EntryGrid` 在 `.loading` 时显示 `ProgressView`，不发起请求就直接落到类型图标，
/// 于是也省掉了「转圈 → 还是类型图标」的闪烁。
///
/// 回退本身始终成立：类型图标，不留空白（PRD §13.3 明文要求）。
enum ThumbnailPolicy {
    /// 远端这条 64 KB 通道上实测**必然失败**的图片类型。
    ///
    /// 名单故意保持最小 —— 只放**实测过、且失败原因是结构性**的那三个。
    /// `webp` / `bmp` / `dng` / `raw` 等未实测，仍让它们走一次（成本 64 KB，
    /// 换一个可能存在的缩略图是划算的）。
    private static let remoteNeverWorks: Set<String> = ["gif", "tif", "tiff"]

    /// 本地文件：图片与视频都做（文件就在本机，`QLThumbnailGenerator` 两条都能出图）。
    static func allowsLocalFile(named name: String) -> Bool {
        name.isImageFile || name.isVideoFile
    }

    /// 设备端条目：只做图片，且排除已知必失败的。
    static func allowsRemoteFile(named name: String) -> Bool {
        name.isImageFile && !remoteNeverWorks.contains(name.pathExtensionLowercased)
    }

    /// 该类型在远端这条通道上是否**已知必失败**（供测试与界面判断用）。
    static func isKnownRemoteFailure(named name: String) -> Bool {
        remoteNeverWorks.contains(name.pathExtensionLowercased)
    }
}
