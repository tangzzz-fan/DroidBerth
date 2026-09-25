import Foundation

enum SpikeReport {
    static func emit() -> Never {
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

        print(out.joined(separator: "\n"))
        exit(0)
    }
}
