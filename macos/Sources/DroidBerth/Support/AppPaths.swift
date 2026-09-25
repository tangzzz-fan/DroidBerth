import Foundation

enum AppPaths {
    static let bundleIdentifier = "dev.tango.droidberth"

    static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base.appendingPathComponent("DroidBerth", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var stagingDirectory: URL {
        let directory = supportDirectory.appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var reportsDirectory: URL {
        let directory = supportDirectory.appendingPathComponent("Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func makeStagingItem(named name: String) -> URL {
        let directory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    static func makeBatchDirectory() -> URL {
        let directory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func clearStaging() {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            try? fileManager.removeItem(at: item)
        }
    }
}
