import Foundation

extension RemoteListing {
    static func parseRecursive(_ output: String, root: String) -> [(directory: String, entries: [RemoteEntry])] {
        var result: [(directory: String, entries: [RemoteEntry])] = []
        var currentDirectory: String?
        var currentEntries: [RemoteEntry] = []

        func flush() {
            if let currentDirectory {
                result.append((currentDirectory, currentEntries))
            }
            currentEntries = []
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("total ") { continue }

            let first = line.first ?? " "
            let isEntryLine = "-dlbcps".contains(first)

            if !isEntryLine, line.hasSuffix(":") {
                flush()
                currentDirectory = String(line.dropLast())
                continue
            }

            guard let directory = currentDirectory, isEntryLine else { continue }
            guard let entry = parseLine(line, directory: directory) else { continue }
            if entry.name == "." || entry.name == ".." { continue }
            currentEntries.append(entry)
        }
        flush()

        return result
    }
}
