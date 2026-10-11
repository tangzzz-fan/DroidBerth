import AppKit
import Foundation

/// 未捕获异常处理器。
///
/// **刻意做成顶层函数**：`NSSetUncaughtExceptionHandler` 要的是一个 C 函数指针，
/// 而 C 函数指针**不能携带上下文** —— 闭包只要引用到 `CrashSentinel` 的静态成员，
/// 编译器就会判定「捕获了上下文」而拒绝（实测报
/// `a C function pointer cannot be formed from a closure that captures context`）。
/// 顶层函数是纯粹的符号引用，反而没这个问题。
///
/// 里面只做两件事：写一行日志、落一份 `last-exception.txt`。
/// **不 `exit()`** —— 那会盖掉系统自己的崩溃报告。
private func droidBerthUncaughtExceptionHandler(_ exception: NSException) {
    let name = exception.name.rawValue
    let reason = exception.reason ?? "(无原因)"
    let frames = exception.callStackSymbols.prefix(12).joined(separator: "\n    ")
    let text = """
        未捕获的 Objective-C 异常
        名字：\(name)
        原因：\(reason)
        前 12 帧：
            \(frames)
        """
    // 同步写：进程随时会被 abort()，排队的日志会连同进程一起消失。
    AppLog.writeInline("未捕获异常 \(name)：\(reason)", level: .error, category: .app)
    CrashSentinel.recordUncaughtException(text)
}

/// 崩溃取证。
///
/// ## 为什么不自己装 signal handler
///
/// 自己抓 `SIGSEGV` / `SIGABRT` 再写文件是这条路上最常见的做法，也是**最容易做坏**的一步：
/// 崩溃那一刻进程状态已经不可信（堆可能已经坏了），在里面调 Foundation 会二次崩溃，
/// 反而把系统本来能生成的完整报告弄丢。macOS 自己就有崩溃报告机制，写得比我们好 ——
/// 它落在 `~/Library/Logs/DiagnosticReports/`，是带线程栈的 `.ips`。
///
/// 所以这里的做法是**不抢系统的活**：
///
/// 1. **会话哨兵**：启动时写一个「本会话开始、还没结束」的标记，正常退出时补上结束时间。
///    下次启动发现上次没补 ⇒ 上次是异常结束（崩溃、强制退出、掉电都算）。
/// 2. **去捡系统的报告**：异常结束时，把时间窗内与 `DroidBerth` 相关的 `.ips` 找出来，
///    连同标记一起存成 `previous-session.json`，供诊断包带走。
/// 3. **只补一个系统抓不到的**：Objective-C 未捕获异常（`NSException`）系统**不会**生成 `.ips`
///    （它只是让进程 `abort()`）。这一类用 `NSSetUncaughtExceptionHandler` 记一笔
///    「名字 + 原因 + 前几帧」，写进日志与一个独立文件。
///
/// 诚实的边界：**「上次异常结束」不等于「上次崩溃了」** —— 强制退出与掉电也会让标记留着。
/// 所以 `previous-session.json` 同时记录「找到了几份 `.ips`」，让读的人自己判断，
/// 而不是替他把结论下死。
enum CrashSentinel {
    struct Session: Codable, Sendable {
        var pid: Int32
        var startedAt: Date
        var endedAt: Date?
        var version: String
        var build: String
        var bundlePath: String

        var wasClean: Bool { endedAt != nil }
    }

    /// 上次会话异常结束时落下的档。诊断包会带上它。
    struct PreviousSession: Codable, Sendable {
        var session: Session
        var detectedAt: Date
        /// 时间窗内与 DroidBerth 相关的系统崩溃报告（文件名字，不含路径）。
        var crashReportNames: [String]
        /// 上一次未捕获异常留下的记录（如果有）。
        var lastException: String?
    }

    nonisolated(unsafe) private static var current: Session?

    // MARK: - 会话

