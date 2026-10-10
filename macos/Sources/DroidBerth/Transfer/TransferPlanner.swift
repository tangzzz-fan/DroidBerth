import Foundation

enum TransferPlanner {
    struct Expansion: Sendable {
        var plans: [TransferPlan] = []
        var notes: [String] = []
        var blockingError: String?
    }

    private static func walk(root: URL) -> [(local: URL, components: [String], size: Int64)] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        var output: [(local: URL, components: [String], size: Int64)] = []
        var pending: [(url: URL, prefix: [String])] = [(root, [root.lastPathComponent])]
        var index = 0

        while index < pending.count {
            let current = pending[index]
            index += 1

            guard let children = try? fileManager.contentsOfDirectory(
                at: current.url,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else { continue }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let values = try? child.resourceValues(forKeys: keys) else { continue }
                let name = child.lastPathComponent

                if values.isDirectory == true {
                    if values.isSymbolicLink == true { continue }
                    pending.append((child, current.prefix + [name]))
                } else if values.isRegularFile == true {
                    let size = values.fileSize.flatMap { Int64($0) } ?? 0
                    output.append((child, current.prefix + [name], size))
                }
            }
        }

        return output
    }

    /// 「保留两者」在**下载**方向的冲突判据。
    ///
    /// macOS 默认卷（APFS / HFS+）**不区分大小写**，也不区分 Unicode 组合形式 ——
    /// `IMG.JPG` 与 `img.jpg` 在同一目录里就是同一个文件。而设备端（ext4 / f2fs）
    /// 区分大小写，所以手机上可以同时存在这两个名字。一旦按设备侧的语义去比较，
    /// 第二个文件会被判为「不冲突」，写过去**静默覆盖**第一个 —— 一次无声的数据丢失。
    ///
    /// 判据取自目标卷自身的 `volumeSupportsCaseSensitiveNames`，不是写死的假设
    /// （外接 APFS 区分大小写的卷是合法的）。取不到时按**不区分**处理：这一侧的
    /// 误判代价不对称 —— 多出一个 ` (1)` 只是碍眼，静默覆盖是丢数据。
    ///
    /// **上传方向刻意不折叠**：设备端主存储是 ext4 / f2fs 派生，确实区分大小写；
    /// 而 FAT32 格式的 SD 卡不区分 —— 那一种要等真机实测后再定（PRD §16 待验证项）。
    private static func conflictKey(_ name: String, caseSensitiveVolume: Bool) -> String {
        caseSensitiveVolume ? name : name.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func upload(
        localURLs: [URL],
        remoteDirectory: String,
        serial: String,
        shell: DeviceShell,
        policy: ConflictPolicy
    ) -> Expansion {
        var expansion = Expansion()

        var candidates: [(local: URL, components: [String], size: Int64)] = []
        let fileManager = FileManager.default

        for url in localURLs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                expansion.notes.append("跳过不存在的项目：\(url.lastPathComponent)")
                continue
            }

            if !isDirectory.boolValue {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                candidates.append((url, [url.lastPathComponent], size))
                continue
            }

            let walked = Self.walk(root: url)
            if walked.isEmpty {
                expansion.notes.append("\(url.lastPathComponent) 是空文件夹，已跳过")
            }
            candidates.append(contentsOf: walked)
        }

        guard !candidates.isEmpty else { return expansion }

        let directories = Set(candidates.map { candidate -> String in
            let parent = candidate.components.dropLast()
            return parent.isEmpty ? remoteDirectory : remoteDirectory + "/" + parent.joined(separator: "/")
        })
        let sortedDirectories = directories.sorted()
        let mkdirCommand = "mkdir -p " + sortedDirectories.map(DeviceShell.quote).joined(separator: " ")
        let mkdirResult = shell.shell(mkdirCommand, timeout: 60)
        guard mkdirResult.ok else {
            expansion.blockingError = "无法在设备上创建目标文件夹：\(mkdirResult.failureMessage)"
            return expansion
        }

        var existingByDirectory: [String: Set<String>] = [:]
        if policy == .keepBoth {
            for directory in sortedDirectories {
                if case .success(let entries) = shell.list(directory) {
                    existingByDirectory[directory] = Set(entries.map { $0.name })
                } else {
                    existingByDirectory[directory] = []
                }
            }
        }

        let totalBytes = candidates.reduce(Int64(0)) { $0 + $1.size }
        if let available = shell.availableBytes(at: remoteDirectory), available < totalBytes {
            expansion.blockingError = "设备剩余空间不足：需要 \(ByteFormat.size(totalBytes))，可用 \(ByteFormat.size(available))"
            return expansion
        }

        var conflictCount = 0
        for candidate in candidates {
            let parentComponents = candidate.components.dropLast()
            let directory = parentComponents.isEmpty
                ? remoteDirectory
                : remoteDirectory + "/" + parentComponents.joined(separator: "/")
            var name = candidate.components.last ?? candidate.local.lastPathComponent

            if policy == .keepBoth, var taken = existingByDirectory[directory], taken.contains(name) {
                let stem = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                var index = 1
                var candidateName: String
                repeat {
                    candidateName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
                    index += 1
                } while taken.contains(candidateName)
                name = candidateName
                taken.insert(candidateName)
                existingByDirectory[directory] = taken
                conflictCount += 1
            }

            let remotePath = directory + "/" + name
            expansion.plans.append(TransferPlan(
                serial: serial,
                direction: .upload,
                localPath: candidate.local.path,
                remotePath: remotePath,
                displayName: name,
                totalBytes: candidate.size
            ))
        }

        if conflictCount > 0 {
            expansion.notes.append("其中 \(conflictCount) 个文件在设备上已存在，将保留两者")
        }

        return expansion
    }

    static func download(
        remoteEntries: [RemoteEntry],
        localDirectory: URL,
        serial: String,
        shell: DeviceShell,
        policy: ConflictPolicy
    ) -> Expansion {
        var expansion = Expansion()
        var candidates: [(remotePath: String, components: [String], size: Int64?)] = []

        for entry in remoteEntries {
            if !entry.isDirectory {
                candidates.append((entry.path, [entry.name], entry.size))
                continue
            }

            let result = shell.shell("ls -lR \(DeviceShell.quote(entry.path))", timeout: 120)
            guard result.ok else {
                expansion.notes.append("无法读取设备文件夹 \(entry.name)：\(result.failureMessage)")
                continue
            }
            let tree = RemoteListing.parseRecursive(result.stdout, root: entry.path)
            var count = 0
            for node in tree {
                for child in node.entries where !child.isDirectory {
                    var relative = child.path
                    if relative.hasPrefix(entry.path + "/") {
                        relative = String(relative.dropFirst(entry.path.count + 1))
                    }
                    candidates.append((child.path, relative.split(separator: "/").map(String.init), child.size))
                    count += 1
                }
            }
            if count == 0 {
                expansion.notes.append("\(entry.name) 里没有文件，已跳过")
            }
        }

        guard !candidates.isEmpty else { return expansion }

        let fileManager = FileManager.default
        let basePath = localDirectory.path

        // 目标卷怎么判「同名」，直接决定「保留两者」会不会误判。见 conflictKey 的说明。
        let caseSensitiveVolume = (try? localDirectory.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) ?? false

        var usedNames: [String: Set<String>] = [:]
        var conflictCount = 0

        for candidate in candidates {
            let parentComponents = candidate.components.dropLast()
            let relativeDirectory = parentComponents.joined(separator: "/")
            let targetDirectory = relativeDirectory.isEmpty
                ? basePath
                : basePath + "/" + relativeDirectory
            try? fileManager.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)

            var name = candidate.components.last ?? "unnamed"
            if policy == .keepBoth {
                var taken = usedNames[targetDirectory] ?? Set(
                    ((try? fileManager.contentsOfDirectory(atPath: targetDirectory)) ?? [])
                        .map { Self.conflictKey($0, caseSensitiveVolume: caseSensitiveVolume) }
                )
                if taken.contains(Self.conflictKey(name, caseSensitiveVolume: caseSensitiveVolume)) {
                    let stem = (name as NSString).deletingPathExtension
                    let ext = (name as NSString).pathExtension
                    var index = 1
                    var candidateName: String
                    repeat {
                        candidateName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
                        index += 1
                    } while taken.contains(Self.conflictKey(candidateName, caseSensitiveVolume: caseSensitiveVolume))
                    name = candidateName
                    conflictCount += 1
                }
                taken.insert(Self.conflictKey(name, caseSensitiveVolume: caseSensitiveVolume))
                usedNames[targetDirectory] = taken
            }

            expansion.plans.append(TransferPlan(
                serial: serial,
                direction: .download,
                localPath: targetDirectory + "/" + name,
                remotePath: candidate.remotePath,
                displayName: name,
                totalBytes: candidate.size
            ))
        }

        if conflictCount > 0 {
            expansion.notes.append("其中 \(conflictCount) 个文件在 Mac 上已存在，将保留两者")
        }

        return expansion
    }
}
