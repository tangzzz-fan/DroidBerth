import AppKit
import QuickLookUI

/// 就地预览（PRD §23）。**直接持有 `QLPreviewPanel`，不用 SwiftUI 的 `.quickLookPreview(_:)`。**
///
/// 为什么换掉那个修饰符（2026-10-10 实测）：
/// 它只暴露一个 `Binding<URL?>`，而**面板被用户关掉后它是否把 nil 写回来没有承诺**。
/// 于是「再按一次空格」只是把同一个值又写了一遍 —— SwiftUI 看不到变化，面板收不回去。
/// 自己持有面板后，`isVisible` 是权威状态，切换逻辑不靠猜。
///
/// 顺带白拿两样原生能力：
/// - 面板内**方向键上下切换**条目（`QLPreviewPanel` 原生支持，只要我们给出完整列表）
/// - Esc 关闭、缩放/全屏等面板自带行为
///
/// 谁把它接进响应者链：`DroidBerthApp.AppDelegate` 实现
/// `acceptsPreviewPanelControl:` —— 面板只认响应者链上第一个愿意接管的对象，
/// 而 App 代理是**每条响应者链的终点**，比挂在某个视图上稳。
@MainActor
final class QuickLookPresenter: NSObject {
    static let shared = QuickLookPresenter()

    private var items: [URL] = []

    /// 面板当前是否在屏上。**这是切换逻辑唯一的判据。**
    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// 空格键的语义：开着就关，否则打开当前选中项。与 Finder 一致。
    func toggle(items: [URL], startAt index: Int) {
        if isVisible {
            dismiss()
        } else {
            present(items: items, startAt: index)
        }
    }

    func present(items: [URL], startAt index: Int) {
        guard !items.isEmpty else { return }
        self.items = items
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.currentPreviewItemIndex = index.clamped(to: items.indices)
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    /// 面板开着时跟着选择走（Finder 行为）。关着就什么都不做。
    func follow(items: [URL], startAt index: Int) {
        guard isVisible, !items.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        let changed = self.items != items
        self.items = items
        panel.currentPreviewItemIndex = index.clamped(to: items.indices)
        if changed { panel.reloadData() }
    }

    func dismiss() {
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
    }
}

// MARK: - 面板的数据源与事件兜底

// `@preconcurrency`：`QLPreviewPanelDataSource` / `Delegate` 的方法在 SDK 里没有
// `NS_SWIFT_UI_ACTOR` 标注，但实际只会在主线程调用。没有这个标注，@MainActor 的
// 类没法在严格并发下满足协议要求。
extension QuickLookPresenter: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard items.indices.contains(index) else { return nil }
        // QLPreviewItem 的实现就是 NSURL（文件 URL）。
        return items[index] as NSURL
    }
}

extension QuickLookPresenter: @preconcurrency QLPreviewPanelDelegate {
    /// 面板没处理的事件转到这里。
    ///
    /// 空格由 `PaneKeyMonitor` 在更靠前的位置消费，正常走不到这里；留着是**兜底**：
    /// 万一某条路径绕过了那个监听，空格仍然能收起面板，而不是留下一个关不掉的面板。
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 else { return false }
        dismiss()
        return true
    }
}

private extension Int {
    /// 夹到合法下标范围，集合为空时给 0（`QLPreviewPanel` 允许空列表，
    /// 传 NSNotFound 反而会让它认为没有当前项）。
    func clamped(to range: Range<Int>) -> Int {
        guard !range.isEmpty else { return 0 }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound - 1)
    }
}
