// 把某个进程的 UI 树打出来（Accessibility API）。
//
// 为什么需要它：截图能看「长什么样」，但**判不了「数量对不对」「点了会不会动」**。
// 而本项目长期把「交互层验收」整块挂在人眼上（README 已知限制）。有了这条，
// 一部分验收可以变成**机器可读的判据**：
//
//   · 状态栏写的数字 vs 列表里真有几行 —— 截图里肉眼数行容易错，这里一数就准
//   · 弹窗/浮层里到底有哪几项 —— 不必点开截图再靠读图
//   · 某个按钮在不在、能不能按（`AXEnabled`）
//
// ⚠️ 需要「辅助功能」权限（系统设置 → 隐私与安全性 → 辅助功能）。
//    没有时 `AXUIElementCopyAttributeValue` 返回 **-25211**，本工具会明说。
//
// 用法：
//
//   ./ui-report.swift DroidBerth                 # 打印整棵树的骨架
//   ./ui-report.swift DroidBerth --texts         # 只打印所有有文字的节点（最常用）
//   ./ui-report.swift DroidBerth --press 位置    # 按标题/描述/值里含「位置」的那个元素
//
// 注意：它是**只读**的，唯一会改状态的是 `--press`（而且只按一下）。
import AppKit
import ApplicationServices
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}
let target = args.first { !$0.hasPrefix("--") } ?? "DroidBerth"
let onlyTexts = args.contains("--texts")
let pressNeedle = value("--press")

func attr(_ element: AXUIElement, _ name: CFString) -> String {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &out) == .success else { return "" }
    if let text = out as? String { return text }
    if let number = out as? NSNumber { return number.stringValue }
    return ""
}

let apps = NSWorkspace.shared.runningApplications.filter {
    ($0.localizedName ?? "").contains(target) && $0.activationPolicy == .regular
}
guard let app = apps.first else {
    FileHandle.standardError.write(Data("「\(target)」没在跑（或它不是普通 App）\n".utf8))
    exit(1)
}
print("进程   : \(app.localizedName ?? "?") pid=\(app.processIdentifier)")

let axApp = AXUIElementCreateApplication(app.processIdentifier)
var windowsRef: CFTypeRef?
let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
guard err == .success else {
    FileHandle.standardError.write(Data("""
    AXWindows 失败，err=\(err.rawValue)（-25211 = 没有「辅助功能」权限）。
    授权：系统设置 → 隐私与安全性 → 辅助功能 → 勾上运行本命令的那个 app → 重启它。

    """.utf8))
    exit(2)
}
let windows = (windowsRef as? [AXUIElement]) ?? []
print("窗口数 : \(windows.count)")

func walkTree(_ element: AXUIElement, depth: Int, limit: Int) {
    guard depth <= limit else { return }
    let role = attr(element, kAXRoleAttribute as CFString)
    let title = attr(element, kAXTitleAttribute as CFString)
    let valueText = attr(element, kAXValueAttribute as CFString)
    let desc = attr(element, kAXDescriptionAttribute as CFString)
    let enabled = attr(element, kAXEnabledAttribute as CFString)

    if !onlyTexts || !title.isEmpty || !valueText.isEmpty || !desc.isEmpty {
        let pad = String(repeating: "  ", count: depth)
        var line = "\(pad)\(role)"
        if !title.isEmpty { line += " title=「\(title)」" }
        if !desc.isEmpty { line += " desc=「\(desc)」" }
        if !valueText.isEmpty { line += " value=「\(valueText.prefix(60))」" }
        // 只对能按的东西报 enabled，免得满屏噪声
        if !enabled.isEmpty, role == "AXButton" { line += " enabled=\(enabled)" }
        print(line)
    }

    var childrenRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
    for child in (childrenRef as? [AXUIElement]) ?? [] {
        walkTree(child, depth: depth + 1, limit: limit)
    }
}

// ── 按一下 ────────────────────────────────────────────────────────────────
// 找**第一个**在三处文字（title / description / value）里含目标串、且能按的元素。
if let needle = pressNeedle {
    var hit: AXUIElement?
    func search(_ element: AXUIElement, depth: Int) {
        guard hit == nil, depth <= 12 else { return }
        let text = attr(element, kAXTitleAttribute as CFString)
            + attr(element, kAXDescriptionAttribute as CFString)
            + attr(element, kAXValueAttribute as CFString)
        if text.contains(needle) {
            var pressable: CFArray?
            AXUIElementCopyActionNames(element, &pressable)
            if let actions = pressable as? [String], actions.contains(kAXPressAction as String) {
                hit = element
                return
            }
        }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        for child in (childrenRef as? [AXUIElement]) ?? [] { search(child, depth: depth + 1) }
    }
    for window in windows { search(window, depth: 1) }
    guard let element = hit else {
        FileHandle.standardError.write(Data("找不到含「\(needle)」且可按下（AXPress）的元素\n".utf8))
        exit(3)
    }
    let pressed = AXUIElementPerformAction(element, kAXPressAction as CFString)
    print("已按  : 「\(needle)」 err=\(pressed.rawValue)")
    // 弹层是**另一个 window**（layer 不为 0），等它出来再打。
    usleep(600_000)
}

// ── 打印 ─────────────────────────────────────────────────────────────────
// 每次重新取 windows —— `--press` 之后弹层是新出现的。
var freshRef: CFTypeRef?
AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &freshRef)
let fresh = (freshRef as? [AXUIElement]) ?? []
let maxDepth = onlyTexts ? 20 : 8
print("── UI 树（深度上限 \(maxDepth)\(onlyTexts ? "，只打有文字的节点" : "")）")
for (index, window) in fresh.enumerated() {
    print("  [窗口 \(index)]")
    walkTree(window, depth: 2, limit: maxDepth)
}
