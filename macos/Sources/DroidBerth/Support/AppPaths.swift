import Foundation

enum AppPaths {
    static let bundleIdentifier = "dev.tango.droidberth"

    static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base.appendingPathComponent("DroidBerth", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var stagingDirectory: URL {
        let directory = supportDirectory.appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var reportsDirectory: URL {
        let directory = supportDirectory.appendingPathComponent("Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Quick Look 预览的临时落地目录（PRD §23：`$TMPDIR/DroidBerth/preview/`）。
    ///
    /// 刻意不放在 `supportDirectory` 下：预览文件是一次性的、可能很大，交给系统
    /// 按 `$TMPDIR` 的规则回收比留在 Application Support 里更合适。
    static var previewDirectory: URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidBerth", isDirectory: true)
            .appendingPathComponent("preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 为一次预览分配落地路径。
    ///
    /// 每次预览放进独立的 UUID 子目录：一来同名文件不会互相覆盖，二来文件名
    /// 原样保留（Quick Look 靠扩展名挑选预览器，改名会退化成通用图标）。
    static func makePreviewItem(named name: String) -> URL {
        let directory = previewDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    /// 网格缩略图的临时落地目录（PRD §13.3）。
    ///
    /// 与预览同理放在 `$TMPDIR` 下而不是 Application Support：远端缩略图要先落成
    /// 文件才能交给 `QLThumbnailGenerator`，这些文件是一次性的，交给系统按临时目录
    /// 规则回收最省心。
    static var thumbnailDirectory: URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidBerth", isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 为一张远端缩略图分配落地文件。
    ///
    /// 用**扁平**的 UUID 文件名 + 原扩展名，而不是每张一个子目录：缩略图数量可能
    /// 成百上千，一个子目录一个文件会让目录项数量翻倍。UUID 前缀避免同名覆盖，
    /// 扩展名必须保留 —— `QLThumbnailGenerator` 靠它挑解码器。
    static func makeThumbnailScratchFile(named name: String) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = UUID().uuidString
        let filename = ext.isEmpty ? stem : "\(stem).\(ext)"
        return thumbnailDirectory.appendingPathComponent(filename)
    }

    /// 清空缩略图缓存目录。启动时调一次。
    static func clearThumbnails() {
        clear(directory: thumbnailDirectory)
    }

    /// 清空预览缓存。启动时调一次，之后每次新预览前（面板已关时）再调一次，
    /// 避免临时目录在一次会话里无限增长。
    static func clearPreviews() {
        clear(directory: previewDirectory)
    }

    static func makeStagingItem(named name: String) -> URL {
        let directory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    static func makeBatchDirectory() -> URL {
        let directory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func clearStaging() {
        clear(directory: stagingDirectory)
    }

    /// 清空一个目录下的**直接子项**。预览 / 暂存 / 缩略图三处的清理逻辑本是一份。
    private static func clear(directory: URL) {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            try? fileManager.removeItem(at: item)
        }
    }
}
