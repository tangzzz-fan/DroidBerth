import Foundation

// 传输语义的回归核对。它要证伪的是**同一族**缺陷：
//
//   「同一个概念在两端（或两侧）语义不同，而代码只按一端写。」
//
// 这一族已经出过两次（见 `check-icon-mapping.swift` 的文件图标分叉），
// 而这一轮的两次比那次更危险 —— 它们是**静默的数据丢失**与**静默的功能缺失**：
//
//   ① `TransferPlanner` 判「同名」用的是精确字符串比较。但设备端 `/sdcard`
//      **不区分大小写**（内容级证明：push 完 `Report.txt` 再 push `report.txt`，
//      只剩一个文件、内容是后者），所以上传 `photo.jpg` 时设备上已有的 `Photo.JPG`
//      被判为「不冲突」，`adb push` 把它**替换掉** —— 而默认策略正是「保留两者」。
//   ② `ThumbnailStore` 让远端视频也去拉 64 KB 文件头。实测这条通道对视频**必然失败**
//      （faststart 要 1 MB、`moov` 在尾要整文件），于是同一批视频「有的有缩略图有的没有」，
//      而用户既看不见也猜不到原因。
//
// 现在两件事都有单一入口：`NameComparison` 与 `ThumbnailPolicy`。
// 这份清单就是那两个入口的契约。
//
// 为什么是独立脚本而不是测试 target：本项目没有测试 target（见 `0926_03` §5.3）。
//
// 跑法（不需要 Rust / adb，约 5 秒）：
//
//     mkdir -p /tmp/transfercheck && cp scripts/check-transfer-semantics.swift /tmp/transfercheck/main.swift
//     swiftc -O -o /tmp/transfercheck/run \
//       -target arm64-apple-macos14.0 \
//       -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
//       -swift-version 6 -strict-concurrency=complete \
//       -Xfrontend -disable-sandbox \
//       macos/Sources/DroidBerth/Support/NameComparison.swift \
//       macos/Sources/DroidBerth/Support/ThumbnailPolicy.swift \
//       macos/Sources/DroidBerth/Support/ByteFormat.swift \
//       /tmp/transfercheck/main.swift && /tmp/transfercheck/run
//
// 注意 **必须叫 `main.swift`**（顶层代码只允许在这个文件名里），
// 且 helper 要标 `@MainActor`（Swift 6 下顶层代码是 MainActor 隔离的）。

var failures: [String] = []

@MainActor
func check(_ label: String, _ got: String, _ want: String) {
    if got != want { failures.append("\(label)：得到 \(got.debugDescription)，期望 \(want.debugDescription)") }
}

@MainActor
func check(_ label: String, _ got: Bool, _ want: Bool) {
    if got != want { failures.append("\(label)：得到 \(got)，期望 \(want)") }
}

@MainActor
func checkEqual<T: Equatable>(_ label: String, _ a: T, _ b: T) {
    if a != b { failures.append("\(label)：\(a) ≠ \(b)") }
}

@MainActor
func checkNotEqual<T: Equatable>(_ label: String, _ a: T, _ b: T) {
    if a == b { failures.append("\(label)：两者相同（\(a)）—— 这个用例本身失效了") }
}

// ─────────────────────────────────────────────────────────────
// ① NameComparison：折叠**必须**与两侧实测一致
//
// 下面这张表是**实测**的结果，不是设计意图。两侧（macOS 默认 APFS 卷 / Android
// `/sdcard` 的 FUSE 层）折叠的是**同一张表**，所以一张表就够：
//   · 大小写、NFC/NFD、ß/ss、ﬁ/fi、KELVIN/k、σ/ς  → **折叠**
//   · 全角Ａ/A、ⓞ/o、é/e、尾随空格、尾随点          → **不折叠**
// 证据：`docs/device-acceptance/2026-10-11/06-name-fold.txt`（设备端）、
//       `.../08-two-sided-fold.txt`（两侧对照）、`.../07-fold-recipe.txt`（Swift 配方）。
// ─────────────────────────────────────────────────────────────

