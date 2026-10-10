import AppKit
import Foundation

/// 文件类型图标的**唯一事实来源**。
///
/// 这一族缺陷的形状是「同一个概念在两端语义不同，代码只按一端写」。改造前
/// `LocalEntry.systemImage` 与 `RemoteEntry.systemImage` 各写了一条 switch，看着像
/// 复制粘贴，**实际已经分叉**：
///
/// | 扩展名 | 改造前（Mac 栏） | 改造前（设备栏） |
/// | --- | --- | --- |
/// | `.apk` | `doc`（通用文稿） | `shippingbox`（盒子） |
/// | `.app` | `app` | `doc`（通用文稿） |
///
/// 同一个文件在同一屏的两栏显示不同图标，而且**没有任何编译错误或测试会告诉你**。
///
/// 现在只有一张表，两栏共用（`support/FileTypeIcon`）。
///
/// ## 两条路径，各管一栏（PRD §8 原则一）
///
/// | 栏 | 路径 | 为什么 |
/// | --- | --- | --- |
/// | 本机 | `NSWorkspace` 的系统彩色图标（`FileIconCache`） | 文件**真实存在**，交给系统零维护，顺带白拿替身角标与 App 包的图标 |
/// | 设备 | 下面这张「完整扩展名精确匹配 → SF Symbol」表 | 条目只是 `adb shell ls` 列出的一行，本机**没有对应文件**，问 `NSWorkspace` 只能拿到笼统的通用图标 |
///
/// ## 新增符号的判据（三条同时成立才加）
///
/// ① 用户会对它做出**不同的动作**；② 在目标用户的文件里**高频**；
/// ③ SF Symbols 里有一个**现成的、16pt 下与已有符号可辨**的符号。
/// **③ 不过就合并 —— 不要为了凑一个图标去自绘。**
///
/// 据此只新增了 3 个符号（`tablecells` / `opticaldisc` / 代码斜杠），
/// 其余刻意并入现有符号，理由逐条写在 `docs/design/DESIGN.md`。
enum FileTypeIcon {
    /// 通用兜底：未命中任何规则时的文稿图标。
    static let fallbackSymbol = "doc"
    static let directorySymbol = "folder.fill"

    /// 完整扩展名（不含点、已小写）→ SF Symbol。
    ///
    /// **必须是完整扩展名的精确匹配**，不能截前缀 —— 否则 `m4a` 会被 `m4` 吞掉。
    /// 扩展名不与类型一一对应时的取舍见 `docs/design/DESIGN.md`「已知冲突」。
    static let symbolByExtension: [String: String] = {
        var table: [String: String] = [:]
        func put(_ symbol: String, _ extensions: [String]) {
            for ext in extensions { table[ext] = symbol }
        }

        put("photo", ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp",
                      "tif", "tiff", "bmp", "avif", "svg",
                      "dng", "raw", "cr2", "nef", "arw"])
        put("film", ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "3gp", "ts"])
        put("waveform", ["mp3", "wav", "aac", "flac", "m4a", "ogg", "opus", "wma"])
        put("doc.richtext", ["pdf", "rtf"])
        put("tablecells", ["xls", "xlsx", "csv", "numbers"])
        put("doc.text", ["txt", "md", "log", "doc", "docx", "pages", "ppt", "pptx", "key"])
        put("doc.zipper", ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"])
        put("opticaldisc", ["dmg", "iso"])
        put("shippingbox", ["apk", "aab", "ipa", "exe"])
        put("chevron.left.forwardslash.chevron.right",
            ["json", "xml", "yaml", "yml", "toml", "plist",
             "sh", "py", "js", "tsx", "swift", "rs", "html", "css"])

        // 刻意**不**单列的：
        // - 全部图片格式共用一个「照片」（heic 与 jpg 给不同图标是纯噪声）
        // - RAW 不单独给符号：能不能推、手机能不能开是运行时才知道的事，
        //   该由文案回答，**不该由图标承诺**
        // - 全部视频 / 音频容器共用一个「胶片」/「波形」（容器差异对用户不可见）
        // - 无扩展名与未知类型共用 `fallbackSymbol`，靠「种类」列区分
        // - 演示文稿并入 `doc.text`（设备侧几乎不出现，且找不到既准确又 16pt 可辨的符号）
        // - `aab` / `ipa` / `exe` 并入 `shippingbox`：**不要用图标表达
        //   「这个不能推到 Android」**，那是禁用态与文案的职责
        return table
    }()

    /// 符号解析。**两栏共用这一个入口**，差异只在渲染层（彩色 / 单色）。
    ///
    /// - Note: 目录优先于扩展名 —— 名字叫 `foo.txt` 的**文件夹**仍然是文件夹。
    static func symbol(forName name: String, isDirectory: Bool) -> String {
        if isDirectory { return directorySymbol }
        let ext = name.pathExtensionLowercased
        guard !ext.isEmpty else { return fallbackSymbol }
        return symbolByExtension[ext] ?? fallbackSymbol
    }

    /// 是否属于「照片 / 视频」—— 缩略图通道与网格回退共用这一条判据。
    ///
    /// 刻意从 `String.isVideoFile` / `isImageFile` 转发而不是另写一份：那两个扩展名
    /// 集合已经存在，多一份就是下一个 `.apk` 分叉。
    static func isVisualMedia(name: String) -> Bool {
        name.isImageFile || name.isVideoFile
    }
}

/// 本机文件图标的缓存（策略乙的「彩色」那一半）。
///
/// 为什么必须有缓存：`NSWorkspace.icon(forFile:)` 是一次 LaunchServices 查询，
/// 列表一屏 200 行、滚动时每帧都会重新求值 —— 不能每次去问系统。
///
/// 为什么是 `@MainActor`：`NSCache` 不是 `Sendable`，放在非隔离的 `static let` 里
/// 在 Swift 6 严格并发下过不了编译。视图本来就在主线程，隔离在这里没有代价。
///
/// 为什么与 `FileTypeIcon` 分成两个类型：`FileTypeIcon.symbol(...)` 是纯函数，
/// 会被 `LocalFileSystem.list()` 这类**可能不在主线程**的路径调用；把两者混在一个
/// 类型里会让整个符号表被 `@MainActor` 传染，`list()` 当场编译不过。
@MainActor
enum FileIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 800
        return cache
    }()

    /// 系统彩色图标。返回 nil 时由视图回退到 `FileTypeIcon` 的单色符号。
    static func icon(forPath path: String) -> NSImage? {
        let key = path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        // `NSWorkspace` 对不存在的路径也会返回一个通用图标，那对界面没有信息量；
        // 但**不能**据此返回 nil —— 权限受限的路径同样查不到属性却是真实条目。
        cache.setObject(icon, forKey: key)
        return icon
    }
}
