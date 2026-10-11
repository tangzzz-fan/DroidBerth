import Foundation
import os

/// 应用自己的日志。
///
/// 这个项目此前**没有任何日志设施** —— 全仓 `print(` 只有一处，在 `--spike-report` 里，
/// 出问题时能拿到的只有用户的口头描述。这一层补的就是那个缺口：把「刚才发生了什么」
/// 写成**用户可以交回来的一份可读现场**。
///
/// 三条设计约束：
///
/// 1. **双写**：同时进统一日志（`os.Logger`）与磁盘文件。
///    前者给开发者在自己机器上排查（`log show --predicate 'subsystem == "dev.tango.droidberth"'`）；
///    后者给「用户报告问题时把文件发回来」这条路 —— 统一日志在别人的机器上拿不到，
///    而且系统会自行滚动删除。
/// 2. **写进去之前就脱敏**（`redact(_:)`）。日志一旦落到磁盘，就可能在用户没意识到的情况下
///    被转发出去。在**写入那一刻**过滤掉用户名与设备序列号，比事后承诺「我们不会看」可靠得多。
/// 3. **绝不因为日志本身失败而影响功能**。所有磁盘操作 `try?` 吞掉；磁盘满、权限被拒
///    都只是丢日志，不该让用户看到任何错误。
///
/// 刻意**不**引入任何第三方日志框架：这里要的东西（分级、分文件、脱敏、轮转）用
/// Foundation 就够了，而依赖越少，这个「出事时才起作用」的模块越不容易先坏掉。
enum AppLog {
    enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case notice = "NOTE"
        case warning = "WARN"
        case error = "ERROR"