let nfcCafe = "caf\u{00E9}.txt"          // é 单码点
let nfdCafe = "cafe\u{0301}.txt"         // e + 组合重音

// 实测表： (a, b, 两侧是否视为同一个文件)
let foldTable: [(String, String, Bool, String)] = [
    ("IMG.JPG", "img.jpg", true, "大小写"),
    (nfcCafe, nfdCafe, true, "NFC ↔ NFD"),
    ("\u{00DF}.txt", "ss.txt", true, "ß ↔ ss"),
    ("\u{FB01}le.txt", "file.txt", true, "连字 ﬁ ↔ fi"),
    ("\u{212A}.txt", "k.txt", true, "KELVIN U+212A ↔ k"),
    ("\u{212B}.txt", "\u{00C5}.txt", true, "ANGSTROM U+212B ↔ Å"),
    ("\u{03C3}.txt", "\u{03C2}.txt", true, "σ ↔ ς（希腊词尾 sigma）"),
    ("\u{0130}.txt", "i\u{0307}.txt", true, "İ U+0130 ↔ i+组合点"),
    ("A.txt", "\u{FF21}.txt", false, "全角Ａ ↔ A（两侧都不折叠）"),
    ("o.txt", "\u{24DE}.txt", false, "带圈 ⓞ ↔ o（两侧都不折叠）"),
    (nfcCafe, "cafe.txt", false, "é ↔ e（两侧都不折叠：不做变音折叠）"),
    ("a.txt", "a.txt ", false, "尾随空格是另一个名字（两侧都保留）"),
    ("a.txt", "a.txt.", false, "尾随点是另一个名字（两侧都保留）"),
    ("a b.txt", "a  b.txt", false, "单空格 ≠ 双空格"),
]

for (a, b, shouldFold, note) in foldTable {
    let got = NameComparison.folded(a) == NameComparison.folded(b)
    check("折叠表 · \(note)：\(a.debugDescription) vs \(b.debugDescription)",
          got, shouldFold)
    // 折叠方向决定了它在现实里是安全的还是危险的：折叠时**多折**只会多一个 ` (1)`，
    // 少折一次就是静默覆盖。所以每条都正反说一遍。
    check("折叠表（反向一致）· \(note)",
          NameComparison.folded(b) == NameComparison.folded(a), got)
}

// 用例前提：这张表里的「不折叠」条目必须真的是**不同的名字**，
// 否则断言在测一个恒真的东西。（NFC/NFD 那一行要按**字节**比 —— 见下。）
for (a, b, shouldFold, note) in foldTable where !shouldFold {
    checkNotEqual("用例前提：\(note) 的两个名字本身必须不同", Array(a.utf8), Array(b.utf8))
}
// NFC/NFD 那一行的字节必须不同（字符串 `==` 会按规范等价判等，掩盖这一维）
checkNotEqual("用例前提：NFC 与 NFD 的**字节**必须不同", Array(nfcCafe.utf8), Array(nfdCafe.utf8))

// Swift 的 String 语义（文档化一条事实，它决定 NFC 这一维要不要写代码）：
//   `==` 与 `Set.contains` 按**规范等价**比较 ⇒ NFC/NFD **原本就不是**缺陷来源；
//   真正漏掉的是**大小写**与**完整折叠**（ß/ﬁ/ς 与规范化是两回事，它们是大小写折叠映射）。
check("Swift 的 == 已按规范等价（NFC/NFD 视为相同）", nfcCafe == nfdCafe, true)
check("Swift 的 == 不忽略大小写", "A.txt" == "a.txt", false)
check("ß 与 ss 不是规范等价（所以是完整折叠那一维的事）", "\u{00DF}.txt" == "ss.txt", false)

