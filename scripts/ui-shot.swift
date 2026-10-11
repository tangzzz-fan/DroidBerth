// 找出某个进程拥有的窗口，打印 `窗口id<TAB>标题<TAB>x,y,w,h`，供 `screencapture -l` 精确截图用。
//
// 为什么不用 `screencapture -w`（交互式选窗口）：那要**人点一下**，自动化里没法用。
//
// ⚠️ 只取 id / 拥有者 / 标题 / 边界 —— 这几样**不需要「屏幕录制」权限**就能拿到；
//    真正抓像素那一步才需要（由 `screencapture` 负责）。
//
// 用法：  ./ui-shot.swift DroidBerth
import CoreGraphics
import Foundation

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DroidBerth"

guard let list = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("拿不到窗口列表\n".utf8))
    exit(2)
}

var matched = 0
for window in list {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains(target) else { continue }
    let number = window[kCGWindowNumber as String] as? Int ?? -1
    let title = window[kCGWindowName as String] as? String ?? ""
    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    // layer != 0 的是菜单 / tooltip / 阴影之类的附属窗口，不是主窗口。
    guard layer == 0 else { continue }
    matched += 1
    let x = Int(bounds["X"] ?? 0), y = Int(bounds["Y"] ?? 0)
    let w = Int(bounds["Width"] ?? 0), h = Int(bounds["Height"] ?? 0)
    print("\(number)\t\(title)\t\(x),\(y),\(w),\(h)")
}
if matched == 0 {
    FileHandle.standardError.write(Data("没找到拥有者包含「\(target)」的窗口\n".utf8))
    exit(1)
}
