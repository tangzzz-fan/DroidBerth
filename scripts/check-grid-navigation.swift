import Foundation

// 网格视图键盘导航的回归核对（PRD §13.3）。
//
// 它要挡住的是**前一族缺陷的第三种形态**：
//
//   ① `check-icon-mapping` 挡「同一份事实写两遍之后分叉」；
//   ② `check-transfer-semantics` 挡「同一个概念在两端语义不同，代码只按一端写」；
//   ③ 这一份挡「**同一个列表在视图里排一次、在键盘逻辑里再排一次**」。
//
// 第 ③ 种是补键盘导航时新出现的风险：方向键按**屏幕上的次序**走，而「屏幕上的次序」
// 现在有两个使用者 —— `EntryGrid` 的 `LazyVGrid` 与 `AppModel.moveGridSelection`。
// 两边各写一份排序（或各算一遍列数），误差不会报错、也不会崩，只会**让 ↓ 跳到
// 肉眼看不见的地方**。所以两件东西各占一个纯函数，这份清单就是它们的契约：
//
//   · `GridNavigation.order`       —— 显示顺序（视图与模型共用同一份）
//   · `GridNavigation.columnCount` —— 一屏几列（↑ / ↓ 按它跳）
//
// 为什么是独立脚本而不是测试 target：本项目没有测试 target（见 `0926_03` §5.3）。
//
// 跑法（不需要 Rust / adb，约 5 秒）：
//
//     mkdir -p /tmp/gridcheck && cp scripts/check-grid-navigation.swift /tmp/gridcheck/main.swift
//     swiftc -O -o /tmp/gridcheck/run \
//       -target arm64-apple-macos14.0 \
//       -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
//       -swift-version 6 -strict-concurrency=complete \
//       -Xfrontend -disable-sandbox \
//       macos/Sources/DroidBerth/Support/GridNavigation.swift \
//       macos/Sources/DroidBerth/Support/NameComparison.swift \
//       macos/Sources/DroidBerth/Support/BrowserEntry.swift \
//       /tmp/gridcheck/main.swift && /tmp/gridcheck/run
//
// 注意 **必须叫 `main.swift`**（顶层代码只允许在这个文件名里），
// 且 helper 要标 `@MainActor`（Swift 6 下顶层代码是 MainActor 隔离的）。

var failures: [String] = []

@MainActor
func check(_ label: String, _ got: Bool, _ want: Bool) {
    if got != want { failures.append("\(label)：得到 \(got)，期望 \(want)") }
}

@MainActor
func checkEqual<T: Equatable>(_ label: String, _ a: T, _ b: T) {
    if a != b { failures.append("\(label)：\(a) ≠ \(b)") }
}

@MainActor
func entry(_ name: String, directory: Bool = false) -> BrowserEntry {
    BrowserEntry(
        origin: .remote,
        name: name,
        path: "/sdcard/DCIM/" + name,
        isDirectory: directory,
        size: 1024,
        modified: nil,
        kindLabel: directory ? "文件夹" : "JPEG 图像",
        systemImage: directory ? "folder" : "photo"
    )
}

// ─────────────────────────────────────────────────────────────
// ① order：显示顺序
// ─────────────────────────────────────────────────────────────

let unsorted = [
    entry("sunrise.jpg"),
    entry("Movies", directory: true),
    entry("beach.png"),
    entry("Camera", directory: true),
    entry("sunset.jpg"),
]

let foldersFirst = GridNavigation.order(unsorted, foldersFirst: true)
checkEqual("order(foldersFirst) 名称序", foldersFirst.map(\.name),
           ["Camera", "Movies", "beach.png", "sunrise.jpg", "sunset.jpg"])

// 关掉「文件夹排在最前」时只看名字 —— 不能因为关了就变回原顺序（那是「没排」）
let byNameOnly = GridNavigation.order(unsorted, foldersFirst: false)
checkEqual("order(!foldersFirst) 名称序", byNameOnly.map(\.name),
           ["beach.png", "Camera", "Movies", "sunrise.jpg", "sunset.jpg"])