        /// 映射到统一日志的级别。`warning`/`error` 抬到 `error`/`fault` 才会进持久化区，
        /// 否则 `log show --last 1h` 里根本看不到它们。
        var osLogType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .notice: .default
            case .warning: .error
            case .error: .fault
            }
        }
    }

    /// 分类只用于过滤。**刻意保持粗粒度** —— 细到「一个源文件一个分类」时，
    /// 查日志的人反而不知道该看哪个。
    enum Category: String, Sendable, CaseIterable {
        case app
        case adb
        case sidecar
        case transfer
        case device
        case ui
        case files
    }

    static let subsystem = "dev.tango.droidberth"
    /// 保留天数。诊断包只带最近的，磁盘上也不该无限增长。
    private static let retentionDays = 7
    /// 单个日志文件的上限。超过就滚到 `.1`（只保留一代）。
    private static let maxBytes = 4 * 1024 * 1024

    private static let queue = DispatchQueue(label: "\(subsystem).log", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var handleURL: URL?
    nonisolated(unsafe) private static var osLoggers: [String: Logger] = [:]
    nonisolated(unsafe) private static var enabled = false

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - 生命周期

    /// 开一个日志会话：建目录、清老文件、打开今天的文件、写会话头。
    ///
    /// 幂等 —— 启动路径上会调用一次，测试与命令行入口再调用也不会重复写头。
    static func start() {
        queue.sync {
            guard !enabled else { return }
            enabled = true
            pruneOldFiles()
            openTodayFile()
            write(sessionHeader(), level: .notice, category: .app, mirrorToConsole: false)
        }
    }

    static var logFileURL: URL {
        AppPaths.logsDirectory.appendingPathComponent("DroidBerth-\(dayFormatter.string(from: Date())).log")
    }

    /// 供诊断与命令行入口读取：把最近 `limit` 行拼起来（跨文件，新的在后）。
    static func tail(limit: Int = 400) -> String {
        let files = logFiles().suffix(2)
        var lines: [String] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
        return lines.suffix(limit).joined(separator: "\n")
    }

    /// 脱敏后的全部日志文件（诊断包用）。
    static func logFiles() -> [URL] {
        let fileManager = FileManager.default
        let items = (try? fileManager.contentsOfDirectory(
            at: AppPaths.logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return items
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - 写

    static func debug(_ message: String, _ category: Category) { log(.debug, category, message) }
    static func info(_ message: String, _ category: Category) { log(.info, category, message) }
    static func notice(_ message: String, _ category: Category) { log(.notice, category, message) }
    static func warning(_ message: String, _ category: Category) { log(.warning, category, message) }
    static func error(_ message: String, _ category: Category) { log(.error, category, message) }

    static func log(_ level: Level, _ category: Category, _ message: String) {
        let line = "\(stampFormatter.string(from: Date())) [\(level.rawValue)] [\(category.rawValue)] \(message)"
        // 统一日志不受 `enabled` 影响：即使文件写不了（只读磁盘 / 权限问题），
        // `log show` 这条排查路径也该还在。
        osLogger(for: category).log(level: level.osLogType, "\(redact(line), privacy: .public)")

        queue.async {
            guard enabled else { return }
            write(line, level: level, category: category, mirrorToConsole: false)
        }
    }

    /// **同步**写一行，绕过队列。
    ///
    /// 只给「马上就要死了」的路径用（未捕获异常处理器）。那里不能依赖异步队列 ——
    /// 进程随时会被 `abort()`，排队的日志会连同进程一起消失。
    static func writeInline(_ message: String, level: Level = .error, category: Category = .app) {
        let line = "\(stampFormatter.string(from: Date())) [\(level.rawValue)] [\(category.rawValue)] \(message)"
        osLogger(for: category).log(level: level.osLogType, "\(redact(line), privacy: .public)")
        guard !enabled || handle != nil else { return }
        write(line, level: level, category: category, mirrorToConsole: false)
    }

    /// 必须在串行队列上调用（`start()` 里那段 `queue.sync` 也在）。
    private static func write(_ line: String, level: Level, category: Category, mirrorToConsole: Bool) {
        _ = level
        _ = category
        _ = mirrorToConsole
        guard let data = (redact(line) + "\n").data(using: .utf8) else { return }
        if handle == nil { openTodayFile() }
        guard let handle else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        if handle.offsetInFile > UInt64(maxBytes) {
            roll()
        } else {
            try? handle.synchronize()
        }
    }

    private static func roll() {
        try? handle?.close()
        handle = nil
        let current = logFileURL
        let previous = current.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: current, to: previous)
        openTodayFile()
    }

    private static func openTodayFile() {
        let url = logFileURL
        if handleURL == url, handle != nil { return }
        try? handle?.close()
        handle = nil
        handleURL = url
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
    }

    private static func sessionHeader() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let process = ProcessInfo.processInfo
        return """
            ──── 会话开始 ────
            版本 \(version) (\(build)) · macOS \(process.operatingSystemVersionString) · pid \(process.processIdentifier)
            可执行文件 \(Bundle.main.bundlePath)
            """
    }

    private static func pruneOldFiles() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let items = (try? fileManager.contentsOfDirectory(
            at: AppPaths.logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for item in items {
            guard let date = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date < cutoff
            else { continue }
            try? fileManager.removeItem(at: item)
        }
    }

    private static func osLogger(for category: Category) -> Logger {
        if let cached = osLoggers[category.rawValue] { return cached }
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        osLoggers[category.rawValue] = logger
        return logger
    }

    // MARK: - 脱敏

    /// 写入磁盘**之前**调用。
    ///
    /// 现在做四件事（都是保守的、只会删信息不会加信息）：
    /// - 家目录路径 → `~`（`/Users/tango/...` → `~/...`）
    /// - **JSON 里的转义形式** → 同样折叠（`JSONEncoder` 会把 `/` 写成 `\/`，
    ///   于是 `"bundlePath": "\/Users\/tango\/..."` 在纯文本替换下**匹配不上** ——
    ///   这是实测漏掉过用户名的一条路径，见 `DiagnosticsExporter.writeSessionFiles`）
    /// - RSA 指纹之类的十六进制冒号串 → 只留前两组
    /// - 形如设备序列号的 `-s <token>` 参数 → 只留前 3 位
    ///
    /// 设备序列号是**真敏感项**（能用来定位具体一台手机），所以对 `-s` 的处理是
    /// 参数级的：`adb -s emulator-5554 shell ...` 记成 `adb -s emu… shell ...`。
    ///
    /// **刻意不做的**：把用户名当成裸词全局替换。bundle 标识符就是
    /// `dev.<用户名>.droidberth`（本项目实测如此），全局替换会把产品标识符一并毁掉，
    /// 而那是排障时有用的事实。用户名只在**路径**里才是隐私 —— 非路径的那一种
    /// （`lsof` 的属主列）由调用方自己避免输出，见 `DiagnosticsExporter.port5197Owner`。
    static func redact(_ text: String) -> String {
        var out = text
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, home != "/" {
            out = out.replacingOccurrences(of: home, with: "~")
            // JSON 转义形式：/Users/x → \/Users\/x
            let escaped = home.replacingOccurrences(of: "/", with: "\\/")
            out = out.replacingOccurrences(of: escaped, with: "~")
            // `/Users/<名字>` 的其余写法（例如别的机器上的路径）
            if let name = home.split(separator: "/").last, name.count > 1 {
                out = out.replacingOccurrences(of: "/Users/\(name)", with: "~")
                out = out.replacingOccurrences(of: "\\/Users\\/\(name)", with: "~")
            }
        }
        out = redactSerials(in: out)
        out = redactFingerprints(in: out)
        return out
    }

    /// 单独的入口：调用方明确知道某个字符串是序列号时用它，比让正则去猜可靠。
    static func redactedSerial(_ serial: String) -> String {
        guard serial.count > 6 else { return serial }
        return String(serial.prefix(3)) + "…"
    }

    /// `adb devices -l` 的输出：**每行第一个 token 就是序列号**，掩掉它。
    ///
    /// 刻意做成独立入口而不是塞进 `redact(_:)`：那条路会跑在**每一行**日志上，
    /// 而「把每行第一个长 token 当序列号掩掉」对普通日志行是错的（会误伤路径）。
    /// 只在明确是设备列表的地方用它。
    static func redactDeviceListing(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("List of devices") else { return String(line) }
            var parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard let first = parts.first, first.count > 6 else { return String(line) }
            parts[0] = redactedSerial(first)
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func redactSerials(in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.contains("-s ") else { return String(line) }
            var tokens = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var index = 0
            while index < tokens.count - 1 {
                if tokens[index] == "-s", tokens[index + 1].count > 6 {
                    tokens[index + 1] = redactedSerial(tokens[index + 1])
                }
                index += 1
            }
            return tokens.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// `A4:7B:9F:2C:11:E8:5D:03` 这类指纹只留前两组 —— 既能对上是哪台机器，又不至于泄露完整密钥指纹。
    private static func redactFingerprints(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?:[0-9A-Fa-f]{2}:){4,}[0-9A-Fa-f]{2}") else {
            return text
        }
        var out = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let value = String(out[range])
            let groups = value.split(separator: ":")
            let kept = groups.prefix(2).joined(separator: ":")
            out.replaceSubrange(range, with: "\(kept):…")
        }
        return out
    }
}