// 折叠后的键应当**逐字节**相同 —— 这样即使将来有人把比较换成 utf8/hash 也仍然一致
check("NFD 与 NFC 折叠后字节相同",
      NameComparison.folded(nfdCafe).utf8.elementsEqual(NameComparison.folded(nfcCafe).utf8), true)

// 幂等：折叠过的键再折一次不能变（否则两轮比较会不一致）
for probe in ["IMG.JPG", "\u{00DF}.txt", "\u{FB01}le.txt", nfdCafe, "中文名.txt", "😀emoji.txt", "a.txt "] {
    checkEqual("folded 幂等：\(probe)", NameComparison.folded(NameComparison.folded(probe)), NameComparison.folded(probe))
}

// 中文与 emoji 不能被破坏
check("中文名.txt 折叠后不变", NameComparison.folded("中文名.txt"), "中文名.txt")
check("😀emoji.txt 折叠后不变", NameComparison.folded("😀emoji.txt"), "😀emoji.txt")

// key(_:caseSensitiveTargetVolume:)：只有下载方向会传 true（外接区分大小写的 APFS 是合法配置）
check("区分大小写的卷上不折叠", NameComparison.key("IMG.JPG", caseSensitiveTargetVolume: true), "IMG.JPG")
check("不区分大小写的卷上折叠", NameComparison.key("IMG.JPG", caseSensitiveTargetVolume: false),
      NameComparison.folded("IMG.JPG"))
check("区分大小写的卷上 NFD 保持原样", NameComparison.key(nfdCafe, caseSensitiveTargetVolume: true), nfdCafe)

// ─────────────────────────────────────────────────────────────
// ② NameConflict：规划器**真正调用**的那两个纯函数
//
// 上一条验证的是「折叠规则」；这一条验证「规划器真的用了它」。
// 两者的区别很重要：规则对、但调用点忘了折叠（或者只折一边），缺陷照样在。
// ─────────────────────────────────────────────────────────────

@MainActor
func renamed(_ name: String, existing: [String]) -> String? {
    var taken = NameConflict.foldedSet(existing)
    return NameConflict.keepBothName(for: name, taken: &taken)
}

@MainActor
func twoInARow(_ first: String, _ second: String, existing: [String]) -> [String] {
    var taken = NameConflict.foldedSet(existing)
    return [first, second].map { NameConflict.keepBothName(for: $0, taken: &taken) ?? $0 }
}

let deviceNames = ["Photo.JPG", "DCIM", "Readme.TXT"]
let folded = NameConflict.foldedSet(deviceNames)

// 【F2 的回归断言】设备上已有 `Photo.JPG`，上传 `photo.jpg` 必须被判为冲突。
// 改造前这一条是 false（精确字符串比较）⇒ `adb push` 静默覆盖。
check("设备上有 Photo.JPG 时，photo.jpg 必须判为冲突", renamed("photo.jpg", existing: deviceNames) != nil, true)
check("设备上有 Photo.JPG 时，PHOTO.JPG 也必须判为冲突", folded.contains(NameComparison.folded("PHOTO.JPG")), true)
check("设备上有 Readme.TXT 时，README.txt 必须判为冲突", folded.contains(NameComparison.folded("README.txt")), true)
// 完整折叠那一维同样要生效（ß/ss 与大小写无关）
check("设备上有 ss.txt 时，ß.txt 必须判为冲突",
      NameConflict.foldedSet(["ss.txt"]).contains(NameComparison.folded("\u{00DF}.txt")), true)
// 阴性：不该冲突的不能误报
check("设备上有 Photo.JPG 时，cover.jpg 不冲突", renamed("cover.jpg", existing: deviceNames) == nil, true)
check("设备上有 Ａ.txt 时，A.txt 不冲突（全角不是等价）",
      renamed("A.txt", existing: ["\u{FF21}.txt"]) == nil, true)
check("空目录不产生冲突", renamed("a.jpg", existing: []) == nil, true)

