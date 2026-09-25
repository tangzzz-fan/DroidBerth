import Foundation

enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    static func size(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        if bytes < 1000 { return "\(bytes) B" }
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let decimals = value < 10 ? 1 : 0
        return String(format: "%.\(decimals)f %@", value, units[index])
    }

    static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "—" }
        return size(Int64(bytesPerSecond)) + "/s"
    }

    static func remaining(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "<1 秒" }
        if seconds < 60 { return "\(Int(seconds.rounded())) 秒" }
        if seconds < 3600 {
            let minutes = Int(seconds) / 60
            let rest = Int(seconds) % 60
            return rest == 0 ? "\(minutes) 分" : "\(minutes) 分 \(rest) 秒"
        }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return "\(hours) 小时 \(minutes) 分"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        let age = Date().timeIntervalSince(value)
        if age >= 0, age < 60 * 60 * 24 * 6 {
            return relativeFormatter.localizedString(for: value, relativeTo: Date())
        }
        return dateFormatter.string(from: value)
    }
}

extension String {
    var pathExtensionLowercased: String { (self as NSString).pathExtension.lowercased() }

    var isVideoFile: Bool {
        ["mp4", "mov", "mkv", "avi", "webm", "m4v", "3gp", "ts", "flv", "wmv"].contains(pathExtensionLowercased)
    }

    var isImageFile: Bool {
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tif", "tiff", "dng", "raw", "arw", "cr2", "nef"].contains(pathExtensionLowercased)
    }

    var isAudioFile: Bool {
        ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma"].contains(pathExtensionLowercased)
    }
}
