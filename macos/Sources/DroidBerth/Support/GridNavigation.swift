import Foundation

/// 网格视图的键盘导航判据（PRD §13.3）。
///
/// ## 为什么需要这个文件
///
/// `LazyVGrid` 与 `Table` / `NSBrowser` **不一样**：后两者自带方向键与 type-select
/// （敲字母跳转），`LazyVGrid` 一样都没有。补上它要算清三件事 ——
/// **显示顺序**、**一屏几列**、**目标落在哪一项** —— 而这三件事只要在视图里算一遍、
/// 在 `AppModel` 里再算一遍，就一定会分叉成两份事实（本项目反复修过的那个形状）。
///
/// 所以它们在这里各占一个纯函数，视图与模型共用同一份，并可以被
/// `scripts/check-grid-navigation.swift` 钉住。
///
/// ## 两处刻意的取舍
///
/// - **顺序定义在这里，而不是让视图自己排序**。方向键是按**屏幕上的次序**走的：
///   顺序若与视图的排序不一致，↓ 会跳到肉眼看不见的地方。
/// - **左右是线性的**（`index ∓ 1`），不是「按列跳」。Finder 的图标视图也是这个语义：
///   一行走到底接着走下一行，列首再按 ← 落回上一行的最后一项。
///   唯一的例外是**不做环绕** —— 首项再按 ← 停住，与 Finder 一致。
enum GridNavigation {
    enum Move: Sendable {
        case left
        case right
        case up
        case down
    }

    /// 网格的显示顺序：文件夹优先（可选）+ 本地化名称。
    ///
    /// 这一条就是 `EntryGrid` 视图里那份排序 —— 现在只有这一份。
    static func order(_ entries: [BrowserEntry], foldersFirst: Bool) -> [BrowserEntry] {
        entries.sorted { lhs, rhs in
            if foldersFirst, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 一屏铺几列。
    ///
    /// 必须与 `LazyVGrid` 的 `.adaptive(minimum: cellWidth, maximum: cellWidth * 1.4)`
    /// 实际铺出来的列数一致：列数 = ⌊(可用宽 + 间距) / (最小列宽 + 间距)⌋。
    /// 上限那一档不会另起作用 —— 列宽天然落在 `[cellWidth, cellWidth + spacing)`，
    /// 而本项目最窄的格子是 72 + 34 = 106pt、间距 12pt，永远够不到 1.4 倍。
    static func columnCount(width: Double, cellWidth: Double, spacing: Double) -> Int {
        guard width > 0, cellWidth > 0 else { return 1 }
        return max(Int((width + spacing) / (cellWidth + spacing)), 1)
    }

    /// 移动后的目标下标。
    ///
    /// - `left` / `right`：线性前后一项，两端夹住不环绕。
    /// - `up` / `down`：按列数跳一整行；越界时夹到首 / 末项 ——
    ///   最后一行的 ↓ 因此落在最后一项，而不是「没反应」。
    ///
    /// `index` 越界（例如锚点指向的条目已被删掉）时按边界处理，不返回 nil：
    /// 调用方已经确认列表非空，这里再给一个失败态只会多出一条没人处理的分支。
    static func targetIndex(from index: Int, move: Move, columns: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(index, 0), count - 1)
        let step = max(columns, 1)
        switch move {
        case .left: return max(clamped - 1, 0)
        case .right: return min(clamped + 1, count - 1)
        case .up: return max(clamped - step, 0)
        case .down: return min(clamped + step, count - 1)
        }
    }

    /// 敲字母跳转：返回命中的下标，没有命中返回 `nil`。
    ///
    /// - `from` 是**这一轮字母的起点**，不是「上一次落点」。`s` 跳到 sunset 之后再敲 `u`，
    ///   要在**同一批候选**里把 `su` 重新筛一遍；从落点往后找会正好跳过它。
    /// - 找满一圈为止（从 `from` 开始绕回开头），所以连着敲同一个字母会在所有
    ///   以它开头的条目之间轮转 —— Finder 的行为。
    /// - 大小写与 Unicode 组合形式按 `NameComparison.folded` 折叠：那是本项目
    ///   **唯一**的折叠加配方，type-select 不该有第二份。
    /// - **没有命中要返回 `nil` 而不是随便挑一个**：调用方据此把按键交还系统，
    ///   不会变成「按了没反应」的静默失败。
    static func typeSelectIndex(_ query: String, in entries: [BrowserEntry], from start: Int) -> Int? {
        let needle = NameComparison.folded(query)
        guard !needle.isEmpty, !entries.isEmpty else { return nil }
        let origin = ((start % entries.count) + entries.count) % entries.count
        for offset in 0..<entries.count {
            let index = (origin + offset) % entries.count
            if NameComparison.folded(entries[index].name).hasPrefix(needle) {
                return index
            }
        }
        return nil
    }
}
