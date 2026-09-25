import Foundation

struct SidecarResolution: Decodable, Sendable {
    struct Probe: Decodable, Sendable {
        let path: String
        let source: String
        let exists: Bool
    }

    let found: Bool
    let path: String?
    let source: String
    let probes: [Probe]
}

struct SidecarExecResult: Decodable, Sendable {
    let ok: Bool
    let code: Int?
    let stdout: String?
    let stderr: String?
    let timedOut: Bool?
    let durationMs: Int?
    let adbPath: String?
    let source: String?
    let error: String?
    let resolution: SidecarResolution?
}

struct SidecarDoctorReport: Decodable, Sendable {
    struct Summary: Decodable, Sendable {
        let verdict: String
        let pass: Int
        let fail: Int
        let manual: Int
        let skip: Int
        let total: Int
    }

    struct Check: Decodable, Sendable {
        let id: Int
        let key: String
        let module: String
        let name: String
        let level: String
        let status: String
        let detail: String
        let evidence: String
    }

    let tool: String
    let summary: Summary
    let checks: [Check]
}
