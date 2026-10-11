import Foundation

struct RemoteEntry: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64?
    let modified: Date?

    var id: String { path }

    var kindLabel: String {
        // 顺序与 `LocalEntry.kindLabel`（本地侧）**逐字一致** —— 这是刻意的：
        // 两端各写一份是不得已（数据结构不同），但**判断顺序与用词必须一样**，
        // 否则同一个概念在两个窗格里会显示得不一样（本项目反复栽的那一类缺陷）。
        // 实测过的具体后果：本地侧漏了 `isSymlink` 那一支，符号链接显示成了「文稿」。
        if isSymlink { return "替身" }
        if isDirectory { return "文件夹" }
        let ext = name.pathExtensionLowercased
        if ext.isEmpty { return "文稿" }
        return ext.uppercased() + " 文稿"
    }

    var systemImage: String {
        FileTypeIcon.symbol(forName: name, isDirectory: isDirectory)
    }
}

enum RemoteListing {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let dayOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ output: String, directory: String) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("total ") { continue }
            if line.hasSuffix(":") { continue }

            guard let entry = parseLine(line, directory: directory) else { continue }
            if entry.name == "." || entry.name == ".." { continue }
            entries.append(entry)
        }

        return entries
    }

    static func parseLine(_ line: String, directory: String) -> RemoteEntry? {
        let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 8 else { return nil }

        let mode = parts[0]
        guard let first = mode.first, "-dlbcps".contains(first) else { return nil }

        let isSymlink = first == "l"
        let isDirectory = first == "d"

        guard let rawSize = Int64(parts[4]) else { return nil }

        var name = parts[7]
        if isSymlink, let range = name.range(of: " -> ") {
            name = String(name[name.startIndex..<range.lowerBound])
        }
        guard !name.isEmpty else { return nil }

        var modified = dateFormatter.date(from: "\(parts[5]) \(parts[6])")
        if modified == nil {
            modified = dayOnlyFormatter.date(from: parts[5])
        }

        let path = directory.hasSuffix("/") ? directory + name : directory + "/" + name

        return RemoteEntry(
            name: name,
            path: path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: isDirectory ? nil : rawSize,
            modified: modified
        )
    }
}
