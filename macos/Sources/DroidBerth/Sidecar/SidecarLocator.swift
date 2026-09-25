import Foundation

struct SidecarProbe: Sendable {
    let path: String
    let exists: Bool
}

struct SidecarLocation: Sendable {
    let executable: URL?
    let probes: [SidecarProbe]
}

enum SidecarLocator {
    static func locate() -> SidecarLocation {
        var probes: [SidecarProbe] = []

        guard let exe = Bundle.main.executableURL else {
            return SidecarLocation(executable: nil, probes: probes)
        }

        let base = exe.resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            base.appendingPathComponent("droidberth-adb"),
            base.appendingPathComponent("droidberth-adb-aarch64-apple-darwin"),
            base.deletingLastPathComponent()
                .appendingPathComponent("Resources")
                .appendingPathComponent("droidberth-adb"),
        ]

        for candidate in candidates {
            let url = candidate.standardizedFileURL
            let exists = FileManager.default.isExecutableFile(atPath: url.path)
            probes.append(SidecarProbe(path: url.path, exists: exists))
            if exists {
                return SidecarLocation(executable: url, probes: probes)
            }
        }

        return SidecarLocation(executable: nil, probes: probes)
    }

    static func describe(_ location: SidecarLocation) -> String {
        location.probes
            .map { "\($0.exists ? "+" : "-") \($0.path)" }
            .joined(separator: "\n")
    }
}
