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

    /// 只拉取远端文件的**前若干字节**，用于网格缩略图（PRD §13.3「缩略图只拉文件头」）。
    ///
    /// 两个刻意的选择：
    /// - 用 `exec-out` 而**不是** `shell`。`adb shell` 的 stdout 走 pty，二进制的
    ///   `\n` 会被翻译成 `\r\n`，图片 / 视频头当场损坏。`exec-out` 出的是原始字节流。
    /// - 设备侧用 `dd` 而**不是** `head -c`：部分旧版 toybox 的 `head` 不支持 `-c`。
    ///
    /// 失败（无 dd、路径不可读、超时）统一返回 nil，由调用方回退类型图标 ——
    /// 缩略图拿不到不是错误，不该往界面上抛。
    func fetchHeader(_ path: String, maxBytes: Int, timeout: TimeInterval = 20) -> Data? {
        guard maxBytes > 0 else { return nil }
        let kilobytes = max(1, (maxBytes + 1023) / 1024)
        let command = "dd if=\(Self.quote(path)) bs=1024 count=\(kilobytes) 2>/dev/null"
        let result = ProcessRunner.runBinary(
            adb,
            ["-s", serial, "exec-out", command],
            timeout: timeout
        )
        guard result.ok, !result.stdout.isEmpty else { return nil }
        return result.stdout.count > maxBytes ? Data(result.stdout.prefix(maxBytes)) : result.stdout
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

    /// 设备端重命名（PRD §13.1 右键菜单）。`mv` 换个名字就是重命名。
    ///
    /// 刻意**不加 `-f` / `-n`**：覆盖与否由调用方先做冲突预检再决定，而不是把一个
    /// 静默覆盖或静默跳过的开关藏在命令里 —— 两种静默都比报错更糟。
    func move(_ source: String, to destination: String) -> ShellResult {
        shell("mv \(Self.quote(source)) \(Self.quote(destination))")
    }

    /// 把多个条目移进一个目录（PRD §24：设备窗格内拖拽 = 设备端移动）。
    func move(_ sources: [String], intoDirectory directory: String) -> ShellResult {
        guard !sources.isEmpty else {
            return ShellResult(code: 0, stdout: "", stderr: "", timedOut: false, spawnError: nil)
        }
        let joined = sources.map(Self.quote).joined(separator: " ")
        return shell("mv \(joined) \(Self.quote(directory))", timeout: 60)
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