// **同一个列表排两次必须得到同一个结果** —— 这条是「视图与键盘不会分叉」的最小判据。
// 视图侧调用的是同一个函数，这里钉的是它的纯粹性（不依赖输入顺序）。
check("order 与输入顺序无关",
      GridNavigation.order(unsorted, foldersFirst: true).map(\.id)
        == GridNavigation.order(Array(unsorted.reversed()), foldersFirst: true).map(\.id), true)

// 空列表不能崩 —— 空目录是常态（新克隆的设备、刚建的空文件夹）。
checkEqual("order(空)", GridNavigation.order([], foldersFirst: true).count, 0)

// ─────────────────────────────────────────────────────────────
// ② columnCount：一屏几列
//
// 公式必须与 `.adaptive(minimum: cellWidth, maximum: cellWidth * 1.4)` 的实际铺列一致：
//   ⌊(可用宽 + 间距) / (最小列宽 + 间距)⌋
// 下面这组数是按 72pt 图标（最窄档，cellWidth = 106）算的。
// ─────────────────────────────────────────────────────────────

checkEqual("columnCount(1000, 106, 12)", GridNavigation.columnCount(width: 1000, cellWidth: 106, spacing: 12), 8)
checkEqual("columnCount(118, 106, 12) 恰好一列", GridNavigation.columnCount(width: 118, cellWidth: 106, spacing: 12), 1)
checkEqual("columnCount(117, 106, 12) 差 1pt 仍是一列", GridNavigation.columnCount(width: 117, cellWidth: 106, spacing: 12), 1)
checkEqual("columnCount(236, 106, 12) 恰好两列", GridNavigation.columnCount(width: 236, cellWidth: 106, spacing: 12), 2)
// 窗口被拖到极窄 / 宽度还没量出来时兜底成 1 —— 不能返回 0（会变成「↑ / ↓ 不动」）
checkEqual("columnCount(0) 兜底", GridNavigation.columnCount(width: 0, cellWidth: 106, spacing: 12), 1)
checkEqual("columnCount(50) 兜底", GridNavigation.columnCount(width: 50, cellWidth: 106, spacing: 12), 1)
// 间距为 0 也不能除零
checkEqual("columnCount(间距 0)", GridNavigation.columnCount(width: 212, cellWidth: 106, spacing: 0), 2)

// ─────────────────────────────────────────────────────────────
// ③ targetIndex：方向键落在哪一项
//
// 左右是**线性**的（Finder 图标视图语义：一行走到底接下一行），
// 上下按列数跳。两端一律夹住 —— **不环绕**：首项再按 ← 停在原地，
// 最后一行的 ↓ 落在最后一项（而不是「没反应」）。
// ─────────────────────────────────────────────────────────────

checkEqual("left 在首项不回绕", GridNavigation.targetIndex(from: 0, move: .left, columns: 4, count: 10), 0)
checkEqual("left 普通", GridNavigation.targetIndex(from: 5, move: .left, columns: 4, count: 10), 4)
checkEqual("right 普通", GridNavigation.targetIndex(from: 5, move: .right, columns: 4, count: 10), 6)
checkEqual("right 在末项不回绕", GridNavigation.targetIndex(from: 9, move: .right, columns: 4, count: 10), 9)
checkEqual("up 整行", GridNavigation.targetIndex(from: 6, move: .up, columns: 4, count: 10), 2)
checkEqual("up 越界夹到首项", GridNavigation.targetIndex(from: 1, move: .up, columns: 4, count: 10), 0)
checkEqual("down 整行", GridNavigation.targetIndex(from: 2, move: .down, columns: 4, count: 10), 6)
checkEqual("down 越界夹到末项", GridNavigation.targetIndex(from: 8, move: .down, columns: 4, count: 10), 9)
// 列数取不到时按 1 列（退化成一维移动）—— 宁可慢，不能跳到别处
checkEqual("columns 0 退化成一维", GridNavigation.targetIndex(from: 3, move: .down, columns: 0, count: 10), 4)
// 索引越界（锚点指向的条目刚被删掉）时按边界处理，不返回失败态
checkEqual("from 越界夹住", GridNavigation.targetIndex(from: 99, move: .left, columns: 4, count: 10), 8)
checkEqual("count 0 不崩", GridNavigation.targetIndex(from: 0, move: .down, columns: 4, count: 0), 0)