// 改名本身：` (1)` / ` (2)` 的生成与登记
checkEqual("photo.jpg 撞 Photo.JPG → photo (1).jpg",
           renamed("photo.jpg", existing: ["Photo.JPG"]) ?? "nil", "photo (1).jpg")
checkEqual("再撞 photo (1).jpg → photo (2).jpg",
           renamed("photo.jpg", existing: ["Photo.JPG", "photo (1).jpg"]) ?? "nil", "photo (2).jpg")
checkEqual("无扩展名：README 撞 readme → README (1)",
           renamed("README", existing: ["readme"]) ?? "nil", "README (1)")
checkEqual("多重点：a.tar.gz 撞 A.TAR.GZ → a.tar (1).gz",
           renamed("a.tar.gz", existing: ["A.TAR.GZ"]) ?? "nil", "a.tar (1).gz")
checkEqual("不冲突时报 nil（调用方保持原名）", renamed("new.jpg", existing: ["Photo.JPG"]) ?? "nil", "nil")

// 同一批里的多个冲突项不能互相撞：登记后再算第二个
checkEqual("同一批里两个仅大小写不同的冲突项要拿到不同的名字",
           twoInARow("photo.jpg", "PHOTO.jpg", existing: ["Photo.JPG"]),
           ["photo (1).jpg", "PHOTO (2).jpg"])

// ── conflicting(_:existing:excluding:)：重命名 / 移动 / 新建文件夹共用的那一个 ──

// 重命名 `b.txt` → `A.TXT` 时设备上已有 `a.txt`：必须判为冲突（否则 mv 覆盖 a.txt 的内容）
checkEqual("重命名到已有名字（仅大小写不同）→ 报冲突",
           NameConflict.conflicting(["…/A.TXT"], existing: ["…/a.txt", "…/c.txt"]),
           ["…/A.TXT"])
// 但「只改自己的大小写」要放行 —— excluding 排除被改的那一项
checkEqual("把 a.txt 改成 A.txt（自己）→ 不报冲突",
           NameConflict.conflicting(["…/A.txt"], existing: ["…/a.txt", "…/c.txt"], excluding: "…/a.txt"),
           [])
checkEqual("把 a.txt 改成 b.txt（别人占着）→ 报冲突",
           NameConflict.conflicting(["…/b.txt"], existing: ["…/a.txt", "…/b.txt"], excluding: "…/a.txt"),
           ["…/b.txt"])
// 移动：整批上报冲突的名字，且返回的是**候选的原始写法**（要报给用户看）
checkEqual("移动整批：只报真正冲突的那些",
           NameConflict.conflicting(["a.jpg", "b.jpg", "c.jpg"],
                                    existing: ["A.JPG", "c.jpg"]),
           ["a.jpg", "c.jpg"])
checkEqual("新建文件夹：photos 撞 Photos → 报冲突",
           NameConflict.conflicting(["photos"], existing: ["Photos", "Movies"]),
           ["photos"])
checkEqual("无冲突时返回空", NameConflict.conflicting(["x"], existing: ["y"]), [String]())

// ─────────────────────────────────────────────────────────────
// ③ DeviceNameRules：校验必须与设备端**实测**的接受范围一致
//
// 这一条也是同一个形状的缺陷：校验按「FAT32 规范」写，而设备端按「Android 存储层
// 实际接受什么」运行。两个方向都会出错 —— 挡太多（用户困惑）与挡太少（提交后报 errno）。
// ─────────────────────────────────────────────────────────────

@MainActor
func valid(_ name: String) -> Bool {
    DeviceNameRules.validationMessage(for: name) == nil
}

