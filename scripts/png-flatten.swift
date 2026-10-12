import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 把一张 PNG 重绘成**不带 alpha 通道**的 sRGB PNG。
//
// 为什么需要它：App Store Connect **不接受带 alpha 的截图**，而 `screencapture`
// 产出的 PNG 带 alpha 通道 —— 2026-10-12 实测 `sips -g hasAlpha` 报 `yes`。
// 这个通道里其实没有透明像素（窗口是实心的），但只要**通道在**，ASC 就会拒。
//
// 做法是「重画一遍」而不是「删通道」：CoreGraphics 用 `noneSkipLast` 建位图、
// 先铺一层不透明底色再把原图 draw 上去。这样即使原图真有半透明像素，
// 结果也是**在不透明底上合成过的**，不会变成黑边。
//
// 用法：
//     png-flatten <in.png> <out.png>          # 去 alpha（尺寸不变）
//     png-flatten <in.png> <out.png> <W> <H>  # 另外校验尺寸（不符返回 3）
//
// 尺寸**不缩放** —— ASC 校验的是**精确像素数**，拉伸出来的图既会被拒、也是假的。
// 要标准尺寸就得让窗口本身就是那个尺寸（见 scripts/appstore-shots.sh）。

let args = CommandLine.arguments
guard args.count == 3 || args.count == 5 else {
    FileHandle.standardError.write(Data("用法: png-flatten <in.png> <out.png> [<W> <H>]\n".utf8))
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let source = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("读不到或解不开：\(inURL.path)\n".utf8))
    exit(1)
}

let width = image.width
let height = image.height

if args.count == 5 {
    let wantW = Int(args[3]) ?? -1
    let wantH = Int(args[4]) ?? -1
    if width != wantW || height != wantH {
        FileHandle.standardError.write(Data(
            "尺寸不符：实际 \(width)×\(height)，App Store 要 \(wantW)×\(wantH)\n".utf8))
        exit(3)
    }
}

// ⚠️ 色彩空间强制 **sRGB**：ASC 要求 sRGB，Display P3 / Adobe RGB / CMYK 都会有色偏。
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write(Data("建不了 bitmap context\n".utf8))
    exit(1)
}

// 先铺不透明白底：万一原图真有半透明像素，合成结果才是可预期的，而不是黑边。
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

guard let flattened = context.makeImage() else {
    FileHandle.standardError.write(Data("重绘失败\n".utf8))
    exit(1)
}

guard let destination = CGImageDestinationCreateWithURL(
    outURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else {
    FileHandle.standardError.write(Data("建不了 \(outURL.path)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, flattened, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("写入失败\n".utf8))
    exit(1)
}

print("  \(width)×\(height) · sRGB · 无 alpha ⇒ \(outURL.lastPathComponent)")
