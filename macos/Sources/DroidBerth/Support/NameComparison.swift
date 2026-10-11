import Foundation

/// 「这两个名字是不是同一个文件」的**唯一**判据。
///
/// 抽成独立类型有两个理由：冲突检测要在上传与下载两侧共用同一套规则，
/// 而规则本身要能被钉住 —— 本项目没有测试 target，用的是 `scripts/check-*.swift`
/// 那套独立编译的断言（见 `scripts/check-transfer-semantics.swift`）。
///
/// ## 为什么两侧的判据不同
///
/// 「名字相同」在两端**不是同一件事**，而默认的误判方向是**静默覆盖**：
///
/// | 侧 | 卷语义 | 后果 |
/// | --- | --- | --- |
/// | macOS 默认卷（APFS / HFS+） | 不区分大小写、不区分 Unicode 组合形式 | `IMG.JPG` 与 `img.jpg` 是同一个文件 |
/// | Android `/sdcard`（MediaProvider 的 FUSE 层） | **同样不区分，且归一化到 NFC** | 同上 |
///
/// 第二行是 **2026-10-11 实测**的结论，它推翻了一份旧注释里的前提
/// （「设备端主存储是 ext4 / f2fs 派生，确实区分大小写」）—— 底下的 ext4 确实区分，
/// 但用户面对的是 FUSE 这一层。**内容级**证据：
///
///     adb push Report.txt（内容 AAAA） → adb push report.txt（内容 BBBB）
///     ⇒ 目录里只剩一个文件，内容是 BBBB
///
/// 另有：`touch Case.txt` 后 `test -f case.txt` 为真；分别建 `Case.txt` 与 `case.txt`
/// 只有一个存活；NFC 与 NFD 的两个 `café.txt` 只剩一个、且是 NFC 形式。
/// 完整证据见 `docs/1011_01_device-acceptance-report.md` §2 与
/// `docs/device-acceptance/2026-10-11/04-final.txt`。
///
/// ## 折叠不止「大小写」这一步
///
/// 设备端做的是 Unicode **完整**大小写折叠 + NFC 归一化，而**不做**变音折叠
/// （`é` ≠ `e`）与全角折叠（`Ａ` ≠ `A`）—— 三组都是实测的，判据与四个候选配方的
/// 对比见 `folded(_:)`。下面这些**都是**会被折叠掉的真实文件名：
/// `ß.txt`↔`ss.txt`、`ﬁle.txt`↔`file.txt`、`σ`↔`ς`。
///
/// ## 于是
///
/// - **上传方向：无条件折叠。** 上传时没有「查询设备卷大小写语义」的接口
///   （`volumeSupportsCaseSensitiveNames` 是 macOS 侧的 API）。与其加一次探测往返
///   （探测自己也会失败，还得给失败兜底，多一个状态），不如直接折叠 —— 这一侧的
///   误判代价不对称：**多出一个 ` (1)` 只是碍眼，静默覆盖是丢用户手机上的数据。**
/// - **下载方向：按目标卷判定。** 这一侧有 API，且「外接区分大小写的 APFS 卷」是
///   合法配置，在那里折叠会造成无缘无故的 ` (1)`。取不到卷信息时仍然按折叠处理。
///
/// 这同时解释了为什么两个方向看起来不对称：不是疏忽，是两侧**可用的判据不同**。
enum NameComparison {
    /// 折叠成一个可比较的键：**Unicode 完整大小写折叠 + NFC 归一化**。
    ///
    /// 这里刻意**不用** `lowercased()` —— 它太窄。`.caseInsensitive` 走的是
    /// **Unicode 完整大小写折叠**（CaseFolding.txt 的 C+F 映射），下列三个差异
    /// 都是真实存在的文件名，而设备端会把它们折叠掉：
    ///
    /// | 名字 | `lowercased()` | `folding(.caseInsensitive)` | 设备端实测 |
    /// | --- | --- | --- | --- |
    /// | `ß.txt` | `ß.txt` | `ss.txt` | **折叠** |
    /// | `ﬁle.txt` | `ﬁle.txt` | `file.txt` | **折叠** |
    /// | `σ` / `ς`（希腊词尾 sigma） | 只折叠前者 | 两者都折叠 | **折叠** |
    ///
    /// 判据是拿四个「**只有完整折叠才会折叠**」的字符去设备上试出来的
    /// （`docs/device-acceptance/2026-10-11/07-fold-recipe.txt`）：
    /// KELVIN SIGN `U+212A` ↔ `k`、ANGSTROM SIGN `U+212B` ↔ `Å`、`σ` ↔ `ς`、
    /// `İ` ↔ `i`+组合点 —— 四个全部折叠；而阴性对照 `é` ↔ `e`、连字 `ﬁ` ↔ `f`
    /// 不折叠。四个候选配方里只有这一个 0 错（`lowercased()` 错 3 项）。
    ///
    /// 刻意**不加**的：
    /// - `.diacriticInsensitive`：会把 `é` 折成 `e`，设备端不这么做（实测），加了会多出
    ///   无缘无故的 ` (1)`。
    /// - `.widthInsensitive`：会把全角 `Ａ` 折成 `A`，设备端同样不这么做（实测）。
    ///
    /// 最后统一到 NFC：设备端把 NFD 归一化到 NFC（macOS 落盘常用 NFD），
    /// 而 `folding` 不保证输出是合成形式。顺序固定下来，同一个名字在任何调用点
    /// 都得到同一个键。
    static func folded(_ name: String) -> String {
        name
            .folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    /// 冲突判据。`caseSensitiveTargetVolume` 为真时**不**折叠。
    static func key(_ name: String, caseSensitiveTargetVolume: Bool) -> String {
        caseSensitiveTargetVolume ? name : folded(name)
    }
}