    /// 开新会话。**必须在任何会崩溃的东西之前调用**（`EntryPoint.main()` 里）。
    static func begin() {
        let previous = readSession()
        if let previous, !previous.wasClean {
            let reports = recentSystemCrashReports(within: 86_400, limit: 5)
            let record = PreviousSession(
                session: previous,
                detectedAt: Date(),
                crashReportNames: reports.map(\.lastPathComponent),
                lastException: readLastException()
            )
            write(record, to: AppPaths.supportDirectory.appendingPathComponent("previous-session.json"))
            AppLog.warning(
                "上次会话未正常结束（pid \(previous.pid)，开始于 \(previous.startedAt)）；"
                    + "窗口内找到 \(reports.count) 份系统崩溃报告"
                    + (record.lastException == nil ? "" : "，且有未捕获异常记录"),
                .app
            )
            for url in reports {
                AppLog.warning("系统崩溃报告：\(url.lastPathComponent)", .app)
            }
        }

        let info = Bundle.main.infoDictionary
        let session = Session(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date(),
            endedAt: nil,
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            bundlePath: Bundle.main.bundlePath
        )
        current = session
        write(session, to: AppPaths.sessionFile)
        AppLog.notice("会话哨兵已建立（pid \(session.pid)）", .app)
    }

    /// 正常退出。`applicationWillTerminate` 里调用 —— **强退与崩溃不会走到这里，
    /// 这正是它能当判据的原因**。
    static func markCleanExit() {
        guard var session = current ?? readSession() else { return }
        session.endedAt = Date()
        write(session, to: AppPaths.sessionFile)
        AppLog.notice("会话正常结束", .app)
    }

    static func readSession() -> Session? {
        decode(Session.self, from: AppPaths.sessionFile)
    }

    static func readPreviousSession() -> PreviousSession? {
        decode(
            PreviousSession.self,
            from: AppPaths.supportDirectory.appendingPathComponent("previous-session.json")
        )
    }

    // MARK: - 未捕获异常

    /// 装 `NSSetUncaughtExceptionHandler`。
    ///
    /// 只覆盖 Objective-C 异常（`NSArray` 越界、`NSException` 显式抛出这类）。
    /// Swift 的运行时陷阱（强制解包 `nil`、数组越界）与内存错误**不走这条路**，
    /// 它们由系统生成 `.ips` —— 两条路合起来才是完整的。
    ///
    /// 处理器里**不做任何非必要的事**：进程马上就要 `abort()`，只写一行然后返回，
    /// 让系统继续它自己的流程（我们**不** `exit()`，那会盖掉系统报告）。
    ///
    /// 注意传的是**顶层函数**而不是闭包：C 函数指针**不能携带上下文**，
    /// 而闭包一旦引用到本类型的静态成员就会被判定为「捕获了上下文」而编译不过。
    static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler(droidBerthUncaughtExceptionHandler)
    }

    /// 记录一条未捕获异常。供上面的顶层函数调用，也可单独测。
    static func recordUncaughtException(_ text: String) {
        // 用 write(to:) 而不是持有句柄：这条路径只跑一次，越简单越好。
        try? AppLog.redact(text).data(using: .utf8)?.write(to: lastExceptionFile(), options: .atomic)
    }

    private static func lastExceptionFile() -> URL {
        AppPaths.supportDirectory.appendingPathComponent("last-exception.txt")
    }

    static func readLastException() -> String? {
        try? String(contentsOf: lastExceptionFile(), encoding: .utf8)
    }

    /// 诊断包用：本次会话开始后出现过的异常记录（说明"这次也出过"）。
    static func clearLastException() {
        try? FileManager.default.removeItem(at: lastExceptionFile())
    }

    // MARK: - 系统崩溃报告

    static func systemCrashReportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// 与 DroidBerth 相关、且在时间窗内的系统崩溃报告（新的在前）。
    static func recentSystemCrashReports(within seconds: TimeInterval, limit: Int) -> [URL] {
        let fileManager = FileManager.default
        let directory = systemCrashReportDirectory()
        let items = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-seconds)
        return items
            .filter { $0.lastPathComponent.hasPrefix("DroidBerth") }
            .filter { url in
                let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (date ?? .distantPast) > cutoff
            }
            .sorted { lhs, rhs in
                let left = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - JSON 读写

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