// ─────────────────────────────────────────────────────────────
// ④ typeSelectIndex：敲字母跳转
//
// 三件事必须成立：大小写不敏感、`from` 决定起点（因此连敲同一个字母会轮转）、
// **没命中返回 nil**（调用方据此把按键交还系统，不会变成「按了没反应」）。
// ─────────────────────────────────────────────────────────────

let named = [entry("beach.png"), entry("sunset.jpg"), entry("doc.pdf"), entry("sea.jpg")]

checkEqual("typeSelect sun → sunset", GridNavigation.typeSelectIndex("sun", in: named, from: 0), 1)
checkEqual("typeSelect SUN 大小写不敏感", GridNavigation.typeSelectIndex("SUN", in: named, from: 0), 1)
checkEqual("typeSelect s 从 0 起", GridNavigation.typeSelectIndex("s", in: named, from: 0), 1)
// 这就是「连敲同一个字母在命中项之间轮转」：起点落在 sunset 之后，于是轮到 sea
checkEqual("typeSelect s 从 2 起 → sea", GridNavigation.typeSelectIndex("s", in: named, from: 2), 3)
checkEqual("typeSelect 起点越界绕回", GridNavigation.typeSelectIndex("s", in: named, from: 9), 1)
checkEqual("typeSelect d → doc", GridNavigation.typeSelectIndex("d", in: named, from: 1), 2)
checkEqual("typeSelect 无命中返回 nil", GridNavigation.typeSelectIndex("zzz", in: named, from: 0), nil)
checkEqual("typeSelect 空表返回 nil", GridNavigation.typeSelectIndex("s", in: [], from: 0), nil)
// 起点负数（光标在「第一个之前」，即 `(nil ?? -1) + 1 == 0` 的相邻情形）也不能崩
checkEqual("typeSelect from 负数绕回", GridNavigation.typeSelectIndex("b", in: named, from: -2), 0)

// 折叠复用 `NameComparison.folded`：那是全项目唯一的折叠加配方，
// type-select 不该有第二份。所以设备端会折叠的写法在这里也要能命中。
let foldable = [entry("ß.txt"), entry("ﬁle.txt")]
checkEqual("typeSelect ß↔ss 折叠", GridNavigation.typeSelectIndex("ss", in: foldable, from: 0), 0)
checkEqual("typeSelect ﬁ↔fi 折叠", GridNavigation.typeSelectIndex("fi", in: foldable, from: 0), 1)
// 而设备端**不**折叠的（é 与 e、全角与半角）在这里同样不该命中 —— 判据与上传冲突检测一致
checkEqual("typeSelect é↔e 不折叠", GridNavigation.typeSelectIndex("e", in: [entry("é.txt")], from: 0), nil)

// ─────────────────────────────────────────────────────────────

print("覆盖：order（文件夹优先 / 名称序 / 纯粹性）· columnCount（7 档宽度）· "
      + "targetIndex（左右线性、上下整行、两端夹住）· typeSelect（大小写 / 起点 / 折叠 / 无命中）")
if failures.isEmpty {
    print("ALL OK")
} else {
    print("FAILURES (\(failures.count)):")
    for item in failures { print("  - \(item)") }
    exit(1)
}
