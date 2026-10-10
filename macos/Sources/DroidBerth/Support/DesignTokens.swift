import AppKit
import SwiftUI

/// 设计令牌的 **Swift 侧落点**。
///
/// 唯一来源是 `docs/design/DESIGN.md`；这个文件只是它的可编译形式。
/// 令牌一旦分家（文档一份、代码一份），下轮改版就要重新对一遍 —— 所以新增颜色、
/// 尺寸、图标常量一律先写进 `DESIGN.md`，再落到这里。
extension Color {

    // MARK: - 品牌色

    /// 品牌主色 `#ED8725`（稿子的 `oklch(0.72 0.16 58)`）。
    ///
    /// ⚠️ **界面里不要用它**。理由见 `DESIGN.md`「品牌色的适用范围」：
    /// 它与 app 现有的**警示色**撞车（`.orange` 表示「媒体入库失败」
    /// 「仅部分照片可访问」），把品牌主色用在界面上会让「正常的主要动作」和
    /// 「出事了」共用一个色相。
    ///
    /// 它只活在 **App 图标**里（`scripts/make-icon.py`）。
    static let brandPrimary = Color(red: 237 / 255.0, green: 135 / 255.0, blue: 37 / 255.0)

    /// 品牌辅色 `#1CA0AC`（`oklch(0.645 0.105 205)`）。
    ///
    /// 与主色不同，**它可以用在界面上** —— 因为青绿不在系统语义色里承担含义，
    /// 不会与任何警示或状态色混淆。当前只有一个落点：传输方向标识里的「下载」。
    static let brandSecondary = Color(red: 28 / 255.0, green: 160 / 255.0, blue: 172 / 255.0)

    // MARK: - 文本层级（对比度驱动的偏离）

    /// 「种类 / 大小 / 修改日期」这类**数据列**文字。
    ///
    /// 为什么不用 `.secondary`：`secondaryLabelColor` 在浅色模式下对白底只有
    /// **3.95:1**，低于 PRD §25 明文要求的 WCAG AA 正文 4.5:1。这里的取值把浅色提到
    /// **5.1:1**、深色 **6.3:1**。
    ///
    /// 这是**被 PRD 要求**的偏离，不是审美偏好 —— 但它仍然是「不引入非系统视觉」
    /// 原则的一次例外，所以只用在承载数据的那几处，纯装饰元素继续用系统语义色。
    static let columnText = Color.adaptive(
        light: NSColor(srgbRed: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0, alpha: 1.0),
        dark: NSColor(srgbRed: 235 / 255.0, green: 235 / 255.0, blue: 245 / 255.0, alpha: 0.62)
    )

    /// 依外观取值的颜色。
    ///
    /// `NSAppearance.bestMatch` 会把「高对比度」「降低透明度」这些辅助功能变体
    /// 归到 aqua / darkAqua 两档里 —— 我们不覆盖它们，只做明暗两分。
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }
}

/// 传输方向的身份色。
///
/// 改造前是散在 `TransferPanel` 里的三元表达式（上传 `accentColor` / 下载 `Color.teal`），
/// 「为什么下载是 teal」没有答案，而且 `Color.teal` 是系统调色板里的固定色板项、
/// **不跟随强调色** —— 用户把强调色设成青绿时两个方向就同色了。
///
/// 现在两个方向都有名字与理由：
/// - 上传 = 系统强调色（用户怎么设，它怎么显示 —— PRD §8「不引入非系统视觉」）
/// - 下载 = 品牌辅色（定名的青绿，理由见 `DESIGN.md`）
enum TransferDirectionTint {
    static func color(for direction: TransferPlan.Direction) -> Color {
        switch direction {
        case .upload: .accentColor
        case .download: .brandSecondary
        }
    }
}
