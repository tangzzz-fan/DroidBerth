import Foundation

// 「已授权 / 最近使用」目录列表的回归核对（docs/1011_04 §4.4 与 E7）。
//
// 它挡的是**第五种形态**的缺陷：**「记忆」本身的语义错**。
//
// ①②③④ 分别挡的是：同一事实写两遍分叉 / 两端语义不同 / 同列在视图与键盘各排一次 /
// 只对某一种运行环境生效的分支。这一份挡的是另一种：
//
//   **一条列表的「合并规则」写错了，而且要过几次使用才看得出来。**
//   「最近使用」的错法都很安静：去重键选错（按名字而不是路径）会让两个同名目录互相顶掉；
//   置顶没做会让用户「刚选过的目录掉到后面」；截断在合并**之前**做会丢掉刚选的那一项……
//   这些都不会报错，只会让用户觉得「它老是记不住」。
//
// 纯的那部分（`merging` / `prune`）是刻意的：它们不碰 bookmark 解析（那要问系统），
// 所以能在这里用构造出来的数据直接喂。**存取往返**也用临时文件真跑一遍 ——
// 不碰用户真实那份 `recent-folders.json`。
//
// 跑法（不需要 Rust / adb，约 3 秒）：
//
//     mkdir -p /tmp/bmcheck && cp scripts/check-bookmarked-folders.swift /tmp/bmcheck/main.swift
//     swiftc -O -o /tmp/bmcheck/run \
//       -target arm64-apple-macos14.0 \
//       -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
//       -swift-version 6 -strict-concurrency=complete \
//       macos/Sources/DroidBerth/Support/BookmarkedFolders.swift \
//       macos/Sources/DroidBerth/Support/AppPaths.swift \
//       /tmp/bmcheck/main.swift && /tmp/bmcheck/run
//
// 注意 **必须叫 `main.swift`**（顶层代码只允许在这个文件名里），
// 且 helper 要标 `@MainActor`（Swift 6 下顶层代码是 MainActor 隔离的）。

var failures: [String] = []

@MainActor
func check(_ label: String, _ got: Bool, _ want: Bool) {
    if got != want { failures.append("\(label)  期望 \(want)，实际 \(got)") }
}

@MainActor
func checkEqual<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    if got != want { failures.append("\(label)  期望 \(want)，实际 \(got)") }
}

func folder(_ name: String, path: String, used: Date) -> BookmarkedFolder {
    BookmarkedFolder(name: name, path: path, bookmark: Data(name.utf8), lastUsed: used)
}

let base = Date(timeIntervalSince1970: 1_700_000_000)
let later = base.addingTimeInterval(3600)

// ── ① 合并：空列表进来一项 ────────────────────────────────────────────────
let fresh = folder("项目素材 2026", path: "/Volumes/SSD/项目素材 2026", used: .distantPast)
let one = BookmarkedFolders.merging(fresh, resolvedPath: "/Volumes/SSD/项目素材 2026",
                                   into: [], now: base)
checkEqual("空列表 + 一项 ⇒ 一项", one.count, 1)
checkEqual("时间戳用 now，不用进来的旧值", one[0].lastUsed, base)

// ── ② 合并：已经存在的那一项要**置顶并刷新**，而不是重复 ────────────────────────
let b = folder("B", path: "/x/B", used: base)
let c = folder("C", path: "/x/C", used: base)
let list = [b, c]
let reAdded = BookmarkedFolders.merging(c, resolvedPath: "/x/C", into: list, now: later)
checkEqual("重复选已存在的 ⇒ 条数不变", reAdded.count, 2)
checkEqual("重复选的那一项置顶", reAdded[0].path, "/x/C")
checkEqual("它拿到了新时间戳", reAdded[0].lastUsed, later)
checkEqual("其余保持原顺序", reAdded[1].path, "/x/B")

// ── ③ 去重键是**路径**，不是名字 ───────────────────────────────────────────
// 两个同名但不同路径的目录必须都在。按名字去重是这类列表最典型的错法。
let s1 = folder("素材", path: "/Volumes/A/素材", used: base)
let s2 = folder("素材", path: "/Volumes/B/素材", used: later)
let sameName = BookmarkedFolders.merging(s2, resolvedPath: "/Volumes/B/素材", into: [s1], now: later)
checkEqual("同名不同路径 ⇒ 都留着", sameName.count, 2)

// ── ④ 新解析出的路径是**权威值**：书签能跟着目录移动，旧 path 要刷新 ─────────────
let moved = BookmarkedFolders.merging(
    folder("素材", path: "/old/位置", used: base),
    resolvedPath: "/new/位置", into: [], now: base)
checkEqual("path 用解析结果覆盖", moved[0].path, "/new/位置")

