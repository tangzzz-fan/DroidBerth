import Foundation

struct ParsedProgress: Sendable {
    var percent: Double?
    var path: String?
    var completedBytes: Int64?
    var elapsedSeconds: Double?
    var bytesPerSecond: Double?
    var errorText: String?

    var isSummary: Bool { completedBytes != nil }
    var isError: Bool { errorText != nil }
}

enum ProgressParser {
    nonisolated(unsafe) private static let percentRegex = /^\[\s*([0-9]{1,3})%\]\s*(.+)$/
    nonisolated(unsafe) private static let summaryRegex = /([0-9]+) bytes in ([0-9.]+)s/
    nonisolated(unsafe) private static let speedRegex = /([0-9.]+)\s*(B|KB|MB|GB)\/s/

    static func parse(_ segment: String) -> ParsedProgress? {
        let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let match = text.wholeMatch(of: percentRegex) {
            return ParsedProgress(percent: Double(match.1), path: String(match.2))
        }

        if let match = text.firstMatch(of: summaryRegex) {
            let bytes = Int64(match.1)
            let seconds = Double(match.2)
            var speed: Double?
            if let speedMatch = text.firstMatch(of: speedRegex) {
                let value = Double(speedMatch.1) ?? 0
                let multiplier: Double
                switch speedMatch.2 {
                case "KB": multiplier = 1000
                case "MB": multiplier = 1_000_000
                case "GB": multiplier = 1_000_000_000
                default: multiplier = 1
                }
                speed = value * multiplier
            }
            return ParsedProgress(
                completedBytes: bytes,
                elapsedSeconds: seconds,
                bytesPerSecond: speed
            )
        }

        if text.hasPrefix("adb: ") && (text.contains("error") || text.contains("failed")) {
            return ParsedProgress(errorText: text)
        }

        if text.hasPrefix("adb: error:") {
            return ParsedProgress(errorText: text)
        }

        return nil
    }
}
