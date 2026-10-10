import AppKit
import SwiftUI

/// 列表 / 网格 / 预览里那个「行首小图标」。
///
/// **两栏共用一套符号，只有呈现方式不同**（策略乙）：
///
/// | 来源 | 呈现 | 为什么 |
/// | --- | --- | --- |
/// | `.local` | 系统**彩色**图标（`NSWorkspace`） | 文件真实存在 ⇒ 零维护地拿到 Finder 的观感，顺带白拿替身角标与 App 包图标 |
/// | `.remote` | 单色 SF Symbol | 条目要过一次 `adb` 才碰得到，视觉上更「轻」是有信息的 |
/// | `.photo` | 单色 SF Symbol | 图库条目不是文件路径，缩略图要走 PhotoKit（另立一票） |
///
/// 「两栏都彩色」被明确否决，理由不是不好看，而是它**在设备侧会稳定谎报**：
/// `base.aab` 这类 Android 专有扩展名在设备栏只能回退成灰色的通用文稿图标，
/// 而它混在一排彩色图标里看起来仍像「系统认识它」。
///
/// `origin` 是唯一的分支依据 —— 颜色承担来源，形状承担类型（`FileTypeIcon`）。
struct EntryIconView: View {
    let entry: BrowserEntry
    /// 视觉边长（pt）。网格会传 72–240 的档位。
    var size: CGFloat = 16

    var body: some View {
        Group {
            if entry.origin == .local, let image = FileIconCache.icon(forPath: entry.path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: entry.systemImage)
                    // SF Symbol 的字形自带留白，按字号给到视觉等宽即可。
                    .font(.system(size: size * 0.86))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
