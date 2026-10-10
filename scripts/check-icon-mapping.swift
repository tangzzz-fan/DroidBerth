import Foundation

// 文件类型图标映射的回归核对。
//
// 它要证伪的是一类**静默**缺陷：同一份事实写两遍之后分叉。改造前
// `LocalEntry.systemImage` 与 `RemoteEntry.systemImage` 各有一条 switch，
// 看着像复制粘贴，实际已经分叉：
//
//     .apk   Mac 栏 = doc（通用文稿）   设备栏 = shippingbox（盒子）
//     .app   Mac 栏 = app              设备栏 = doc（通用文稿）
//
// 同一个文件在同一屏的两栏显示不同图标，而且**没有任何编译错误会告诉你**。
// 现在两栏走同一个入口（`FileTypeIcon.symbol(forName:isDirectory:)`），
// 这份清单就是那个入口的契约。
//
// 为什么是一个独立脚本而不是测试 target：本项目没有测试 target（见 `0926_03` §5.3）。
//
// 跑法（不需要 Rust / adb，约 5 秒）：
//
//     mkdir -p /tmp/iconcheck && cp scripts/check-icon-mapping.swift /tmp/iconcheck/main.swift
//     swiftc -O -o /tmp/iconcheck/run \
//       -target arm64-apple-macos14.0 \
//       -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
//       -swift-version 6 -strict-concurrency=complete \
//       -Xfrontend -disable-sandbox \
//       macos/Sources/DroidBerth/Support/FileTypeIcon.swift \
//       macos/Sources/DroidBerth/Support/ByteFormat.swift \
//       /tmp/iconcheck/main.swift && /tmp/iconcheck/run
//
// 注意 **必须叫 `main.swift`** —— 顶层代码只允许出现在这个文件名里；
// 也注意 helper 要标 `@MainActor`（Swift 6 下顶层代码是 MainActor 隔离的）。

var failures: [String] = []

@MainActor
func expect(_ name: String, isDirectory: Bool = false, _ symbol: String) {
    let got = FileTypeIcon.symbol(forName: name, isDirectory: isDirectory)
    if got != symbol {
        failures.append("\(name) → \(got)（期望 \(symbol)）")
    }
}

// ① 曾经分叉的那两个。两栏共用一个入口之后，只要它俩对了，分叉就不可能再回来。
expect("base.apk", "shippingbox")
expect("DroidBerth.app", "doc")

// ② 完整扩展名精确匹配 —— 不能截前缀（`m4a` 被 `m4` 吞掉、`tsx` 被 `ts` 吞掉）
expect("voice.m4a", "waveform")
expect("clip.mp4", "film")
expect("movie.ts", "film")            // MPEG 传输流，按视频归类
expect("App.tsx", "chevron.left.forwardslash.chevron.right")
expect("Main.swift", "chevron.left.forwardslash.chevron.right")

// ③ 刻意合并的（合并是默认答案，新增需要理由）
expect("IMG_1.heic", "photo")
expect("IMG_1.jpg", "photo")
expect("shot.dng", "photo")           // RAW 不单独给符号：能不能开是运行时的事
expect("a.flac", "waveform")
expect("b.mp3", "waveform")
expect("deck.pptx", "doc.text")
expect("book.pages", "doc.text")
expect("bad.aab", "shippingbox")      // 不用图标表达「这个不能推到 Android」
expect("bad.ipa", "shippingbox")
expect("x.iso", "opticaldisc")
expect("y.dmg", "opticaldisc")
expect("sheet.numbers", "tablecells")
expect("data.csv", "tablecells")

// ④ 兜底与目录
expect("README", FileTypeIcon.fallbackSymbol)        // 无扩展名
expect("weird.qqq", FileTypeIcon.fallbackSymbol)     // 未知类型
expect("folder.txt", isDirectory: true, FileTypeIcon.directorySymbol)

// ⑤ 表里不能出现空洞：每个值都必须是本次核过的符号
let known: Set<String> = [
    "photo", "film", "waveform", "doc.richtext", "tablecells", "doc.text",
    "doc.zipper", "opticaldisc", "shippingbox",
    "chevron.left.forwardslash.chevron.right",
]
for (ext, symbol) in FileTypeIcon.symbolByExtension where !known.contains(symbol) {
    failures.append("扩展名 \(ext) 指向未预期的符号 \(symbol)")
}

// ⑥ 键必须全是小写、无点（匹配是按完整扩展名做的，键不规范就会静默失配）
for ext in FileTypeIcon.symbolByExtension.keys where ext != ext.lowercased() || ext.contains(".") {
    failures.append("扩展名键不规范：\(ext)")
}

print("覆盖扩展名：\(FileTypeIcon.symbolByExtension.count) 个")
if failures.isEmpty {
    print("ALL OK")
} else {
    print("FAILURES (\(failures.count)):")
    for item in failures { print("  - \(item)") }
    exit(1)
}
