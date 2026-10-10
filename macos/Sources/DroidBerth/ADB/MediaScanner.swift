import Foundation

/// 上传之后的「媒体入库」检查（PRD §19，本产品风险最高的一项）。
///
/// `adb push` 只写文件系统，**不经过 MediaStore**。相册读的是索引而不是文件系统的
/// 实时视图，所以「推过去了但相册里看不见」是这个产品最容易在核心任务上失败的地方。
///
/// 这里做两件事，都很克制：
/// 1. **触发扫描** —— 命令在运行时探测，不按 Android 版本表写死（见 `ScanCommand`）。
/// 2. **回查索引** —— 查不到就如实说「没查到」并给可操作指引，**绝不假装成功**。
enum MediaScanner {
    /// 一个文件的入库判定。**三态而不是两态**：
    ///
    /// 上传 `.txt` 时，它本来就**不该**出现在相册索引里。把这种情况报成失败是甩锅，
    /// 报成「已进入相册索引」是撒谎（这正是此前 `isIndexed` 的缺陷）。所以单列
    /// `.notMedia`，由调用方保持**沉默**。
    enum Indexability: Sendable {
        case indexed
        case notIndexed
        case notMedia
    }

    struct Outcome: Sendable {
        let remotePath: String
        let indexability: Indexability

        var indexed: Bool { indexability == .indexed }

        /// 非媒体文件不参与相册索引，调用方应当**什么都不说**。
        var applicable: Bool { indexability != .notMedia }

        var detail: String {
            switch indexability {
            case .indexed: "已进入系统相册索引"
            case .notIndexed: "未在系统相册索引中找到。可在手机上打开相册下拉刷新；若仍看不到，重启手机后即可出现"
            case .notMedia: "非媒体文件，不参与相册索引"
            }
        }
    }

    // MARK: - 触发扫描用哪条命令

    /// **运行时探测，不写版本表。**
    ///
    /// `android.intent.action.MEDIA_SCANNER_SCAN_FILE` 广播在 API 29（Android 10）
    /// 已被标记废弃，官方说法是改成向 MediaStore 直接插入。而在那之后，「主动扫一个
    /// 路径」这件事只剩 shell 侧的命令，公开资料里给出的名字互相矛盾
    /// （`cmd media_scanner scan-file` / `cmd media.scan` / `cmd media_rescan` …
    /// 彼此冲突，且多数来自低可信来源）。与其押一个名字，不如**问设备自己**：
    /// `cmd -l` 会列出本机存在的全部 shell 服务命令，按这张实测出来的名单挑。
    ///
    /// 这同时解决了版本覆盖问题：名单里没有就退回广播，功能不会因此消失。
    enum ScanCommand: Sendable {
        /// `cmd media_scanner scan-file <文件>`
        case scanFile
        /// `cmd media.scan <目录>`
        case mediaScan
        /// `am broadcast MEDIA_SCANNER_SCAN_FILE`（API 29 起废弃，作为兜底保留）
        case broadcast

        /// 这条命令要传**文件路径**还是**所在目录**。三者语义不同，传错就是静默无效。
        var targetsDirectory: Bool {
            switch self {
            case .scanFile, .broadcast: false
            case .mediaScan: true
            }
        }

        func shellCommand(for path: String) -> String {
            switch self {
            case .scanFile:
                "cmd media_scanner scan-file \(DeviceShell.quote(path))"
            case .mediaScan:
                "cmd media.scan \(DeviceShell.quote(path))"
            case .broadcast:
                "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(DeviceShell.quote("file://" + path))"
            }
        }
    }

    nonisolated(unsafe) private static var probedCommands: [String: ScanCommand] = [:]
    private static let probeLock = NSLock()

    /// 按设备序列号记住探测结果 —— 一台机器上的可用命令不会中途变化，
    /// 而每次上传都探一遍等于白加一次子进程。
    static func command(for shell: DeviceShell) -> ScanCommand {
        probeLock.lock()
        defer { probeLock.unlock() }
        if let cached = probedCommands[shell.serial] { return cached }

        var resolved: ScanCommand = .broadcast
        let listed = shell.shell("cmd -l", timeout: 15)
        if listed.ok {
            let services = Set(
                listed.stdout.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            )
            if services.contains("media_scanner") {
                resolved = .scanFile
            } else if services.contains("media.scan") {
                resolved = .mediaScan
            }
        }
        probedCommands[shell.serial] = resolved
        return resolved
    }

    /// 已经探测过、当前还留着缓存的设备。给 `DeviceMonitor` 用来清理离线设备。
    static var knownSerials: [String] {
        probeLock.lock()
        defer { probeLock.unlock() }
        return Array(probedCommands.keys)
    }

