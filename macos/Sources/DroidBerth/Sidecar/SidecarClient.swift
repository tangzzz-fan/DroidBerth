import Foundation

struct SidecarClient: Sendable {
    let executable: URL

    func version(timeout: TimeInterval = 15) -> ProcessResult {
        ProcessRunner.run(executable, ["version"], timeout: timeout)
    }

    func resolve(timeout: TimeInterval = 20) -> SidecarResolution? {
        let result = ProcessRunner.run(executable, ["resolve"], timeout: timeout)
        return Self.decode(SidecarResolution.self, from: result.stdout)
    }

    func doctor(timeout: TimeInterval = 90) -> SidecarDoctorReport? {
        let result = ProcessRunner.run(executable, ["doctor", "--compact"], timeout: timeout)
        return Self.decode(SidecarDoctorReport.self, from: result.stdout)
    }

    func exec(_ arguments: [String], timeout: TimeInterval = 30) -> SidecarExecResult? {
        var args = ["exec", "--timeout", String(Int(timeout))]
        args.append(contentsOf: arguments)
        let result = ProcessRunner.run(executable, args, timeout: timeout + 10)
        return Self.decode(SidecarExecResult.self, from: result.stdout)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
