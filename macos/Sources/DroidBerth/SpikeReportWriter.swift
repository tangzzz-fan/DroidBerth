import Foundation

enum SpikeReportWriter {
    private struct Report: Encodable {
        let generatedAt: String
        let rows: [Row]
    }

    private struct Row: Encodable {
        let id: String
        let title: String
        let status: String
        let evidence: String
    }

    static func write(_ rows: [SpikeRow]) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DroidBerth-reports")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let report = Report(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            rows: rows.map {
                Row(id: $0.id, title: $0.title, status: $0.status.rawValue, evidence: $0.evidence)
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return }

        try? data.write(to: directory.appendingPathComponent("spike-\(stamp).json"))
    }
}
