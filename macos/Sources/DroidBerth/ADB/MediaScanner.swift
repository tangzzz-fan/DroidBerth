import Foundation

enum MediaScanner {
    struct Outcome: Sendable {
        let remotePath: String
        let indexed: Bool
        let detail: String
    }

    private static let queryURI = "content://media/external/file"

    static func scan(shell: DeviceShell, remotePaths: [String]) -> [Outcome] {
        guard !remotePaths.isEmpty else { return [] }

        for path in remotePaths {
            let url = "file://" + path
            _ = shell.shell(
                "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(DeviceShell.quote(url))",
                timeout: 20
            )
        }

        var pending = remotePaths
        var found: Set<String> = []
        let deadline = Date().addingTimeInterval(6)

        while !pending.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.6)
            var stillPending: [String] = []
            for path in pending {
                if isIndexed(shell: shell, remotePath: path) {
                    found.insert(path)
                } else {
                    stillPending.append(path)
                }
            }
            pending = stillPending
        }

        return remotePaths.map { path in
            if found.contains(path) {
                return Outcome(remotePath: path, indexed: true, detail: "已进入系统相册索引")
            }
            return Outcome(
                remotePath: path,
                indexed: false,
                detail: "未在系统相册索引中找到。可在手机上打开相册下拉刷新；若仍看不到，重启手机后即可出现"
            )
        }
    }

    static func isIndexed(shell: DeviceShell, remotePath: String) -> Bool {
        let name = (remotePath as NSString).lastPathComponent
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        let whereClause = "_data LIKE '%\(escaped)'"
        let command = "content query --uri \(queryURI) --projection _id:_data --where \(DeviceShell.doubleQuote(whereClause))"
        let result = shell.shell(command, timeout: 20)
        guard result.ok else { return false }
        let output = result.stdout
        if output.contains("No result found") { return false }
        if output.contains("Error") { return false }
        return output.contains("_data=")
    }
}
