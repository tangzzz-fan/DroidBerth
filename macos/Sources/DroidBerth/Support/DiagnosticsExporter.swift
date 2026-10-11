import Foundation

/// 把「现场」收集成**一个 zip**，让用户能一键交回来。
///
/// 这一层存在的理由：用户报「传不动 / 打不开 / 闪退」时，开发者手上什么都没有。
/// 让人去 `~/Library/Logs` 里翻文件、再跑几条命令、再打包，是**不会发生**的 ——
/// 现实里只会得到一句「不行」。所以把这一整套动作压成一次点击（或一条命令）。
///
/// 装进去的东西，按「排障时先看哪份」的顺序：
///
/// | 文件 | 为什么在 |
/// | --- | --- |
/// | `环境.txt` | 版本 / 系统 / 架构 / 是否在 `/Applications` —— 一半的问题看到这几行就定性了 |
/// | `上次会话.json` | 上次是不是异常结束、以及窗口内找到了几份系统崩溃报告 |
/// | `崩溃报告/` | 系统的 `.ips`（已脱敏），带线程栈 |
/// | `日志/` | 应用自己的日志（已脱敏） |
/// | `自检报告.txt` | `--spike-report` 的 V1–V4，判据是「应然」而不是「日志里有什么」 |
/// | `sidecar-doctor.json` | sidecar 的定位与诊断结果 |
/// | `adb.txt` | adb 版本、5037 端口归谁 —— 「adb 挂了」这类问题的现场 |
/// | `设备列表.txt` | 连了几台、什么状态（序列号已掩） |
///
/// **隐私**：所有文本都过 `AppLog.redact`（家目录 → `~`、设备序列号 → 前三位、密钥指纹 → 前两组）。
/// `.ips` 也是 JSON 文本，同样过一遍。**没有**任何自动上传 —— 这个 zip 只会留在用户的机器上，
/// 要不要发、发给谁由用户决定。
enum DiagnosticsExporter {
    struct Outcome: Sendable {
        var directory: URL
        var zipURL: URL
        var items: [String]
        var warnings: [String]
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - 入口

    /// 收集并打包。**同步**，可能耗时数秒到十几秒（要跑自检与 sidecar doctor）。
    ///
    /// `parent` 为 nil 时用 `defaultParent()`。产物落在 `parent/DroidBerth-diagnostics-<时间>/`
    /// 与同名的 `.zip`。
    static func collect(into parent: URL? = nil) -> Outcome {
        let started = Date()
        let stamp = stampFormatter.string(from: Date())
        let target = (parent ?? defaultParent())
        let work = target.appendingPathComponent("DroidBerth-diagnostics-\(stamp)", isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        var items: [String] = []
        var warnings: [String] = []

        // ① 环境
        write("环境.txt", environmentText(), into: work, items: &items)

        // ② 会话与崩溃
        writeSessionFiles(into: work, items: &items)
        writeCrashReports(into: work, items: &items, warnings: &warnings)

        // ③ 日志
        let logs = work.appendingPathComponent("日志", isDirectory: true)
        try? fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        var logCount = 0
        for url in AppLog.logFiles() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let redacted = AppLog.redact(text)
            if (try? redacted.write(to: logs.appendingPathComponent(url.lastPathComponent),
                                   atomically: true, encoding: .utf8)) != nil {
                logCount += 1
            }
        }
        if logCount > 0 { items.append("日志/（\(logCount) 个文件）") }

        // ④ 自检报告（会跑 adb / 取决于是否有设备，故放在日志之后）
        if let report = timed("自检报告", warnings: &warnings, {
            SpikeReport.text()
        }) {
            write("自检报告.txt", report, into: work, items: &items)
        }

        // ⑤ sidecar doctor（原始 JSON）
        if let doctor = timed("sidecar doctor", warnings: &warnings, { doctorJSON() }) {
            write("sidecar-doctor.json", doctor, into: work, items: &items)
        }

        // ⑥ adb 现场
        write("adb.txt", adbText(), into: work, items: &items)

        // ⑦ 设备列表
        write("设备列表.txt", deviceListText(), into: work, items: &items)

        // ⑧ 说明
        write("说明.txt", readmeText(items: items), into: work, items: &items)

        // ⑨ 打包（自研 ZIP 写入器，不用 ditto —— 理由见 `ZipWriter`：中文名的 UTF-8 标志）
        let zipURL = target.appendingPathComponent("DroidBerth-diagnostics-\(stamp).zip")
        try? fileManager.removeItem(at: zipURL)
        do {
            try ZipWriter.archive(zipEntries(root: work)).write(to: zipURL, options: .atomic)
        } catch {
            warnings.append("打包失败：\(error)")
        }

        let outcome = Outcome(directory: work, zipURL: zipURL, items: items, warnings: warnings)
        AppLog.notice(
            "诊断包已导出：\(zipURL.lastPathComponent)，含 \(items.count) 项，"
                + "耗时 \(Int(Date().timeIntervalSince(started) * 1000)) ms"
                + (warnings.isEmpty ? "" : "，\(warnings.count) 条警告"),
            .app
        )
        for warning in warnings {
            AppLog.warning("诊断包里的一步失败：\(warning)", .app)
        }
        return outcome
    }

