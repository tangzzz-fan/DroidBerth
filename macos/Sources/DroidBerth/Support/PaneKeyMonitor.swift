import AppKit

/// 拦截窗格级的无修饰键：Tab 循环聚焦（PRD §22）、空格 Quick Look（PRD §23）。
///
/// 只在「当前没有在编辑文本」时生效：重命名 / 新建文件夹 / 搜索等输入框里的
/// Tab 与空格保持系统默认语义，不被吞掉（PRD §22 的例外条款）。
///
/// 已知取舍：空格被全局接管，因此聚焦在按钮上时空格不再触发按钮。本产品
/// 窗格内可聚焦的按钮很少，且 PRD §23 明确要求空格 = Quick Look，故接受。
@MainActor
final class PaneKeyMonitor {
    /// 参数为 true 表示 Shift+Tab（反向循环）。
    var onCycleFocus: ((Bool) -> Void)?
    /// 返回 true 表示事件已被消费（空格被吃掉）；false 表示当前没有可预览的目标，
    /// 把空格还给系统，避免「按了没反应」的静默失败。
    var onQuickLook: (() -> Bool)?

    private var token: Any?

    private static let tabKeyCode: UInt16 = 48
    private static let spaceKeyCode: UInt16 = 49

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !TextEditingRelay.isEditing else { return event }

        // 有模态（sheet / 对话框 / 打开面板）时一律放行。
        // 少了这一条：删除确认弹窗弹着的时候按空格会去切换背后的 Quick Look ——
        // 那一刻空格属于弹窗，不属于窗格。
        guard NSApp.modalWindow == nil else { return event }

        let relevant: NSEvent.ModifierFlags = [.command, .option, .control]
        let bare = event.modifierFlags.intersection(relevant).isEmpty

        // 预览面板开着时：**只有空格归我们**（收起），其余按键全部放行，交给面板自己
        // 处理 —— 方向键在条目间切换、Esc 关闭、⌘ 系列仍然是系统快捷键。
        // 抢走 Tab 会让正在预览的人莫名其妙（焦点被搬到另一个窗格去了）。
        if QuickLookPresenter.shared.isVisible {
            guard bare, !event.modifierFlags.contains(.shift),
                  event.keyCode == Self.spaceKeyCode else { return event }
            _ = onQuickLook?()
            return nil
        }

        // 有修饰键时交还给系统（⌘⇥ 切应用、⌘Space 聚焦搜索 等）
        guard bare else { return event }

        switch event.keyCode {
        case Self.tabKeyCode:
            onCycleFocus?(event.modifierFlags.contains(.shift))
            return nil

        case Self.spaceKeyCode:
            guard !event.modifierFlags.contains(.shift) else { return event }
            guard onQuickLook?() == true else { return event }
            return nil

        default:
            return event
        }
    }
}