// 长度：**255 字节**（边界是实测的）
check("251 ASCII + .txt = 255 字节 → 合法", valid(String(repeating: "x", count: 251) + ".txt"), true)
check("255 ASCII + .txt = 259 字节 → 过长", valid(String(repeating: "x", count: 255) + ".txt"), false)
check("254 ASCII + .txt = 258 字节 → 过长", valid(String(repeating: "x", count: 254) + ".txt"), false)
// 【F3 的回归断言】按字节判，不能按字符判：100 个汉字 = 104 字符但 304 字节
check("100 个汉字（304 字节 / 104 字符）→ 过长",
      valid(String(repeating: "中", count: 100) + ".txt"), false)
check("80 个汉字（244 字节 / 84 字符）→ 合法",
      valid(String(repeating: "中", count: 80) + ".txt"), true)
check("200 个 emoji（804 字节 / 204 字符）→ 过长",
      valid(String(repeating: "😀", count: 200) + ".txt"), false)
check("旧判据（100 个汉字 > 255 字符）本会放行 —— 所以这一条真的钉住了改动",
      (String(repeating: "中", count: 100) + ".txt").count > 255, false)

// 字符集：设备端自己就拒的那一组，校验要前移
for bad in [":", "*", "?", "\"", "<", ">", "|", "\\"] {
    check("名称含「\(bad)」→ 拒绝", valid("a\(bad)b.txt"), false)
}
check("名称含制表符 → 拒绝", valid("a\tb.txt"), false)
// 实测设备端**接受**的，校验不能挡（挡多了同样是一种错）
for good in ["a'b.txt", "a`b.txt", "a$b.txt", "a;b.txt", "a&b.txt", "a b.txt",
             "中文名.txt", "😀emoji.txt", ".hidden.txt", "-dash.txt", "~tilde.txt",
             "#hash.txt", "%pct.txt", "(paren).txt", "[brack].txt", "{brace}.txt",
             "enddot..txt", "trailingspace .txt"] {
    check("名称「\(good)」→ 放行（实测设备端接受）", valid(good), true)
}
// 全角与带圈也不是非法字符
check("全角Ａ → 放行", valid("\u{FF21}.txt"), true)
check("带圈 ⓞ → 放行", valid("\u{24DE}.txt"), true)

// 必然非法的
check("空 → 拒绝", valid(""), false)
check("全空白 → 拒绝（先裁空白）", valid("   "), false)
check("`.` → 拒绝", valid("."), false)
check("`..` → 拒绝", valid(".."), false)
check("含 `/` → 拒绝", valid("a/b.txt"), false)

// 首尾空白会被裁掉：校验放行，但调用方必须用裁过的名字（AppModel 就是这么做的）
check("首尾空白的名字放行（由调用方裁）", valid("  a.txt  "), true)
checkEqual("校验对裁过的名字给出同样的结论",
           DeviceNameRules.validationMessage(for: "  a.txt  ") ?? "nil",
           DeviceNameRules.validationMessage(for: "a.txt") ?? "nil")

// 报错文案要指名道姓，而不是把原始字符直接甩出去
check("制表符的报错文案用「制表符」而不是裸字符",
      DeviceNameRules.validationMessage(for: "a\tb.txt")?.contains("制表符") ?? false, true)
check("非法字符的报错文案里带上那个字符",
      DeviceNameRules.validationMessage(for: "a:b.txt")?.contains(":") ?? false, true)

// ─────────────────────────────────────────────────────────────
// ④ ThumbnailPolicy：远端只做图片（F1 的修复）
// ─────────────────────────────────────────────────────────────

// 远端：实测在 64 KB 通道上**能出图**的
for ext in ["jpg", "jpeg", "png", "heic", "heif"] {
    check("远端 \(ext) 应当生成缩略图", ThumbnailPolicy.allowsRemoteFile(named: "a.\(ext)"), true)
}

// 远端：视频 —— **本次修复的核心**。改造前这五项全为 true。
for name in ["clip.mp4", "clip.mov", "clip.m4v", "clip.mkv", "clip.avi", "clip.webm", "clip.3gp"] {
    check("远端 \(name) 不生成缩略图（64 KB 通道对视频必失败）",
          ThumbnailPolicy.allowsRemoteFile(named: name), false)
}

