import SwiftUI

/// 窗格空态的结构化描述（PRD §17.1 / §25）。
///
/// ## 为什么要有这个类型
///
/// 改造前空态只是 `MainView` 拼出来的**一个字符串**，交给
/// `ContentUnavailableView { Label(message, systemImage: "tray") }`。两个后果：
///
/// 1. **四类语义完全不同的空态长得一模一样** —— 未连接设备 / 照片权限被拒 /
///    文件夹是空的 / 搜索无结果，全是同一个 `tray` 符号。而 `tray` 既不代表
///    「没连设备」也不代表「没有搜索结果」。
/// 2. **挂不上按钮** —— 字符串传不了动作，于是三类本该有下一步的空态一个按钮都没有：
///    清筛选要去工具栏找小叉、重新检测要去设备菜单里翻。
///
/// 现在图标、文案、动作都在这里，`EntryTable` / `EntryGrid` / `PhotoSourceView`
/// 只负责把它画出来。
struct PaneEmptyState {
    struct Action {
        var title: String
        var handler: () -> Void
    }

    var systemImage: String = "tray"
    var title: String
    var message: String? = nil
    /// 主按钮（`.borderedProminent`）。
    var primary: Action? = nil
    /// 次级动作，画成文字链。**刻意保留**：主按钮只能有一个，但「稍后再说」
    /// 「连接不上？」这类出口不该因此消失。
    var secondary: Action? = nil
    /// 非 nil 时额外给一个「连接不上？」文字链，点开 popover 显示这些排查步骤。
    ///
    /// 为什么要一个 popover：把 4 条排查清单常驻在空态里会把版式撑得很长，
    /// 而绝大多数插入设备的用户不需要它。
    var troubleshooting: [String]? = nil
    /// 非 nil 时改用「设备连接引导卡片」版式（PRD §17.1 / §17.2），
    /// 忽略上面的图标、动作与 troubleshooting。
    var guide: DeviceGuide? = nil

    /// 四类常规空态 + 两类错误态。刻意集中成静态工厂，免得每个调用点各拼一遍文案。
    static func folderIsEmpty() -> PaneEmptyState {
        PaneEmptyState(
            systemImage: "folder",
            title: "这个文件夹是空的",
            // 「中性状态不要做成操作入口」：空文件夹是正常状态，不是错误，
            // 所以既不使用警示色，也不给主按钮。
            message: "这里还没有文件。可以从另一栏拖进来，或直接把文件拖到这个窗口。"
        )
    }

    static func noSearchMatch(query: String, onClear: @escaping () -> Void) -> PaneEmptyState {
        PaneEmptyState(
            systemImage: "magnifyingglass",
            // 主文案带上产生空态的**那个具体值**：比「无搜索结果」多给一条
            // 「我搜的是什么」的确认信息。
            title: "没有找到与「\(query)」匹配的文件",
            message: "试试更短的关键词，或者清除当前的筛选条件。",
            primary: Action(title: "清除搜索词", handler: onClear)
        )
    }

    static func failed(_ message: String, onRetry: @escaping () -> Void) -> PaneEmptyState {
        PaneEmptyState(
            systemImage: "exclamationmark.triangle",
            title: "打不开这个位置",
            message: message,
            primary: Action(title: "重试", handler: onRetry)
        )
    }
}

/// 设备连接引导卡片的内容（PRD §17.1 / §17.2）。
///
/// PRD §17.1 的原文要求是「手机上的『允许 USB调试？』**图示** + 『勾选始终允许再点确定』
/// + 『已完成，重新检测』**按钮** + 按检测到的**品牌**显示对应图文」。这四项在改造前
/// 一项都没有 —— 只有 `deviceEmptyMessage` 返回的一句话。
struct DeviceGuide {
    enum Kind {
        /// 设备插着但未授权（`unauthorized`）。
        case usbAuthorization
        /// 手机重启后 `tcpip` 端口失效，且当前没有 USB（PRD §17.2）。
        case wirelessReactivation
    }

