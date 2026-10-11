import Foundation

/// 一个「最近使用 / 已授权」的目录。
///
/// 为什么需要这层：沙盒版**只能**通过「用户亲手选一次」到达任意目录
/// （`com.apple.security.files.user-selected.read-write`，见 `docs/1011_04` §4.4），
/// 而「选一次」必须**跨启动记住** —— 靠的就是 security-scoped bookmark。
///
/// 侧载版不需要授权，但同一份机制顺带提供了「最近使用的目录」，所以两个构建共用一条路
/// （在非沙盒里 `startAccessingSecurityScopedResource` 是空操作，不会有害）。
struct BookmarkedFolder: Codable, Hashable, Sendable {
    /// 显示名（取选择那一刻的 `lastPathComponent`）。
    let name: String
    /// **上次解析到的路径**。
    ///
    /// ⚠️ 它可能过期：bookmark 的好处正是**目录被改名/移动后仍能解析到**，那时这个值就旧了。
    /// 所以它只用于显示与**去重**，每次成功解析后都会被刷新。
    var path: String
    /// security-scoped bookmark（`.withSecurityScope`）。
    let bookmark: Data
    var lastUsed: Date
}

/// 「最近使用」列表的**纯逻辑** + 持久化。
///
/// 纯的那部分是 `merging` / `prune`：合并、去重、置顶、截断。
/// 它们**刻意不碰系统**（不做 bookmark 解析）—— 解析要真去问系统，是另一件事，
/// 放在 `AppModel` 那一层，这样这条列表语义能被 `scripts/check-bookmarked-folders.swift` 钉住。
enum BookmarkedFolders {
    /// 最多记几条。定这个数是因为它只服务于「回到上次传的那个项目文件夹」，
    /// 而不是当收藏夹用；列表长了反而找不到。
    static let limit = 10

    /// 把一项并进列表：**按路径去重 → 置顶 → 盖时间戳 → 截断**。
    ///
    /// - Parameter path: 这一项**刚刚解析出来的**路径（权威值；`incoming.path` 会被它覆盖）
    static func merging(
        _ incoming: BookmarkedFolder,
        resolvedPath path: String,
        into existing: [BookmarkedFolder],
        now: Date
    ) -> [BookmarkedFolder] {
        var item = incoming
        item.path = path
        item.lastUsed = now
        let rest = existing.filter { $0.path != path }
        return prune([item] + rest)
    }

    /// 截断到 `limit`。**假定传入的已经是「最近在前」** —— 这里不再排序，
    /// 因为排序需要日期而列表本来就按使用顺序维护；两处都排一次就会分叉。
    static func prune(_ list: [BookmarkedFolder]) -> [BookmarkedFolder] {
        Array(list.prefix(limit))
    }

    // ── 持久化 ────────────────────────────────────────────────────────────
    //
    // 落在 `AppPaths.supportDirectory`（沙盒里就是容器的 Application Support ⇒ 一定可写）。
    // 读写失败一律**当作空列表 / 静默忽略**：这层坏了顶多是「记不住上次的目录」，
    // 不该把启动路径弄崩。
    //
    // 位置**做成参数**（而不是把 `storeURL` 写死在调用点）是为了让守卫能用临时文件**真跑一遍
    // 存取往返** —— 否则测它就得写进用户真实的那一份，那既不干净、也会被别的运行覆盖。

    static var storeURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("recent-folders.json")
    }

    static func load(from url: URL = storeURL) -> [BookmarkedFolder] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BookmarkedFolder].self, from: data)).map(prune) ?? []
    }

    static func save(_ list: [BookmarkedFolder], to url: URL = storeURL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(prune(list)) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
