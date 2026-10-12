import AppKit
import ApplicationServices
import Foundation

// 设置某个进程主窗口的尺寸与位置。
//
// 为什么不用 AppleScript：`tell application "System Events"` 走的是 **Automation**
// 权限（Apple Events），那是与「辅助功能」**完全不同的 TCC 类别**。
// 2026-10-12 实测本机没给 ⇒ `execution error: 发生权限违例 (-10004)`。
// 而 AX API 只需要「辅助功能」—— 本项目的 `ui-report` / `ui-shot` 都走它，已经授权。
//
// 用法：window-resize <App 名> <宽> <高> [x] [y]
//   成功打印实测到的尺寸（**读回来验证**，不假定设置一定生效）。

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("用法: window-resize <App 名> <宽> <高> [x] [y]\n".utf8))
    exit(2)
}
let targetName = args[1]
guard let wantW = Double(args[2]), let wantH = Double(args[3]), wantW > 0, wantH > 0 else {
    FileHandle.standardError.write(Data("宽高要是正数\n".utf8)); exit(2)
}

let running = NSWorkspace.shared.runningApplications
    .filter { ($0.localizedName ?? "").contains(targetName) }
guard let app = running.first else {
    FileHandle.standardError.write(Data("「\(targetName)」没在运行\n".utf8)); exit(1)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)

var windowsRef: CFTypeRef?
let listErr = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
guard listErr == .success, let windows = windowsRef as? [AXUIElement], let window = windows.first else {
    FileHandle.standardError.write(Data(
        "拿不到窗口（AX err=\(listErr.rawValue)；-25211 = 没有「辅助功能」权限）\n".utf8))
    exit(1)
}

// ⚠️ 顺序是**先位置、后尺寸**：只设尺寸时，系统为了让标题栏可见可能把窗口往下推，
// 于是「设成 1440×900」得到的却是「1440×900 但位置不确定」。先钉位置更可控。
if args.count >= 6, let x = Double(args[4]), let y = Double(args[5]) {
    var point = CGPoint(x: x, y: y)
    if let value = AXValueCreate(.cgPoint, &point) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }
}

var size = CGSize(width: wantW, height: wantH)
if let value = AXValueCreate(.cgSize, &size) {
    let err = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    if err != .success {
        FileHandle.standardError.write(Data("设置尺寸被拒（AX err=\(err.rawValue)）\n".utf8))
        exit(1)
    }
}

// **读回来**：AX 的设置可能被窗口的最小/最大尺寸夹住，不读回来就不知道真实值。
// （本项目窗口有最小宽度限制，所以这一条不是形式主义。）
func readSize(_ element: AXUIElement) -> CGSize {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
          let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return .zero }
    var result = CGSize.zero
    AXValueGetValue(value as! AXValue, .cgSize, &result)
    return result
}

// 给窗口一点时间落定再读 —— 同步读完有时拿到的是旧值。
var actual = readSize(window)
for _ in 0..<10 where Int(actual.width) != Int(wantW) || Int(actual.height) != Int(wantH) {
    usleep(120_000)
    actual = readSize(window)
}

print("  窗口实测: \(Int(actual.width))×\(Int(actual.height))（目标 \(Int(wantW))×\(Int(wantH))）")
if Int(actual.width) != Int(wantW) || Int(actual.height) != Int(wantH) {
    FileHandle.standardError.write(Data(
        "尺寸没落到位 —— 可能被窗口的最小尺寸限制夹住了（本项目最小宽度是 1180）\n".utf8))
    exit(1)
}
