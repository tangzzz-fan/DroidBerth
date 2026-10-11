import AppKit
import SwiftUI

/// 设备连接引导卡片（PRD §17.1 / §17.2）。
///
/// 为什么不是一个 `ContentUnavailableView`：它要装一张 260pt 高的手机示意图 ——
/// `ContentUnavailableView` 的 label 是 `@ViewBuilder`，塞得进去，但它的字号与间距
/// 是给「一个符号 + 一句话」设计的，塞一张示意图会把整块版式撑变味。
///
/// 尺寸约定：**按 300pt 宽设计**（要嵌进 340pt 的窗格），正文不小于 11pt。
/// 外层的 `ScrollView` 是必需的 —— 内容高度远超一个 340pt 窗格的高度。
struct DeviceGuideCard: View {
    let guide: DeviceGuide

    @State private var showsTroubleshooting = false

    private let contentWidth: CGFloat = 300

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                illustration

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: guide.headerSymbol)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(guide.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(guide.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                steps

                if let note = guide.brandNote {
                    brandNote(note)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button(guide.primaryTitle, action: guide.primaryAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                    Button(showsTroubleshooting ? "收起排查步骤" : "连接不上？") {
                        showsTroubleshooting.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                if showsTroubleshooting {
                    troubleshooting
                }
            }
            .frame(width: contentWidth, alignment: .leading)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 插图

    @ViewBuilder
    private var illustration: some View {
        switch guide.kind {
        case .usbAuthorization: PhoneAuthorizationMockup()
        case .wirelessReactivation: wirelessIllustration
        }
    }

    /// 无线重新激活用不着画手机 —— 那一步发生在 Mac 的菜单里。
    private var wirelessIllustration: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Image(systemName: "cable.connector")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Image(systemName: "laptopcomputer")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    // MARK: - 三步说明

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(.quaternary, in: Circle())
                    Text(step)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func brandNote(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // 厂商文案里带 `**…：**` 强调，走 Markdown 渲染（见 `Text(markdown:)`）。
            Text(markdown: note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(guide.troubleshooting.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").font(.caption2).foregroundStyle(.tertiary)
                    Text(item)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }
}

/// Android 上那个「允许 USB 调试吗？」授权弹窗的示意图。
///
/// **这是插图，不是控件** —— 它画的是**另一台设备**的界面，本来就不该用 macOS 的系统控件
/// 去表达。但它同样不引入非系统视觉：底色、分隔线、文字层级全部走语义色，因此深色模式
/// 自动跟随。
private struct PhoneAuthorizationMockup: View {
    var body: some View {
        VStack(spacing: 0) {
            // 听筒槽
            Capsule()
                .fill(.quaternary)
                .frame(width: 34, height: 3)
                .padding(.top, 8)
                .padding(.bottom, 10)

            dialog
                .padding(.horizontal, 10)
                .padding(.bottom, 14)

            Spacer(minLength: 0)
        }
        .frame(width: 196, height: 246)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement()
        .accessibilityLabel("手机上会弹出「允许 USB 调试吗？」的授权窗口，"
                            + "里面有这台计算机的 RSA 密钥指纹、一个「一律允许使用这台计算机进行调试」"
                            + "复选框，以及取消、允许两个按钮")
    }

    private var dialog: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("允许 USB 调试吗？")
                .font(.caption)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)

            Text("计算机的 RSA 密钥指纹为：")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 稿子 §3.3 明示这是**示例值**（真机上显示的是这台 Mac 的真实指纹）。
            Text("A4:7B:9F:2C:11:E8:5D:03\n6A:B2:44:19:7C:D5:88:31")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineSpacing(1)

            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "checkmark.square")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("一律允许使用这台计算机进行调试")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                mockButton("取消", prominent: false)
                mockButton("允许", prominent: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func mockButton(_ title: String, prominent: Bool) -> some View {
        Text(title)
            .font(.system(size: 10))
            .foregroundStyle(prominent ? Color.white : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear)
            )
            .clipShape(Capsule())
    }
}
