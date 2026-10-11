import Foundation

/// 「保留两者」的冲突判定与改名。**纯函数**，不碰设备、不碰文件系统。
///
/// 从 `TransferPlanner.upload` 里抽出来有两个理由：
///
/// 1. **可测**。这是本项目唯一一条**会丢用户数据**的路径（漏判 = `adb push` 静默覆盖），
///    而它原先嵌在一个需要 `DeviceShell` 才能跑的方法里，没法在无设备时验证。
///    现在它只依赖 `NameComparison`，能用 `scripts/check-transfer-semantics.swift`
///    直接钉住。
/// 2. **规则集中**。「设备上已有的名字怎么折叠」「冲突后怎么改名」两件事在这里各占一个方法，
///    调用方 `TransferPlanner` 只剩编排。
///
/// 判据本身（为什么必须折叠、折叠到什么程度）在 `NameComparison` 里，连同实测证据。
enum NameConflict {
    /// 把设备上已存在的名字折叠成一个集合。
    ///
    /// **两边的名字都要折叠后才能比** —— 只折一边等于没折。
    static func foldedSet(_ existingNames: [String]) -> Set<String> {
        Set(existingNames.map(NameComparison.folded))
    }

    /// 在 `existing` 里找出与 `candidates` 冲突的那些**候选**。
    ///
    /// 返回的是候选的**原始写法**（不是折叠后的键），因为调用方要把名字报给用户看：
    /// 「『IMG_0001.JPG』已存在，换一个名称再试」。
    ///
    /// `excluding` 用于「重命名」这条路：把 `a.txt` 改成 `A.txt` 是**合法**的改大小写操作，
    /// 而按折叠判据它当然与自己冲突。所以要能把被改的那一项本身排除掉。
    ///
    /// 设备端重命名 / 移动 / 上传三处都用它 —— 这一族缺陷的形状是「同一个概念在两端
    /// 语义不同，代码只按一端写」，散落在调用点比较就必然再分叉一次。
    static func conflicting(
        _ candidates: [String],
        existing: [String],
        excluding excluded: String? = nil
    ) -> [String] {
        let taken = foldedSet(excluded.map { name in existing.filter { $0 != name } } ?? existing)
        return candidates.filter { taken.contains(NameComparison.folded($0)) }
    }

    /// 名字与设备上已有的冲突时，返回一个不冲突的 ` (1)` / ` (2)` … 名字；
    /// 并把新名字登记进 `taken`（这样同一批里多个冲突项不会撞在一起）。
    ///
    /// 不冲突时返回 `nil`，调用方保持原名 —— **不改名是默认行为**：
    /// 设备端只读（`.overwrite` 策略）或本来就没冲突时都一样。
    static func keepBothName(for name: String, taken: inout Set<String>) -> String? {
        guard taken.contains(NameComparison.folded(name)) else { return nil }

        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 1
        var candidate: String
        repeat {
            candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            index += 1
        } while taken.contains(NameComparison.folded(candidate))

        taken.insert(NameComparison.folded(candidate))
        return candidate
    }
}
