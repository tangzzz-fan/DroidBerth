import Foundation

enum SpikeReport {
    /// 报告正文。抽出来是为了让**诊断包**能把它作为一份文件带走 ——
    /// `emit()` 是「打印后退出」，诊断包要的是「拿到文本但不退出」。
    static func text() -> String {
        let rows = SpikeChecks.runAll()
        var out: [String] = []

        out.append("DroidBerth swift-native spike report")
        out.append("time:       \(ISO8601DateFormatter().string(from: Date()))")
        out.append("executable: \(Bundle.main.executableURL?.path ?? "?")")
        out.append("bundle:     \(Bundle.main.bundlePath)")
        out.append("")

        for row in rows {
            out.append("== \(row.id) [\(row.status.rawValue.uppercased())] \(row.title)")
            for line in row.evidence.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append("   \(line)")
            }
            out.append("")
        }

        let summary = rows.map { "\($0.id)=\($0.status.rawValue)" }.joined(separator: " ")
        out.append("SUMMARY: \(summary)")
        return out.joined(separator: "\n")
    }

    static func emit() -> Never {
        print(text())
        exit(0)
    }
}
