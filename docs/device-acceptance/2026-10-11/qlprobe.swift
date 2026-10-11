// 复刻 ThumbnailStore.generateCGImage 的判定路径。
//
// 参数与 macos/Sources/DroidBerth/Support/ThumbnailStore.swift 完全一致：
//   QLThumbnailGenerator.Request(fileAt:size:scale:representationTypes: .thumbnail)
//   size = 512×512（ThumbnailConstants.maxPixelSize），scale = 1
//
// 用法：qlprobe <file>        成功打印 OK + 尺寸，失败打印 FAIL + 原因
//       退出码 0 = 能出缩略图，1 = 出不了（app 会回退类型图标）
import AppKit
import Foundation
import QuickLookThumbnailing

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)

let request = QLThumbnailGenerator.Request(
    fileAt: url,
    size: CGSize(width: 512, height: 512),
    scale: 1,
    representationTypes: .thumbnail
)

do {
    let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
    print("OK \(rep.cgImage.width)x\(rep.cgImage.height)")
    exit(0)
} catch {
    let reason = (error as NSError)
    print("FAIL [\(reason.domain) \(reason.code)] \(reason.localizedDescription)")
    exit(1)
}
