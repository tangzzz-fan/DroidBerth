// 诊断：**Dock 到底拿到了什么图标**。
//
// 症状是「bundle 里 icon.icns 明明在、Finder 里也是对的，但 Dock 上还是通用图标」时，
// 不要靠截图判断 —— 读 `NSRunningApplication.icon` 就是 Dock 用的那个值。
// 通用应用图标是白/灰；本项目的图标在 (width/4, height/2) 处是 `(240,151,67)` 品牌橙。
//
// 跑法（约 3 秒）：
//
//     mkdir -p /tmp/dockicon && cp scripts/diagnose-dock-icon.swift /tmp/dockicon/main.swift
//     swiftc -O -o /tmp/dockicon/run \
//       -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
//       -swift-version 6 -strict-concurrency=complete -Xfrontend -disable-sandbox \
//       /tmp/dockicon/main.swift && /tmp/dockicon/run
//
// 若结果是通用图标，按 README「图标不生效 / Dock 上还是旧图标」清 LaunchServices 的
// 幽灵记录并 `killall Dock` —— 根因几乎总在那里，不在图标文件本身。
//
// ⚠️ 打印的颜色只在**像素级别**说明问题：中心是白的是因为图标正中是两块白面板的接缝，
//    判据看 (w/4, h/2) 那一处（在橙色底板上）。
import AppKit
import Foundation

let bundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "droidberth"
let running = NSWorkspace.shared.runningApplications.filter {
    ($0.bundleIdentifier ?? "").lowercased().contains(bundleID.lowercased())
}

print("=== 正在运行、bundle id 含「\(bundleID)」的实例：\(running.count) 个 ===")
for app in running {
    print()
    print("  bundleURL : \(app.bundleURL?.path ?? "(拿不到)")")
    print("  pid       : \(app.processIdentifier)   isActive: \(app.isActive)")
    guard let icon = app.icon, let tiff = icon.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), rep.pixelsWide > 0 else {
        print("  图标      : 拿不到")
        continue
    }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    func rgb(_ x: Int, _ y: Int) -> (String, Int, Int, Int) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return ("?", 0, 0, 0) }
        let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255), b = Int(c.blueComponent * 255)
        return (String(format: "(%3d,%3d,%3d)", r, g, b), r, g, b)
    }
    let (center, _, _, _) = rgb(w / 2, h / 2)
    let (quarter, r, g, b) = rgb(w / 4, h / 2)
    print("  图标尺寸  : \(w)x\(h)")
    print("  (w/2,h/2) : \(center)   ← 图标正中是两块白面板的接缝")
    print("  (w/4,h/2) : \(quarter)   ← **判据看这一处**")
    // 品牌橙 ≈ (240,151,67)；通用应用图标这一处接近白/灰（三通道差 < 12）
    let spread = max(r, max(g, b)) - min(r, min(g, b))
    print("  ⇒ \(spread > 40 ? "有彩色底板 ⇒ 是**本项目的图标**" : "接近中性灰 ⇒ **通用应用图标**（去清 LaunchServices 记录）")")
}

print()
print("=== 磁盘上各副本的图标状况 ===")
let home = NSHomeDirectory()
let candidates = [
    "/Applications/DroidBerth.app",
    "\(home)/Developments/DroidBerth/macos/build/dd/Build/Products/Release/DroidBerth.app",
    "\(home)/Developments/DroidBerth/macos/build/dd-debug/Build/Products/Debug/DroidBerth.app",
]
var extra: [String] = []
if let entries = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Library/Developer/Xcode/DerivedData") {
    for entry in entries where entry.hasPrefix("DroidBerth-") {
        for config in ["Debug", "Release"] {
            extra.append("\(home)/Library/Developer/Xcode/DerivedData/\(entry)/Build/Products/\(config)/DroidBerth.app")
        }
    }
}
for path in candidates + extra {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else {
        print("  [不存在] \(path)")
        continue
    }
    let hasIcon = fm.fileExists(atPath: path + "/Contents/Resources/icon.icns")
    var key = "(无)"
    if let dict = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
       let value = dict["CFBundleIconFile"] { key = String(describing: value) }
    print("  [在] \(path)")
    print("       icon.icns=\(hasIcon ? "有" : "**没有**")  CFBundleIconFile=\(key)")
}
print()
print("提示：清完记录后，`lsregister -f <当前产物>` 再 `killall Dock`。")