    private static func timed(_ name: String, warnings: inout [String], _ body: () -> String?) -> String? {
        let started = Date()
        let value = body()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if value == nil {
            warnings.append("\(name) 没跑出结果（耗时 \(ms) ms）")
        }
        AppLog.debug("诊断收集 · \(name) 耗时 \(ms) ms", .app)
        return value
    }

    /// zip 落点：桌面 → 下载 → 诊断目录。优先桌面，因为下一步是「把它发给我」，
    /// 用户在桌面上最容易看到它。
    static func defaultParent() -> URL {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        for name in ["Desktop", "Downloads"] {
            let candidate = home.appendingPathComponent(name, isDirectory: true)
            if fileManager.isWritableFile(atPath: candidate.path) { return candidate }
        }
        return AppPaths.diagnosticsDirectory
    }

    // MARK: - 各份内容

    private static func environmentText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let process = ProcessInfo.processInfo
        let bundlePath = Bundle.main.bundlePath
        let inApplications = bundlePath.hasPrefix("/Applications/")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? nil
        let adbResolution = ADBBinary.shared.resolve()

        var lines: [String] = []
        lines.append("DroidBerth 诊断包")
        lines.append("导出时间：\(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("— 应用 —")
        lines.append("版本：\(version) (\(build))")
        lines.append("bundle：\(bundlePath)")
        lines.append("是否在 /Applications：\(inApplications ? "是" : "否（Gatekeeper 检查会因此不成立）")")
        lines.append("日志目录：\(AppPaths.logsDirectory.path)")
        lines.append("")
        lines.append("— 系统 —")
        lines.append("macOS：\(process.operatingSystemVersionString)")
        lines.append("架构：\(unameMachine())")
        lines.append("可用空间（家目录卷）：\(free.map { ByteFormat.size($0) } ?? "未知")")
        lines.append("")
        lines.append("— adb / sidecar 的定位 —")
        lines.append("adb：\(adbResolution?.path.map { AppLog.redact($0) } ?? "**没找到**")")
        lines.append("sidecar：\(SidecarLocator.describe(SidecarLocator.locate()))")
        return lines.joined(separator: "\n")
    }

    private static func unameMachine() -> String {
        let result = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/uname"), ["-m"], timeout: 5)
        return result.ok ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "未知"
    }

