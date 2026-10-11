import Foundation

/// 沙盒下「固定位置」该不该出现在侧边栏里（`docs/1011_04_appstore-plan.md` §4.1）。
///
/// 背景：沙盒里的 `NSHomeDirectory()` 指向容器，而容器里那六个名字**看起来都在**。
/// 2026-10-12 拿 MAS 那套 entitlements 打沙盒探针量过，它们其实分成三类：
///
/// | 条目 | 在容器里是什么 | 能不能用 |
/// | --- | --- | --- |
/// | `Downloads` | 符号链接 → 真实目录，**有对应 entitlement** | ✅ 能列 |
/// | `Desktop` / `Movies` / `Pictures` / `Music` | 符号链接 → 真实目录，**没有 entitlement** | ❌ `errno 257` |
/// | `Documents` | **容器里的空真目录** —— 没有对应 entitlement 时 containermanagerd 干脆不给符号链接 | ⚠️ 能列，但是空的 |
///
/// 而 `FileManager.fileExists` **会跟随符号链接** ⇒ 只看它，六项全都「存在」。
/// 于是侧边栏把六项都画出来：四项点开报错、一项点开是**空文件夹且不报任何错**。
/// 最后那条是「用户以为文件丢了」级别的缺陷，偏偏它最安静。
///
/// ⇒ 判据两条，**缺一不可**：
///
/// 1. 解析符号链接后必须落在**容器之外** —— 否则它只是容器里的一个目录，不是用户的
/// 2. 必须**真的能列出内容** —— 名字在、权限不在，照样是假的
///
/// 侧载版（不在沙盒里）`containerPath` 传 `nil`、`canList` 恒真 ⇒ 两条都放行，
/// **行为与从前完全一致**。也就是说这条分支只在沙盒下生效 —— 这正是它必须做成**纯函数**
/// 的原因：靠手跑跑不出这条分支，只能靠判据钉住（`scripts/check-local-place-policy.swift`）。
enum LocalPlacePolicy {
    /// - Parameters:
    ///   - resolvedPath: **解析符号链接之后**的绝对路径（`URL.resolvingSymlinksInPath()`）
    ///   - containerPath: **解析符号链接之后**的容器根；不在沙盒里时传 `nil`
    ///   - canList: 实际能不能列出这个目录的内容。**不能用 `fileExists` / `isReadableFile` 代替** ——
    ///     实测沙盒下这两个对那四项都返回「可以」，只有真去列才报 `errno 257`
    static func isUsable(resolvedPath: String, containerPath: String?, canList: Bool) -> Bool {
        guard canList else { return false }
        guard let containerPath, !containerPath.isEmpty else { return true }
        return !isInside(resolvedPath, containerPath)
    }

    /// `path` 是否在 `container` 之内。
    ///
    /// **按路径分量比，不按字符串前缀。** 前缀比较会把
    /// `…/Containers/x/Database` 判成在 `…/Containers/x/Data` 之内 —— 那是两个不同的目录。
    /// 同一类错误本项目在 ZIP 打包那里已经踩过一次（`/tmp` 与 `/private/tmp` 之下
    /// 字符串 `hasPrefix` 全判成假）。所以这里两个参数都**假定已解析过符号链接**。
    static func isInside(_ path: String, _ container: String) -> Bool {
        let target = components(path)
        let base = components(container)
        guard !base.isEmpty, target.count >= base.count else { return false }
        return Array(target.prefix(base.count)) == base
    }

    private static func components(_ path: String) -> [String] {
        (path as NSString).standardizingPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