    var kind: Kind
    /// 卡片头部的小图标（设计稿 §3.3 技术注：USB 授权用 `cable.connector`，
    /// 与「未连接设备」空态同一个符号，让两处一眼认出是同一件事）。
    var headerSymbol: String
    var title: String
    var subtitle: String
    var steps: [String]
    var primaryTitle: String
    var primaryAction: () -> Void
    /// 厂商附加说明（PRD §17.1「厂商差异」）。**允许 Markdown 行内标记**，
    /// 由 `Text(markdown:)` 渲染。识别不出品牌时应传通用文案
    /// （`AndroidDevice.BrandFamily.genericAuthorizationNote`），不要传 nil。
    var brandNote: String? = nil
    /// 「连接不上？」展开后的排查清单。同样允许 Markdown。
    var troubleshooting: [String]
}

/// 空态的呈现入口。常规空态走系统 `ContentUnavailableView`；
/// 需要插图的连接引导走 `DeviceGuideCard`（`ContentUnavailableView` 的 label
/// 放不下 260pt 高的手机示意图）。
struct PaneEmptyStateView: View {
    let state: PaneEmptyState

    @State private var showsTroubleshooting = false

    var body: some View {
        if let guide = state.guide {
            DeviceGuideCard(guide: guide)
        } else if state.primary != nil || state.secondary != nil || state.troubleshooting != nil {
            ContentUnavailableView {
                Label(state.title, systemImage: state.systemImage)
            } description: {
                if let message = state.message { Text(message) }
            } actions: {
                actions
            }
        } else {
            ContentUnavailableView {
                Label(state.title, systemImage: state.systemImage)
            } description: {
                if let message = state.message { Text(message) }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let primary = state.primary {
            Button(primary.title, action: primary.handler)
                .buttonStyle(.borderedProminent)
        }
        if let secondary = state.secondary {
            Button(secondary.title, action: secondary.handler)
                .buttonStyle(.link)
        }
        if let troubleshooting = state.troubleshooting {
            Button("连接不上？") { showsTroubleshooting.toggle() }
                .buttonStyle(.link)
                .popover(isPresented: $showsTroubleshooting, arrowEdge: .bottom) {
                    TroubleshootingPopover(items: troubleshooting)
                }
        }
    }
}

/// 「连接不上？」的排查清单。刻意做成 popover 而不是常驻文本 —— 插入设备顺利的用户
/// 永远不需要打开它。
struct TroubleshootingPopover: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("连接不上时按顺序试一遍")
                .font(.caption)
                .fontWeight(.semibold)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(.tertiary)
                    Text(markdown: item)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }
}

extension Text {
    /// 把一段可能带 `**粗体**` 的文案渲成 `Text`。
    ///
    /// ⚠️ **不能只靠 `AttributedString(markdown:)`**。CommonMark 有一组「分隔符左右侧」
    /// （left/right-flanking）规则：`**` 想闭合，它的**后面**必须跟空白、标点或行尾。
    /// 我们的文案是中文，`**小米设备：**先到…` 里闭合的 `**` 后面紧跟的是**汉字** ——
    /// 于是它不满足闭合条件，`**` 会被**原样渲染出来**（实测确认，四个样本里三个中招）。
    ///
    /// 所以先试 Markdown；若结果里仍残留 `**`，再按「开头一段粗体」这种形态手工拆。
    /// 本项目全部文案都是这一种形态（`**前缀：**正文`）—— 够用，且不必为了排版引半个
    /// Markdown 解析器进来。
    ///
    /// 解析失败一律退回 `verbatim`：绝不因为一段文案让界面渲染不出来。
    init(markdown: String) {
        if let attributed = try? AttributedString(markdown: markdown),
           !String(attributed.characters).contains("**") {
            self.init(attributed)
            return
        }
        if markdown.hasPrefix("**"), let closing = markdown.dropFirst(2).range(of: "**") {
            let bold = String(markdown.dropFirst(2)[..<closing.lowerBound])
            let rest = String(markdown[closing.upperBound...])
            self = Text(bold).bold() + Text(verbatim: rest)
            return
        }
        self.init(verbatim: markdown)
    }
}
