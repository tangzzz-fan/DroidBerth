import AppKit

/// 拦截窗格级的无修饰键：Tab 循环聚焦（PRD §22）、空格 Quick Look（PRD §23）、
/// 网格视图的方向键与字母跳转（PRD §13.3）、回车重命名（PRD §13.1）。
///
/// 只在「当前没有在编辑文本」时生效：重命名 / 新建文件夹 / 搜索等输入框里的
/// Tab 与空格保持系统默认语义，不被吞掉（PRD §22 的例外条款）。
///
/// ## 消费与放行
///
/// 这一层挂在 `NSEvent.addLocalMonitorForEvents` 上，优先级**高于一切窗口**，
/// 所以每一条新键都必须自己知道「什么时候不该管」：
///
/// - 每个回调都返回「是否已消费」。**没消费就原样交还系统** —— 列表与分栏的
///   原生方向键 / type-select 靠这一条才没被抢走（我们只在聚焦窗格确实是网格、
///   且确实算得出落点时才消费）。
/// - 回车**不挂菜单快捷键**，与空格 / Tab 同一条理由：无修饰键的菜单快捷键会
///   先于文本框拿到事件。
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
    /// 网格视图的方向键。第二个参数为 true 表示 Shift 按住（扩展选择）。
    /// 返回 true 表示已消费。
    var onGridMove: ((GridNavigation.Move, Bool) -> Bool)?
    /// 网格视图的字母跳转。第一个参数是**累积**的字母缓冲（`s` → `su` → `sun`），
    /// 第二个参数表示这枚字母是否接在上一枚之后（false = 新一轮）。返回 true 表示已消费。
    var onGridTypeSelect: ((String, Bool) -> Bool)?
    /// 回车重命名。返回 true 表示已消费。
    var onRename: (() -> Bool)?

    private var token: Any?

    /// 字母跳转的缓冲与它的截止时刻。
    ///
    /// 不用 `Timer`：只需要在**下一次按键**时判断「离上一枚字母是不是太久」，
    /// 惰性比较比维护一个会跑的生命周期更省事，也不会在没人按键时空转。
    private var typeSelectBuffer = ""
    private var typeSelectDeadline = Date.distantPast
    private static let typeSelectTimeout: TimeInterval = 0.8

    private static let tabKeyCode: UInt16 = 48
    private static let spaceKeyCode: UInt16 = 49
    /// 主键盘回车与小键盘回车。
    private static let returnKeyCodes: Set<UInt16> = [36, 76]
    private static let arrowMoves: [UInt16: GridNavigation.Move] = [
        123: .left, 124: .right, 125: .down, 126: .up,
    ]

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
        // 那一刻空格属于弹窗，不属于窗格。回车同理：弹窗里的回车是「确定」。
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

        // 有修饰键时交还给系统（⌘⇥ 切应用、⌘Space 聚焦搜索 等）。
        // ⇧ 不在其中：⇧+方向键是「扩展选择」，要往下走。
        guard bare else { return event }

        // ── 网格视图的三个键（PRD §13.3）────────────────────────────────
        // 一律「消费了才拦」。列表与分栏的方向键 / type-select 是原生能力，
        // 只要回调说没消费，事件就照原样流下去。
        if Self.returnKeyCodes.contains(event.keyCode) {
            return onRename?() == true ? nil : event
        }

        if let move = Self.arrowMoves[event.keyCode] {
            return onGridMove?(move, event.modifierFlags.contains(.shift)) == true ? nil : event
        }

        if let typed = Self.typeSelectCharacter(event) {
            let now = Date()
            let isContinuation = now < typeSelectDeadline
            let buffer = isContinuation ? typeSelectBuffer + typed : typed
            typeSelectBuffer = buffer
            typeSelectDeadline = now.addingTimeInterval(Self.typeSelectTimeout)
            return onGridTypeSelect?(buffer, isContinuation) == true ? nil : event
        }

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

    /// 这一枚按键能不能进字母跳转的缓冲。
    ///
    /// 判据是「排除法」而不是「白名单」：可打印的字符太多了（中文、emoji、`-`、`#`），
    /// 列举一定会漏。要排掉的是三类**看着也像字符**的东西：
    ///
    /// 1. 控制字符 —— Tab(`\t`) 与回车(`\r`) 都在这一档，而它们在本产品里有别的语义；
    /// 2. 空格 —— 归 Quick Look（PRD §23）；
    /// 3. AppKit 用 `U+F700–U+F8FF` 这一段私有码位表示功能键（方向键、F1–F12、
    ///    前向删除……）。**不排掉它们，按一下右方向键就会往缓冲里塞一个不可见字符。**
    ///
    /// 外加 `U+007F`（Delete）：它的码位高于空格，前三条都拦不住它。
    private static func typeSelectCharacter(_ event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
        for scalar in characters.unicodeScalars {
            if scalar.value < 0x21 { return nil }
            if scalar.value == 0x7F { return nil }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }
}
