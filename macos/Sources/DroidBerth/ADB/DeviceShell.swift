import Foundation

struct ShellResult: Sendable {
    let code: Int32?
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let spawnError: String?

    var ok: Bool { spawnError == nil && !timedOut && code == 0 }

    var combined: String {
        let parts = [stdout, stderr].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var failureMessage: String {
        if let spawnError { return spawnError }
        if timedOut { return "命令超时" }
        let text = combined
        if text.isEmpty { return "退出码 \(code.map(String.init) ?? "nil")" }
        return text
    }
}

struct DeviceShell: Sendable {
    enum ListingResult: Sendable {
        case success([RemoteEntry])
        case failure(String)
    }

    let adb: URL
    let serial: String

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func doubleQuote(_ value: String) -> String {
        var escaped = value
        for character in ["\\", "\"", "$", "`"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
        }
        return "\"" + escaped + "\""
    }

    func raw(_ arguments: [String], timeout: TimeInterval = 30) -> ShellResult {
        let result = ProcessRunner.run(adb, ["-s", serial] + arguments, timeout: timeout)
        return ShellResult(
            code: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            timedOut: result.timedOut,
            spawnError: result.spawnError
        )
    }

    func shell(_ command: String, timeout: TimeInterval = 30) -> ShellResult {
        raw(["shell", command], timeout: timeout)
    }

    func list(_ path: String, timeout: TimeInterval = 30) -> ListingResult {
        let result = shell("ls -la \(Self.quote(path))", timeout: timeout)
        guard result.ok else { return .failure(result.failureMessage) }
        let entries = RemoteListing.parse(result.stdout, directory: path)
        return .success(entries)
    }

    func exists(_ path: String) -> Bool {
        shell("ls -d \(Self.quote(path)) 2>/dev/null").ok
    }

    func makeDirectory(_ path: String) -> ShellResult {
        shell("mkdir -p \(Self.quote(path))")
    }

    func remove(_ paths: [String]) -> ShellResult {
        guard !paths.isEmpty else {
            return ShellResult(code: 0, stdout: "", stderr: "", timedOut: false, spawnError: nil)
        }
        let joined = paths.map(Self.quote).joined(separator: " ")
        return shell("rm -rf \(joined)", timeout: 60)
    }

    func availableBytes(at path: String) -> Int64? {
        let result = shell("df -k \(Self.quote(path))")
        guard result.ok else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 4, fields[0] != "Filesystem" else { continue }
            if let blocks = Int64(fields[3]) { return blocks * 1024 }
        }
        return nil
    }

    func property(_ name: String) -> String? {
        let result = shell("getprop \(name)")
        guard result.ok else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func androidVersion() -> (sdk: Int?, release: String?) {
        let sdkText = property("ro.build.version.sdk")
        return (sdkText.flatMap(Int.init), property("ro.build.version.release"))
    }

    func wifiAddress() -> String? {
        let ipResult = shell("ip -4 addr show wlan0 2>/dev/null")
        if ipResult.ok {
            for line in ipResult.stdout.split(separator: "\n") {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                if let index = fields.firstIndex(of: "inet"), fields.count > index + 1 {
                    let candidate = fields[index + 1].split(separator: "/").first.map(String.init) ?? ""
                    if !candidate.isEmpty, candidate != "127.0.0.1" { return candidate }
                }
            }
        }

        if let fallback = property("dhcp.wlan0.ipaddress"), !fallback.isEmpty, fallback != "0.0.0.0" {
            return fallback
        }

        let ifconfigResult = shell("ifconfig wlan0 2>/dev/null")
        if ifconfigResult.ok, let match = ifconfigResult.stdout.firstMatch(of: /inet (?:addr:)?(\d+\.\d+\.\d+\.\d+)/) {
            return String(match.1)
        }

        return nil
    }

    func remoteTargetDirectoryDefaults() -> [String] {
        ["/sdcard/DCIM", "/sdcard/Movies", "/sdcard/Pictures", "/sdcard/Download"]
    }
}
