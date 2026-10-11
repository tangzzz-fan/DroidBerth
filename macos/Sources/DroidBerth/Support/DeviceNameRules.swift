import Foundation

/// 设备端文件名的合法性规则。**全部是实测出来的**，不是照抄 FAT32 的规范。
///
/// 判据与证据：`docs/1011_01_device-acceptance-report.md` §3。
///
/// ## 长度：255 **字节**，不是 255 个字符
///
/// 设备端的 `NAME_MAX` 是 255 **UTF-8 字节**，而这里原先数的是 `name.count`
/// （Swift 的字素簇）。汉字 3 字节、emoji 4 字节 ⇒ **64 个汉字之后的校验就不可信了**：
/// 实测 100 个汉字（304 字节）与 200 个 emoji（804 字节）都能通过旧校验，
/// 然后在设备上以 `File name too long` 失败。
/// 边界：251 个 ASCII + `.txt` = **255 字节成功**、255 个 ASCII + `.txt` = 259 字节失败。
///
/// 字符数 ≤ 字节数，所以按字节判**严格更强**，且正是设备端的判据。
///
/// ## 字符集：这一组是设备端**自己**就拒的
///
/// 拒绝者是 Android 的存储层（为保持卷与 MTP 的 FAT 兼容语义），错误 `EPERM`，
/// 且 `touch`/`mv` 与 `adb push` 两条通道的被拒集合**完全一致**。
/// 所以这不是「提前挡下一个本来能成功的操作」，而是**把 errno 换成人话**：
/// 从 `mv: '...': Operation not permitted` 变成「名称不能包含「:」」，
/// 并且在用户提交**之前**就让「确定」不可用。
///
/// 反过来也重要：**不要**把这份名单扩到实测之外。实测 `'` `` ` `` `$` `;` `&` 空格、
/// 中文、emoji、点前缀、前导 `-`、`~` `#` `%` `( ) [ ] { }` 全都能建得出来。
enum DeviceNameRules {
    /// 设备端存储层拒绝的字符（实测，`EPERM`）。
    static let forbiddenCharacters: Set<Character> = [":", "*", "?", "\"", "<", ">", "|", "\\", "\t"]

    /// 名字的字节上限（设备端 `NAME_MAX`）。
    static let maximumByteCount = 255

    /// 第一个非法字符；没有则 `nil`。
    static func firstForbiddenCharacter(in name: String) -> Character? {
        name.first { forbiddenCharacters.contains($0) }
    }

    /// 校验结果，`nil` 表示可以提交。
    ///
    /// 名字会先按**首尾空白**裁一次。这一条是产品决定而不是设备约束
    /// （设备端其实**保留**尾随空格，实测）。理由是粘贴时多带一个换行是最常见的误操作，
    /// 裁掉它符合用户意图；但调用方**必须用裁过的名字去操作**，否则校验与实际动作
    /// 会不一致（`AppModel.renameRemoteEntry` 就是这么做的）。
    static func validationMessage(for raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "名称不能为空" }
        if name == "." || name == ".." { return "「\(name)」不是合法的名称" }
        if name.contains("/") { return "名称不能包含「/」" }
        if let bad = firstForbiddenCharacter(in: name) {
            return "名称不能包含「\(display(bad))」"
        }
        if name.utf8.count > maximumByteCount {
            return "名称过长（最多 \(maximumByteCount) 字节，一个汉字占 3 字节）"
        }
        return nil
    }

    /// 制表符之类的字符直接打出来会让人看不懂，换成名字。
    private static func display(_ character: Character) -> String {
        character == "\t" ? "制表符" : String(character)
    }
}