    private static func writeSessionFiles(into work: URL, items: inout [String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        // ⚠️ 这两份是 **JSON**，不能只靠 `AppLog.redact(text)` 那条路 —— `JSONEncoder`
        // 把 `/` 转义成 `\/`，于是 `"bundlePath": "\/Users\/tango\/…"` 在纯文本替换下
        // **匹配不上**，本机用户名会原样进包（实测漏过一次）。
        // 所以脱敏必须做在**值**上、编码之前。`redactedForExport` 干的就是这件事。
        if let session = CrashSentinel.readSession(),
           let data = try? encoder.encode(session.redactedForExport) {
            try? data.write(to: work.appendingPathComponent("本次会话.json"), options: .atomic)
            items.append("本次会话.json")
        }
        if let previous = CrashSentinel.readPreviousSession(),
           let data = try? encoder.encode(previous.redactedForExport) {
            try? data.write(to: work.appendingPathComponent("上次会话.json"), options: .atomic)
            items.append("上次会话.json")
        }
        if let exception = CrashSentinel.readLastException() {
            write("未捕获异常.txt", exception, into: work, items: &items)
        }
    }

    private static func writeCrashReports(into work: URL, items: inout [String], warnings: inout [String]) {
        let reports = CrashSentinel.recentSystemCrashReports(within: 7 * 86_400, limit: 5)
        guard !reports.isEmpty else { return }
        let directory = work.appendingPathComponent("崩溃报告", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copied = 0
        for url in reports {
            // `.ips` 是 JSON 文本（首行一个头、其余正文），所以同样能过脱敏。
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                warnings.append("读不了崩溃报告 \(url.lastPathComponent)")
                continue
            }
            let redacted = AppLog.redact(text)
            if (try? redacted.write(to: directory.appendingPathComponent(url.lastPathComponent),
                                   atomically: true, encoding: .utf8)) != nil {
                copied += 1
            }
        }
        if copied > 0 { items.append("崩溃报告/（\(copied) 份系统 .ips）") }
    }

    private static func doctorJSON() -> String? {
        guard let sidecar = SidecarLocator.locate().executable else { return nil }
        let result = ProcessRunner.run(sidecar, ["doctor"], timeout: 60)
        let text = result.stdout.isEmpty ? result.stderr : result.stdout
        return text.isEmpty ? nil : AppLog.redact(text)
    }

    private static func adbText() -> String {
        guard let adb = ADBBinary.shared.resolve()?.path else { return "没找到 adb" }
        let url = URL(fileURLWithPath: adb)
        var lines: [String] = []
        let version = ProcessRunner.run(url, ["version"], timeout: 15)
        lines.append("— adb version —")
        lines.append(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        if !version.ok {
            lines.append("退出码：\(version.exitCode.map(String.init) ?? "nil")")
            lines.append("stderr：\(version.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        lines.append("")
        lines.append("— 5037 端口归谁 —")
        lines.append(port5197Owner())
        return AppLog.redact(lines.joined(separator: "\n"))
    }

    /// 5037 被**别的** adb 占用是 PRD §17 点名的坑：版本不一致会静默改变行为。
    ///
    /// **用 `lsof -F` 的字段化输出，而不是默认的表格输出** —— 默认输出里有一列是
    /// **进程属主（也就是本机用户名）**，那是路径替换抓不到的隐私（实测漏出去过：
    /// `adb 41421 tango 16u … TCP 127.0.0.1:5037`）。
    /// 排障只关心「谁在监听、是不是我们自己那个 adb」，用户名既无用也不该外带。
    /// `-F pcn` 只给 pid / 命令名 / 地址三样，正好够用。
    private static func port5197Owner() -> String {
        let result = ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/lsof"),
                                       ["-nP", "-iTCP:5037", "-sTCP:LISTEN", "-F", "pcn"],
                                       timeout: 10)
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return error.isEmpty ? "（没有进程在监听 5037）" : "（lsof 无输出：\(error)）"
        }

        // `-F` 的格式是每行一个字段：p<pid> 起一个新进程，c<命令>，n<地址>。
        var lines: [String] = []
        var pid = "?"
        var command = "?"
        for raw in text.split(separator: "\n") {
            let field = String(raw)
            guard let tag = field.first else { continue }
            let value = String(field.dropFirst())
            switch tag {
            case "p": pid = value
            case "c": command = value
            case "n": lines.append("pid \(pid)  \(command)  监听 \(value)")
            default: break
            }
        }
        return lines.isEmpty ? "（lsof 输出了内容但解析不出进程）" : lines.joined(separator: "\n")
    }

    private static func deviceListText() -> String {
        guard let adb = ADBBinary.shared.resolve()?.path else { return "没找到 adb" }
        let result = ProcessRunner.run(URL(fileURLWithPath: adb), ["devices", "-l"], timeout: 20)
        return AppLog.redactDeviceListing(result.stdout + result.stderr)
    }

    private static func readmeText(items: [String]) -> String {
        """
        DroidBerth 诊断包
        =================

        怎么用：把这个 zip 整个发给开发者即可。里面没有任何自动上传，
        生成之后它只存在于你的机器上，发不发、发给谁由你决定。

        内容
        ----
        \(items.map { "· \($0)" }.joined(separator: "\n"))

        隐私
        ----
        所有文本都已过脱敏：
        · 家目录里的用户名 → ~
        · 设备序列号 → 只留前 3 位
        · RSA 密钥指纹 → 只留前两组
        系统崩溃报告（.ips）同样过了一遍。若你仍不放心，可以直接删掉
        「日志」「崩溃报告」两个目录再发出去 —— 其余几份足以定位大多数问题。

        「上次会话.json」怎么看
        -----------------------
        里面有 endedAt 字段：
        · 有值 → 上次是正常退出的
        · 没有 → 上次异常结束。**这不等于崩溃** —— 强制退出、掉电也会这样。
          crashReportNames 里列出的系统 .ips 才是「确实崩过」的证据，
          两者要一起看。
        """
    }

    // MARK: - 写盘

    /// 把工作目录整棵收成 ZIP 条目，**根目录名一并保留**（等价于 ditto 的 `--keepParent`）。
    ///
    /// ## 为什么是「自己递归 + 只用 lastPathComponent 拼相对路径」
    ///
    /// 一开始用的是 `FileManager.enumerator` + `url.path.hasPrefix(root.path)`，结果
    /// **整个包只剩一个根目录条目**。根因是符号链接：`root.path` 是 `/tmp/...`，而枚举器
    /// 返回的是**解析过符号链接**的 `/private/tmp/...`，于是前缀判断对每一个子项都为假，
    /// 全部被静默跳过 —— 不报错、不警告，产出一个「能解压但空」的包。
    ///
    /// 教训：**不要拿绝对路径做前缀匹配**。这里改成从根开始自己递归，子项路径由
    /// `lastPathComponent` 逐级拼出来，全程不碰绝对路径，因此对符号链接免疫。
    /// 顺带拿到确定性的次序（同一个现场两次导出的 zip 内容一致，便于比对）。
    private static func zipEntries(root: URL) -> [ZipWriter.Entry] {
        var directories: [String] = []
        var files: [ZipWriter.Entry] = []
        collect(root, path: root.lastPathComponent, directories: &directories, files: &files)
        return directories.map { ZipWriter.Entry.directory($0) }
            + files.sorted { $0.path < $1.path }
    }

    private static func collect(_ directory: URL, path: String,
                                directories: inout [String], files: inout [ZipWriter.Entry]) {
        directories.append(path)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let childPath = "\(path)/\(item.lastPathComponent)"
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                collect(item, path: childPath, directories: &directories, files: &files)
            } else if let data = try? Data(contentsOf: item) {
                files.append(.file(childPath, data))
            }
        }
    }

    private static func write(_ name: String, _ text: String, into work: URL, items: inout [String]) {
        let url = work.appendingPathComponent(name)
        guard (try? AppLog.redact(text).write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        items.append(name)
    }
}

// MARK: - 出包前的脱敏

/// 会话档里的 `bundlePath` 是本机绝对路径，含用户名。
///
/// 做成「编码前先脱敏值」而不是「编码后脱敏文本」，是因为 JSON 会把 `/` 转义成 `\/`，
/// 文本替换会对不上（实测漏过一次）。
private extension CrashSentinel.Session {
    var redactedForExport: CrashSentinel.Session {
        var copy = self
        copy.bundlePath = AppLog.redact(bundlePath)
        return copy
    }
}

private extension CrashSentinel.PreviousSession {
    var redactedForExport: CrashSentinel.PreviousSession {
        var copy = self
        copy.session = session.redactedForExport
        if let exception = lastException {
            copy.lastException = AppLog.redact(exception)
        }
        return copy
    }
}