// 远端：实测必失败的图片类型（GIF 要 trailer、TIFF 的 strip 在尾部）
for name in ["anim.gif", "scan.tif", "scan.tiff"] {
    check("远端 \(name) 不生成缩略图（结构性失败）",
          ThumbnailPolicy.allowsRemoteFile(named: name), false)
    check("\(name) 被标为已知必失败", ThumbnailPolicy.isKnownRemoteFailure(named: name), true)
}

// 远端：未实测的图片类型仍让它们走一次（成本 64 KB，换一个可能存在的缩略图划算）
for ext in ["webp", "bmp", "dng", "raw", "cr2", "nef", "arw"] {
    check("远端 \(ext) 仍尝试（未实测，成本仅 64 KB）", ThumbnailPolicy.allowsRemoteFile(named: "a.\(ext)"), true)
}

// 远端：非素材类型一律不做
for name in ["note.txt", "doc.pdf", "archive.zip", "song.mp3", "README"] {
    check("远端 \(name) 不生成缩略图", ThumbnailPolicy.allowsRemoteFile(named: name), false)
}

// 本地：图片**与视频**都做（文件就在本机，QL 对完整文件两条都能出图，实测 8/8）
for name in ["a.jpg", "a.png", "a.heic", "a.gif", "a.tiff", "clip.mp4", "clip.mov"] {
    check("本地 \(name) 生成缩略图", ThumbnailPolicy.allowsLocalFile(named: name), true)
}
for name in ["note.txt", "doc.pdf", "archive.zip", "README"] {
    check("本地 \(name) 不生成缩略图", ThumbnailPolicy.allowsLocalFile(named: name), false)
}

// 扩展名大小写不能改变结论（`IMG.GIF` 也是 gif）
check("远端 .GIF 同样排除", ThumbnailPolicy.allowsRemoteFile(named: "IMG.GIF"), false)
check("远端 .MOV 同样排除", ThumbnailPolicy.allowsRemoteFile(named: "MOV_0001.MOV"), false)
check("远端 .JPG 同样尝试", ThumbnailPolicy.allowsRemoteFile(named: "IMG_0001.JPG"), true)
check("本地 .MOV 同样尝试", ThumbnailPolicy.allowsLocalFile(named: "MOV_0001.MOV"), true)

// 不变式：远端的许可集合必须是本地的**真子集**（远端能力更弱，不可能反过来）
let allExtensions = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tif", "tiff",
                     "dng", "raw", "arw", "cr2", "nef",
                     "mp4", "mov", "mkv", "avi", "webm", "m4v", "3gp", "ts", "flv", "wmv",
                     "mp3", "m4a", "wav", "txt", "pdf", "zip", "iso", "apk"]
for ext in allExtensions {
    let name = "sample.\(ext)"
    if ThumbnailPolicy.allowsRemoteFile(named: name) && !ThumbnailPolicy.allowsLocalFile(named: name) {
        failures.append("不变式破坏：\(name) 远端允许但本地不允许（远端能力不可能更强）")
    }
}
// 而且是**真**子集：视频这一类只可能在本地被允许
check("真子集：远端不许的视频在本地必须许",
      ThumbnailPolicy.allowsRemoteFile(named: "clip.mp4") == false
        && ThumbnailPolicy.allowsLocalFile(named: "clip.mp4") == true, true)

// ─────────────────────────────────────────────────────────────

print("覆盖：折叠实测表 \(foldTable.count) 行 · NameConflict 改名/冲突 · "
      + "DeviceNameRules 校验 · ThumbnailPolicy \(allExtensions.count) 个扩展名")
if failures.isEmpty {
    print("ALL OK")
} else {
    print("FAILURES (\(failures.count)):")
    for item in failures { print("  - \(item)") }
    exit(1)
}
