import AppKit

/// 拦截 Tab 键，用于在两个窗格之间循环聚焦（PRD §22）。
///
/// 只在「当前没有在编辑文本」时生效：重命名 / 新建文件夹 / 搜索等输入框里的 Tab
/// 保持系统默认语义，不被吞掉。这是 PRD §22 明确要求的例外。
@MainActor
final class PaneCycleKeyMonitor {
    /// 参数为 true 表示 Shift+Tab（反向循环）。
    private let handler: (Bool) -> Void
    private var token: Any?

    private static let tabKeyCode: UInt16 = 48

    init(handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

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
        guard event.keyCode == Self.tabKeyCode else { return event }
        guard !Self.isEditingText else { return event }
        // 有修饰键时交还给系统（⌘⇥ 切应用、⌃⇥ 等）
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control]
        guard event.modifierFlags.intersection(relevant).isEmpty else { return event }

        handler(event.modifierFlags.contains(.shift))
        return nil
    }

    /// 首响应者是文本视图（或正在编辑的文本字段）时，Tab 属于文本编辑语义。
    private static var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if let view = responder as? NSView, view is NSTextField { return true }
        return false
    }
}
