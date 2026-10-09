import AppKit

/// 把 ⌘C / ⌘V / ⌘X / ⌘A / ⌘⌫ 在「焦点在文本框里」时交还给系统文本编辑语义。
///
/// PRD §22 明确要求：焦点在文本输入框（重命名、新建文件夹、搜索）时，
/// 这些快捷键必须恢复为标准文本语义。菜单项一旦被按下就会吞掉事件，
/// 所以只能在动作里显式转发一次。
@MainActor
enum TextEditingRelay {
    /// 当前首响应者是否正在编辑文本。
    static var isEditing: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    /// 若正在编辑文本，把选择器沿响应链转发；返回是否已转发。
    @discardableResult
    static func forwardIfEditing(_ selector: Selector) -> Bool {
        guard isEditing else { return false }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }
}