// ── ⑤ 截断：上限 10，且**先合并再截断**（先截断会把刚选的那一项丢掉）──────────
var many: [BookmarkedFolder] = []
for i in 0..<12 { many.append(folder("f\(i)", path: "/p/\(i)", used: base)) }
checkEqual("prune 截到 limit", BookmarkedFolders.prune(many).count, BookmarkedFolders.limit)
checkEqual("prune 保留的是**最前面**那些（最近在前）", BookmarkedFolders.prune(many)[0].path, "/p/0")

let overflow = BookmarkedFolders.merging(
    folder("new", path: "/p/new", used: base), resolvedPath: "/p/new", into: many, now: later)
checkEqual("溢出时条数被截断", overflow.count, BookmarkedFolders.limit)
checkEqual("**刚选的那一项仍在最前**（这是「先合并再截断」的意义）", overflow[0].path, "/p/new")

// ── ⑥ 存取往返（临时文件，不碰用户真实那份）──────────────────────────────
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("droidberth-bm-check-\(UUID().uuidString)")
    .appendingPathComponent("recent-folders.json")
BookmarkedFolders.save(sameName, to: tmp)
let reloaded = BookmarkedFolders.load(from: tmp)
checkEqual("往返后条数一致", reloaded.count, sameName.count)
checkEqual("往返后路径一致", reloaded.map(\.path), sameName.map(\.path))
// 日期要能原样回来 —— `JSONEncoder` 的日期策略写错时，这里会静默变成 2001 年。
checkEqual("往返后最近一项的时间戳一致", reloaded[0].lastUsed, sameName[0].lastUsed)
checkEqual("往返后书签字节一致", reloaded[0].bookmark, sameName[0].bookmark)
try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())

// ── ⑦ 坏文件 / 不存在都不该崩：当作空列表 ─────────────────────────────────
let missing = BookmarkedFolders.load(from: tmp)
checkEqual("读不到 ⇒ 空列表（不崩）", missing.count, 0)

// ── ⑧ 解析分类：可用的与失效的**必须分开**（E7 的启动恢复靠它）───────────────
// 书签会失效（目录被删、外置卷没插、权限被回收）。分类错了有两种坏结果：
// 把坏的当好的 ⇒ 启动落在不存在的路径上；把好的丢掉 ⇒ 用户每次开机都要重选。
let a1 = folder("A", path: "/x/A", used: later)
let bad = folder("坏", path: "/x/gone", used: base)
let a2 = folder("B", path: "/x/B", used: base)
// 用 path 模拟系统的解析成败 —— 真造一个坏 bookmark 很难稳定复现。
let canResolve: (BookmarkedFolder) -> URL? = { item in
    item.path.contains("gone") ? nil : URL(fileURLWithPath: item.path)
}

let allGood = BookmarkedFolders.resolveAll([a1, a2], using: canResolve)
checkEqual("全可解析 ⇒ resolved 全收", allGood.resolved.count, 2)
checkEqual("全可解析 ⇒ stale 为空", allGood.stale.count, 0)
checkEqual("first 是列表第一项（最近使用在前）", allGood.first?.folder.path, "/x/A")

let mixed = BookmarkedFolders.resolveAll([a1, bad, a2], using: canResolve)
checkEqual("中间坏一个 ⇒ resolved 仍是两项", mixed.resolved.count, 2)
checkEqual("坏的那个进 stale（调用方据此清掉）", mixed.stale.map(\.path), ["/x/gone"])
checkEqual("resolved 保持原顺序", mixed.resolved.map(\.folder.path), ["/x/A", "/x/B"])

// 这条是重点：**第一个坏了不能就此放弃** —— 那正是「上次的目录打不开了，
// 于是整个列表都不恢复」这种体验的来源。
let firstBad = BookmarkedFolders.resolveAll([bad, a2], using: canResolve)
checkEqual("第一项就坏 ⇒ first 顺延到第二项", firstBad.first?.folder.path, "/x/B")

let allBad = BookmarkedFolders.resolveAll(
    [bad, folder("坏2", path: "/y/gone", used: base)], using: canResolve)
checkEqual("全坏 ⇒ resolved 空", allBad.resolved.count, 0)
checkEqual("全坏 ⇒ stale 收全", allBad.stale.count, 2)
check("全坏 ⇒ first 为 nil（调用方据此进「失效」状态）", allBad.first == nil, true)

check("空列表 ⇒ first 为 nil", BookmarkedFolders.resolveAll([], using: canResolve).first == nil, true)

// ─────────────────────────────────────────────────────────────

print("覆盖：合并（空 / 重复置顶 / 刷新时间戳）· 去重键（路径而非名字）· 解析路径为权威值 · "
      + "截断上限与「先合并再截断」· 存取往返（含日期策略）· 读不到时不崩 · "
      + "解析分类（全好 / 中间坏 / 第一项坏 / 全坏 / 空）")
if failures.isEmpty {
    print("ALL OK")
} else {
    print("FAILURES (\(failures.count)):")
    for item in failures { print("  - \(item)") }
    exit(1)
}