    /// 设备离线时清掉它的探测缓存。缓存按 serial 分键，条目本来就不会串 —— 这里
    /// 的意义只是不在一次长会话里为已经拔掉的设备留着无主条目。
    static func forget(serial: String) {
        probeLock.lock()
        defer { probeLock.unlock() }
        probedCommands.removeValue(forKey: serial)
    }

    // MARK: - 索引判据

    /// 扩展名 → MediaStore 的表名。
    ///
    /// 分表是**必须**的：原来一律查 `external/file`，那是覆盖所有文件类型的表，
    /// 于是上传 `.txt` 也会「查到」并报「已进入相册索引」，而相册里根本没有它。
    ///
    /// 判不出来时返回 `nil`（= 不参与相册索引），而不是猜一个表。**宁可沉默，
    /// 不给一句无法验证的结论。**代价是某些冷门媒体扩展名（如 `.mts`）会被漏判，
    /// 所以下面补了一张扫描器自己的表 —— 复用 `isImageFile` 那套会连带改掉图标语义，
    /// 不该动。
    private static func mediaTable(for name: String) -> String? {
        if name.isImageFile { return "images" }
        if name.isVideoFile { return "video" }
        if name.isAudioFile { return "audio" }

        switch name.pathExtensionLowercased {
        case "avif", "jxl", "psd", "svg": return "images"
        case "mts", "m2ts", "mxf", "vob", "rmvb", "asf": return "video"
        case "aiff", "aif", "ape", "mka", "amr": return "audio"
        default: return nil
        }
    }

    static func indexability(shell: DeviceShell, remotePath: String) -> Indexability {
        guard let table = mediaTable(for: remotePath) else { return .notMedia }
        return isIndexed(shell: shell, remotePath: remotePath, table: table) ? .indexed : .notIndexed
    }

    private static func isIndexed(shell: DeviceShell, remotePath: String, table: String) -> Bool {
        let name = (remotePath as NSString).lastPathComponent
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        // 用**后缀匹配**而不是路径等值：设备上同一处有两个合法写法
        // （`/sdcard/...` 与 `/storage/emulated/0/...`），MediaStore 存的是后者，
        // 而我们的 remotePath 用的是前者。等值匹配会永远查不到。
        let whereClause = "_data LIKE '%/\(escaped)'"
        let command = "content query --uri content://media/external/\(table)/media "
            + "--projection _id:_data --where \(DeviceShell.doubleQuote(whereClause))"
        let result = shell.shell(command, timeout: 20)
        guard result.ok else { return false }
        if result.stdout.contains("No result found") { return false }
        if result.stdout.contains("Error") { return false }

        // `LIKE '%/x.jpg'` 命中 `a/x.jpg`，也命中 `a/prefix_x.jpg` —— 再按 basename
        // 精确核一遍，否则会把「同目录下另一个结尾相同的文件」当成自己的。
        return result.stdout
            .split(separator: "\n")
            .contains { line in
                guard let range = line.range(of: "_data=") else { return false }
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return (value as NSString).lastPathComponent == name
            }
    }

    // MARK: - 入口

    static func scan(shell: DeviceShell, remotePaths: [String]) -> [Outcome] {
        guard !remotePaths.isEmpty else { return [] }

        let command = command(for: shell)

        // 只有媒体文件才值得扫、值得等。非媒体直接给判定，不进轮询。
        let mediaPaths = remotePaths.filter { mediaTable(for: $0) != nil }

        if !mediaPaths.isEmpty {
            // 同一条命令可能覆盖多个文件（`media.scan` 传的是目录），去重能省掉
            // 一串冗余子进程 —— 上传 200 张图时这不是小事。
            let targets = Set(mediaPaths.map { path in
                command.targetsDirectory ? (path as NSString).deletingLastPathComponent : path
            })
            for target in targets {
                _ = shell.shell(command.shellCommand(for: target), timeout: 30)
            }
        }

        var pending = mediaPaths
        var found: Set<String> = []
        let deadline = Date().addingTimeInterval(6)

        while !pending.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.6)
            var stillPending: [String] = []
            for path in pending {
                if indexability(shell: shell, remotePath: path) == .indexed {
                    found.insert(path)
                } else {
                    stillPending.append(path)
                }
            }
            pending = stillPending
        }

        return remotePaths.map { path in
            let indexability: Indexability
            if found.contains(path) {
                indexability = .indexed
            } else if mediaTable(for: path) == nil {
                indexability = .notMedia
            } else {
                indexability = .notIndexed
            }
            return Outcome(remotePath: path, indexability: indexability)
        }
    }
}
