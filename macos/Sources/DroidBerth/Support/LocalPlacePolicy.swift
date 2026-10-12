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
        return isBrowsable(resolvedPath: resolvedPath, containerPath: containerPath)
    }

    /// 这个路径**能不能作为本地浏览位置**（列出来、走进去）。
    ///
    /// 沙盒里 `NSHomeDirectory()` 就是 App 自己的容器，里面有 `Library` / `SystemData` / `tmp` /
    /// `Documents` 这些**App 自己的管道**。它们既不是用户的文件，用户点进去也看不懂。
    ///
    /// ⚠️ 2026-10-12 实测：沙盒版**开局就站在那里**，列表把那些管道原样列了出来 ——
    /// 而当时**这一层没有任何保护**（`places()` 只挡住了弹窗那一处）。判据是同一条，
    /// 只是用在「列目录 / 导航」而不是「弹窗里列不列」。
    ///
    /// 注意**容器内的符号链接是例外**：`<容器>/Downloads` 解析后是 `/Users/<你>/Downloads`，
    /// 落在容器**之外** ⇒ 它是用户的真实文件夹，照样可浏览。`resolvingSymlinksInPath` 是调用方的
    /// 责任（本函数只做纯文本比较）。
    static func isBrowsable(resolvedPath: String, containerPath: String?) -> Bool {
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

// MARK: - 授权状态（E7）

/// 本地窗格的**授权状态**。
///
/// 与上面的「该不该显示某个位置」是**两件事**：`LocalPlacePolicy` 判一个位置能不能用，
/// 这里判**整个窗格处于哪种处境** —— 它决定界面是显示内容、显示引导、还是显示
/// 「重新选择」。搞混了就会出现「列表是空的」与「你没有权限」说成同一句话。
///
/// 侧载版永远取 `.notRequired`（没有沙盒就没有「容器外读不了」这件事），所以这一整套
/// 在侧载版上是死分支。反过来，沙盒版**必须**有它：没授权时列表本来就是空的，
/// 而「这个文件夹是空的」会是一句彻底的误导 —— 用户会以为自己的文件丢了。
enum LocalAccess: Equatable, Sendable {
    /// 非沙盒：不需要授权。侧载版的唯一取值。
    case notRequired
    /// 沙盒 + **从没授权过任何目录** ⇒ 首次运行，该给引导。
    case missing
    /// 沙盒 + 至少一个书签可用。
    case granted
    /// 沙盒 + 有记录但**全都解析不出来** ⇒ 目录被删 / 卷没插 / 权限被回收。
    case expired
}

/// 由两个**计数**定授权状态。
///
/// 做成纯函数（而不是内联在 `AppModel` 里）是因为这几条分支在真机上很难全部走到：
/// 要造出「有记录但全坏」的现场，得先授权一个目录、再把它删掉或拔掉它所在的卷。
/// 而这几条分支的差别正是**界面说哪句话** —— 说错了用户就不知道下一步该做什么。
enum FolderAccess {
    /// - Parameters:
    ///   - isSandboxed: 是否在沙盒里（`AppPaths.containerDirectory != nil`）
    ///   - storedCount: 磁盘上原本记了几项
    ///   - resolvedCount: 其中**解析成功、且目录确实还在**的项数
    static func state(isSandboxed: Bool, storedCount: Int, resolvedCount: Int) -> LocalAccess {
        guard isSandboxed else { return .notRequired }
        if resolvedCount > 0 { return .granted }
        // 从没记过 ⇒ 首次运行，该给引导；
        // 记过但全坏了 ⇒ 「上次那个打不开了」，该让用户**重新选择**。
        // 两者的下一步动作相同，但说法不同 —— 而说法正是用户此刻最需要的东西。
        return storedCount == 0 ? .missing : .expired
    }
}
