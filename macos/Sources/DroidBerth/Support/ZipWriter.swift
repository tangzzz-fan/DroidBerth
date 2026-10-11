import Compression
import Foundation

/// 最小 ZIP 写入器（deflate + store 两种方法）。
///
/// ## 为什么不用 `ditto` / `zip`
///
/// 诊断包里的文件名是**中文**（`环境.txt` / `日志/` / `崩溃报告/`），而实测：
///
/// | 工具 | 中文名的 UTF-8 标志位 | `__MACOSX/` 垃圾项 |
/// | --- | --- | --- |
/// | `/usr/bin/ditto -c -k --sequesterRsrc` | **没设**（flag `0x0008`，应为 `0x0800`） | 6–8 项 |
/// | `/usr/bin/ditto --norsrc --noextattr` | **没设** | 0 项 |
/// | `/usr/bin/zip -r -X` | **没设** | 0 项 |
///
/// 「没设标志位」意味着名字虽然按 UTF-8 写进去了，但**规范上它声称自己是 `cp437`** ——
/// 于是按规范解压的工具（含本机 `unzip -l`）拿到的是乱码 `τÄ»σóâ.txt`。
/// 这个包是要**发给别人**的，名字读不出来就等于丢了一半信息。
///
/// 自己写还有个附带好处：不再依赖外部子进程。诊断模块是「出事时才起作用」的那一层，
/// 少一个可能在关键时刻不可用的依赖，比省下这 100 行更值。
///
/// ## 实现要点
///
/// - 名字一律走 **UTF-8 + 设置 EFS 标志位（`0x0800`）**，两条都给全，规范内不再有歧义。
/// - 压缩用 `Compression` 框架的 `COMPRESSION_ZLIB` —— 它给的是**裸 DEFLATE**（RFC 1951），
///   正好是 ZIP method 8 要的格式，不需要 zlib 的 2 字节头与 4 字节校验尾。
///   压不动时回退到 method 0（store），两者在同一个包里可以混用。
/// - 目录项以 `/` 结尾、无数据、`external attrs` 带上 `0x10`（目录位）。
enum ZipWriter {
    /// 一个待打包的条目。`data` 为 nil 表示目录。
    struct Entry {
        var path: String
        var data: Data?

        static func directory(_ path: String) -> Entry { Entry(path: path, data: nil) }
        static func file(_ path: String, _ data: Data) -> Entry { Entry(path: path, data: data) }
    }

    enum Failure: Error, CustomStringConvertible {
        case deflateFailed(String)
        case tooLarge(String)

        var description: String {
            switch self {
            case .deflateFailed(let path): "压缩失败：\(path)"
            case .tooLarge(let path): "条目太大，超出 ZIP 的 4 GB 上限：\(path)"
            }
        }
    }

    /// 把条目打成一个 zip。目录请放在其内容之前（不是必须，但解压器更友好）。
    static func archive(_ entries: [Entry], modified: Date = Date()) throws -> Data {
        var body = Data()
        var directory = Data()
        let (dosTime, dosDate) = dosStamp(modified)

        for entry in entries {
            // 目录名统一补尾斜杠 —— ZIP 靠这个字符区分「目录」与「空文件」。
            let isDirectory = entry.data == nil
            let name = isDirectory && !entry.path.hasSuffix("/") ? entry.path + "/" : entry.path
            let nameBytes = Data(name.utf8)
            let raw = entry.data ?? Data()

            let (method, payload): (UInt16, Data)
            if isDirectory || raw.isEmpty {
                (method, payload) = (0, Data())
            } else if let deflated = deflate(raw), deflated.count < raw.count {
                (method, payload) = (8, deflated)
            } else {
                (method, payload) = (0, raw)
            }

            let crc = crc32(raw)
            let offset = UInt32(body.count)

            guard payload.count <= Int(UInt32.max), raw.count <= Int(UInt32.max) else {
                throw Failure.tooLarge(entry.path)
            }

            // ── 局部文件头 ──
            body.appendLE(UInt32(0x0403_4B50))
            body.appendLE(UInt16(20))                       // 解压所需版本 2.0
            body.appendLE(UInt16(0x0800))                   // EFS：名字是 UTF-8
            body.appendLE(method)
            body.appendLE(dosTime)
            body.appendLE(dosDate)
            body.appendLE(crc)
            body.appendLE(UInt32(payload.count))
            body.appendLE(UInt32(raw.count))
            body.appendLE(UInt16(nameBytes.count))
            body.appendLE(UInt16(0))                        // 无 extra 字段
            body.append(nameBytes)
            body.append(payload)

            // ── 中央目录项 ──
            directory.appendLE(UInt32(0x0201_4B50))
            directory.appendLE(UInt16(0x031E))              // 生成方：UNIX，版本 3.0
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(0x0800))
            directory.appendLE(method)
            directory.appendLE(dosTime)
            directory.appendLE(dosDate)
            directory.appendLE(crc)
            directory.appendLE(UInt32(payload.count))
            directory.appendLE(UInt32(raw.count))
            directory.appendLE(UInt16(nameBytes.count))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))                   // 无注释
            directory.appendLE(UInt16(0))                   // 起始磁盘号
            directory.appendLE(UInt16(0))                   // 内部属性
            // 外部属性：高 16 位是 Unix 权限。目录要带 0x10（MS-DOS 目录位）。
            let unixMode: UInt32 = isDirectory ? 0o040755 : 0o100644
            directory.appendLE(isDirectory ? (unixMode << 16) | 0x10 : unixMode << 16)
            directory.appendLE(offset)
            directory.append(nameBytes)
        }

        guard directory.count <= Int(UInt32.max), body.count <= Int(UInt32.max) else {
            throw Failure.tooLarge("中央目录")
        }

        var out = body
        let directoryOffset = UInt32(body.count)
        out.append(directory)

        // ── 中央目录结束记录 ──
        out.appendLE(UInt32(0x0605_4B50))
        out.appendLE(UInt16(0))                             // 本磁盘号
        out.appendLE(UInt16(0))                             // 中央目录起始磁盘号
        out.appendLE(UInt16(min(entries.count, Int(UInt16.max))))
        out.appendLE(UInt16(min(entries.count, Int(UInt16.max))))
        out.appendLE(UInt32(directory.count))
        out.appendLE(directoryOffset)
        out.appendLE(UInt16(0))                             // 无注释
        return out
    }

    // MARK: - 压缩

    /// 裸 DEFLATE（RFC 1951）。`COMPRESSION_ZLIB` 在 Apple 的实现里就**是**裸流 ——
    /// 不带 zlib 头与尾，正是 ZIP method 8 需要的。
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        // 最坏情况（不可压）下 deflate 会略微膨胀，给足余量。
        let capacity = data.count + max(64, data.count / 16) + 64
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBase, capacity,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - 时间戳

    /// MS-DOS 的打包时间格式（ZIP 只支持到 1980–2107、精确到 2 秒）。
    private static func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, parts.year ?? 1980))
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | ((parts.second ?? 0) / 2))
        let day = UInt16((year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    /// ZIP 内部一律**小端**。
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
