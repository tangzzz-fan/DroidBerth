import AppKit
import Foundation

@MainActor
@Observable
final class AppModel {
    enum Pane: Sendable {
        case mac
        case device
    }

    enum MacSource: String, Sendable, CaseIterable, Identifiable {
        case files
        case photos

        var id: String { rawValue }
        var label: String { self == .files ? "Finder 位置" : "照片图库" }
    }

    struct Banner: Identifiable, Sendable {
        enum Level: Sendable {
            case info
            case warning
            case error
        }

        let id = UUID()
        let level: Level
        let title: String
        let detail: String?
    }

    enum ExportPhase: Sendable, Equatable {
        case idle
        case running(done: Int, total: Int, current: String)
        case finished(exported: Int, failed: Int)
    }

    let settings = AppSettings.shared
    let monitor = DeviceMonitor()
    let wireless = WirelessManager()
    let photos = PhotoLibraryModel()
    let queue = TransferQueue()

    var focus: Pane = .mac
    var macSource: MacSource = .files

    var localDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    private(set) var localEntries: [LocalEntry] = []
    var localSelection: Set<String> = []
    private(set) var localHistory: [URL] = []
    private(set) var localHistoryIndex = -1
    var localError: String?

    var remoteDirectory = "/sdcard"
    private(set) var remoteEntries: [RemoteEntry] = []
    var remoteSelection: Set<String> = []
    private(set) var remoteHistory: [String] = []
    private(set) var remoteHistoryIndex = -1
    var remoteError: String?
    var remoteLoading = false
    var remoteAvailableBytes: Int64?

    var photoSelection: Set<String> = []

    var showHiddenFiles = false
    var banner: Banner?
    var exportPhase: ExportPhase = .idle

    var deviceQuickLocations: [(String, String)] {
        [("DCIM", "/sdcard/DCIM"), ("Movies", "/sdcard/Movies"), ("Pictures", "/sdcard/Pictures"), ("Download", "/sdcard/Download")]
    }

    var activeDevice: AndroidDevice? { monitor.activeDevice }

    var isExporting: Bool {
        if case .running = exportPhase { return true }
        return false
    }

    // MARK: - 生命周期

    func start() {
        AppPaths.clearStaging()
        photos.refreshAccess()
        wireless.attach(monitor: monitor)
        FinderServiceProvider.shared.install { [weak self] urls in
            self?.handleFinderService(urls)
        }
        monitor.start()
        navigateLocal(to: localDirectory, resetHistory: true)
        Task { await bootstrapRemote() }
    }

    private func bootstrapRemote() async {
        try? await Task.sleep(for: .seconds(1))
        if let device = monitor.activeDevice, let remembered = settings.destination(for: device.serial) {
            remoteDirectory = remembered
        }
        await loadRemote()
    }

    func deviceDidChange() async {
        if let device = monitor.activeDevice, let remembered = settings.destination(for: device.serial) {
            remoteDirectory = remembered
        }
        remoteHistory = []
        remoteHistoryIndex = -1
        await loadRemote()
    }

    // MARK: - Mac 窗格

    func navigateLocal(to url: URL, resetHistory: Bool = false) {
        localDirectory = url
        if resetHistory {
            localHistory = [url]
            localHistoryIndex = 0
        } else {
            if localHistoryIndex < localHistory.count - 1 {
                localHistory = Array(localHistory.prefix(localHistoryIndex + 1))
            }
            localHistory.append(url)
            localHistoryIndex = localHistory.count - 1
        }
        localSelection = []
        reloadLocal()
    }

    func reloadLocal() {
        switch LocalFileSystem.list(localDirectory, showHidden: showHiddenFiles) {
        case .success(let entries):
            localEntries = entries.sorted(by: Self.localSort)
            localError = nil
        case .failure(let message):
            localEntries = []
            localError = message
        }
    }

    var canGoLocalBack: Bool { localHistoryIndex > 0 }
    var canGoLocalForward: Bool { localHistoryIndex < localHistory.count - 1 }

    func localGoBack() {
        guard canGoLocalBack else { return }
        localHistoryIndex -= 1
        localDirectory = localHistory[localHistoryIndex]
        localSelection = []
        reloadLocal()
    }

    func localGoForward() {
        guard canGoLocalForward else { return }
        localHistoryIndex += 1
        localDirectory = localHistory[localHistoryIndex]
        localSelection = []
        reloadLocal()
    }

    func localGoUp() {
        let components = localDirectory.standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { return }
        let parent = "/" + components.dropLast().joined(separator: "/")
        navigateLocal(to: URL(fileURLWithPath: parent))
    }

    func openLocalSelection() {
        guard let entry = localEntries.first(where: { localSelection.contains($0.id) }), entry.isDirectory else { return }
        navigateLocal(to: entry.url)
    }

    private static func localSort(_ lhs: LocalEntry, _ rhs: LocalEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // MARK: - 设备窗格

    func navigateRemote(to path: String, resetHistory: Bool = false) async {
        remoteDirectory = path
        if resetHistory {
            remoteHistory = [path]
            remoteHistoryIndex = 0
        } else {
            if remoteHistoryIndex < remoteHistory.count - 1 {
                remoteHistory = Array(remoteHistory.prefix(remoteHistoryIndex + 1))
            }
            remoteHistory.append(path)
            remoteHistoryIndex = remoteHistory.count - 1
        }
        remoteSelection = []
        await loadRemote()
    }

    func loadRemote() async {
        guard let device = monitor.activeDevice else {
            remoteEntries = []
            remoteError = nil
            remoteAvailableBytes = nil
            return
        }
        guard let shell = monitor.shell(for: device) else {
            remoteEntries = []
            remoteError = "未找到可用的 adb 可执行文件"
            return
        }

        remoteLoading = true
        let path = remoteDirectory

        let listing = await Task.detached(priority: .userInitiated) { () -> DeviceShell.ListingResult in
            shell.list(path)
        }.value

        switch listing {
        case .success(let entries):
            remoteEntries = entries.sorted(by: Self.remoteSort)
            remoteError = nil
        case .failure(let message):
            remoteEntries = []
            remoteError = message
        }

        remoteAvailableBytes = await Task.detached(priority: .utility) {
            shell.availableBytes(at: path)
        }.value

        remoteLoading = false
    }

    var canGoRemoteBack: Bool { remoteHistoryIndex > 0 }
    var canGoRemoteForward: Bool { remoteHistoryIndex < remoteHistory.count - 1 }

    func remoteGoBack() async {
        guard canGoRemoteBack else { return }
        remoteHistoryIndex -= 1
        await navigateRemote(to: remoteHistory[remoteHistoryIndex])
    }

    func remoteGoForward() async {
        guard canGoRemoteForward else { return }
        remoteHistoryIndex += 1
        await navigateRemote(to: remoteHistory[remoteHistoryIndex])
    }

    func remoteGoUp() async {
        guard remoteDirectory != "/sdcard", remoteDirectory != "/" else { return }
        let parent = (remoteDirectory as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != remoteDirectory else { return }
        await navigateRemote(to: parent)
    }

    func openRemoteSelection() async {
        guard let entry = remoteEntries.first(where: { remoteSelection.contains($0.id) }), entry.isDirectory else { return }
        await navigateRemote(to: entry.path)
    }

    private static func remoteSort(_ lhs: RemoteEntry, _ rhs: RemoteEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // MARK: - 上传

    var selectedLocalURLs: [URL] {
        localEntries.filter { localSelection.contains($0.id) }.map(\.url)
    }

    var selectedPhotoItems: [PhotoItem] {
        photos.items.filter { photoSelection.contains($0.id) }
    }

    var uploadCandidateNames: [String] {
        switch macSource {
        case .files: selectedLocalURLs.map(\.lastPathComponent)
        case .photos: selectedPhotoItems.map(\.filename)
        }
    }

    var uploadSelectionCount: Int {
        switch macSource {
        case .files: localSelection.count
        case .photos: photoSelection.count
        }
    }

    func uploadDestination(for device: AndroidDevice) -> (path: String, reason: String) {
        if let remembered = settings.destination(for: device.serial), remoteDirectory == "/sdcard" {
            return (remembered, "上次使用的目录")
        }
        if remoteDirectory != "/sdcard" {
            return (remoteDirectory, "设备窗格当前目录")
        }
        if settings.routingEnabled, let name = uploadCandidateNames.first {
            if name.isVideoFile { return ("/sdcard/Movies", "按文件类型分流") }
            if name.isImageFile { return ("/sdcard/DCIM", "按文件类型分流") }
            return ("/sdcard/Download", "按文件类型分流") 
        }
        return (remoteDirectory, "设备窗格当前目录")
    }

    func uploadSelection() async {
        guard let device = monitor.activeDevice else {
            banner = Banner(level: .warning, title: "没有可用的设备", detail: "请用数据线连接 Android 手机，并在手机上允许 USB 调试")
            return
        }
        guard device.state.isUsable else {
            banner = Banner(level: .warning, title: "设备当前不可用", detail: "状态：\(device.state.localizedDescription)")
            return
        }
        guard let shell = monitor.shell(for: device) else {
            banner = Banner(level: .error, title: "未找到 adb", detail: "请确认 app 包内的 adb 完整")
            return
        }

        var sources: [URL] = []
        switch macSource {
        case .files:
            sources = selectedLocalURLs
            guard !sources.isEmpty else {
                banner = Banner(level: .info, title: "请先选择要上传的项目", detail: "在左侧 Mac 窗格里选中文件或文件夹")
                return
            }
        case .photos:
            let selected = selectedPhotoItems
            guard !selected.isEmpty else {
                banner = Banner(level: .info, title: "请先选择要推送的照片", detail: "在左侧照片图库里选中项目")
                return
            }
            sources = await exportPhotos(selected)
            guard !sources.isEmpty else { return }
        }

        let destination = uploadDestination(for: device)
        let serial = device.serial
        let policy = settings.conflictPolicy

        let expansion = await Task.detached(priority: .userInitiated) {
            TransferPlanner.upload(
                localURLs: sources,
                remoteDirectory: destination.path,
                serial: serial,
                shell: shell,
                policy: policy
            )
        }.value

        if let error = expansion.blockingError {
            banner = Banner(level: .error, title: "无法开始上传", detail: error)
            return
        }
        guard !expansion.plans.isEmpty else {
            banner = Banner(level: .info, title: "没有可上传的文件", detail: expansion.notes.joined(separator: "；"))
            return
        }

        var notes = expansion.notes
        notes.insert("落点：\(destination.path)（\(destination.reason)）", at: 0)
        queue.enqueue(plans: expansion.plans, notes: notes)
        settings.rememberDestination(destination.path, for: serial)

        if destination.path != remoteDirectory {
            await navigateRemote(to: destination.path)
        } else {
            await loadRemote()
        }
    }

    // MARK: - Finder 服务

    func handleFinderService(_ urls: [URL]) {
        NSApp.activate()
        Task { await uploadFromFinderService(urls) }
    }

    private func uploadFromFinderService(_ urls: [URL]) async {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            banner = Banner(
                level: .warning,
                title: "Finder 传来的项目已不存在",
                detail: "\(urls.count) 个项目都无法读取"
            )
            return
        }

        let device: AndroidDevice
        if let current = monitor.activeDevice, current.state.isUsable {
            device = current
        } else {
            banner = Banner(
                level: .info,
                title: "正在等待设备",
                detail: "已从 Finder 收到 \(existing.count) 个项目，正在识别 Android 设备…"
            )
            guard let waited = await waitForUsableDevice() else {
                banner = Banner(
                    level: .warning,
                    title: "没有可用的设备",
                    detail: "已从 Finder 收到 \(existing.count) 个项目，但没有等到可用的 Android 设备。连接设备后请重新执行一次。"
                )
                return
            }
            device = waited
        }

        guard let shell = monitor.shell(for: device) else {
            banner = Banner(level: .error, title: "未找到 adb", detail: "请确认 app 包内的 adb 完整")
            return
        }

        let destination = finderServiceDestination(for: device, urls: existing)
        let serial = device.serial
        let policy = settings.conflictPolicy

        let expansion = await Task.detached(priority: .userInitiated) {
            TransferPlanner.upload(
                localURLs: existing,
                remoteDirectory: destination.path,
                serial: serial,
                shell: shell,
                policy: policy
            )
        }.value

        if let error = expansion.blockingError {
            banner = Banner(level: .error, title: "无法开始上传", detail: error)
            return
        }
        guard !expansion.plans.isEmpty else {
            banner = Banner(level: .info, title: "没有可上传的文件", detail: expansion.notes.joined(separator: "；"))
            return
        }

        var notes = expansion.notes
        notes.insert("来源：Finder 服务（\(existing.count) 个项目）", at: 0)
        notes.insert("落点：\(destination.path)（\(destination.reason)）", at: 0)
        queue.enqueue(plans: expansion.plans, notes: notes)
        settings.rememberDestination(destination.path, for: serial)

        if destination.path != remoteDirectory {
            await navigateRemote(to: destination.path)
        } else {
            await loadRemote()
        }
    }

    private func finderServiceDestination(
        for device: AndroidDevice,
        urls: [URL]
    ) -> (path: String, reason: String) {
        if let remembered = settings.destination(for: device.serial) {
            return (remembered, "上次使用的目录")
        }
        if remoteDirectory != "/sdcard" {
            return (remoteDirectory, "设备窗格当前目录")
        }
        guard settings.routingEnabled else {
            return ("/sdcard/Download", "默认落点")
        }
        let names = urls.map(\.lastPathComponent)
        if names.contains(where: { $0.isVideoFile }) { return ("/sdcard/Movies", "按文件类型分流") }
        if names.contains(where: { $0.isImageFile }) { return ("/sdcard/DCIM", "按文件类型分流") }
        return ("/sdcard/Download", "按文件类型分流")
    }

    private func waitForUsableDevice(timeout: TimeInterval = 20) async -> AndroidDevice? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await monitor.refresh()
            if let device = monitor.activeDevice, device.state.isUsable {
                return device
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func exportPhotos(_ items: [PhotoItem]) async -> [URL] {
        let batch = AppPaths.makeBatchDirectory()
        var exported: [URL] = []
        var failed = 0
        let total = items.count

        exportPhase = .running(done: 0, total: total, current: "")

        for await result in PhotoExporter.export(identifiers: items.map(\.localIdentifier), to: batch) {
            if let url = result.url {
                exported.append(url)
            } else {
                failed += 1
            }
            exportPhase = .running(done: exported.count + failed, total: total, current: result.filename)
        }

        exportPhase = .finished(exported: exported.count, failed: failed)

        if exported.isEmpty {
            banner = Banner(level: .error, title: "照片导出失败", detail: "没有成功导出任何项目，请检查照片图库权限")
        } else if failed > 0 {
            banner = Banner(level: .warning, title: "部分照片导出失败", detail: "\(failed) 个项目未能导出，其余 \(exported.count) 个将继续推送")
        }

        return exported
    }

    // MARK: - 下载

    func downloadSelection() async {
        guard let device = monitor.activeDevice, device.state.isUsable else {
            banner = Banner(level: .warning, title: "没有可用的设备", detail: nil)
            return
        }
        guard let shell = monitor.shell(for: device) else {
            banner = Banner(level: .error, title: "未找到 adb", detail: nil)
            return
        }

        let entries = remoteEntries.filter { remoteSelection.contains($0.id) }
        guard !entries.isEmpty else {
            banner = Banner(level: .info, title: "请先选择要下载的项目", detail: "在右侧设备窗格里选中文件或文件夹")
            return
        }

        let destination = localDirectory
        let serial = device.serial
        let policy = settings.conflictPolicy

        let expansion = await Task.detached(priority: .userInitiated) {
            TransferPlanner.download(
                remoteEntries: entries,
                localDirectory: destination,
                serial: serial,
                shell: shell,
                policy: policy
            )
        }.value

        guard !expansion.plans.isEmpty else {
            banner = Banner(level: .info, title: "没有可下载的文件", detail: expansion.notes.joined(separator: "；"))
            return
        }

        var notes = expansion.notes
        notes.insert("落点：\(destination.path)", at: 0)
        queue.enqueue(plans: expansion.plans, notes: notes)
        reloadLocal()
    }

    // MARK: - 设备端写操作

    func makeRemoteDirectory(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let device = monitor.activeDevice, let shell = monitor.shell(for: device) else {
            banner = Banner(level: .error, title: "未找到 adb", detail: nil)
            return
        }

        let path = remoteDirectory.hasSuffix("/") ? remoteDirectory + trimmed : remoteDirectory + "/" + trimmed
        let result = await Task.detached(priority: .userInitiated) { shell.makeDirectory(path) }.value
        if result.ok {
            await loadRemote()
        } else {
            banner = Banner(level: .error, title: "新建文件夹失败", detail: result.failureMessage)
        }
    }

    func deleteRemoteSelection() async {
        let entries = remoteEntries.filter { remoteSelection.contains($0.id) }
        guard !entries.isEmpty else { return }
        guard let device = monitor.activeDevice, let shell = monitor.shell(for: device) else { return }

        let paths = entries.map(\.path)
        let result = await Task.detached(priority: .userInitiated) { shell.remove(paths) }.value
        if result.ok {
            remoteSelection = []
            await loadRemote()
        } else {
            banner = Banner(level: .error, title: "删除失败", detail: result.failureMessage)
        }
    }

    func scanRemoteSelection() async {
        let entries = remoteEntries.filter { remoteSelection.contains($0.id) }
        let paths = entries.filter { !$0.isDirectory }.map(\.path)
        guard !paths.isEmpty else {
            banner = Banner(level: .info, title: "请先选择要扫描的文件", detail: nil)
            return
        }
        guard let device = monitor.activeDevice, let shell = monitor.shell(for: device) else { return }

        let outcomes = await Task.detached(priority: .userInitiated) {
            MediaScanner.scan(shell: shell, remotePaths: paths)
        }.value

        let indexed = outcomes.filter(\.indexed).count
        let failed = outcomes.count - indexed
        if failed == 0 {
            banner = Banner(level: .info, title: "媒体库已刷新", detail: "\(indexed) 个文件已进入系统相册索引")
        } else {
            banner = Banner(
                level: .warning,
                title: "部分文件未进入相册索引",
                detail: "\(failed) 个文件未索引。可在手机上打开相册下拉刷新；若仍看不到，重启手机后即可出现"
            )
        }
    }

    // MARK: - 无线

    func enableWireless() async {
        guard let device = monitor.activeDevice else {
            banner = Banner(level: .warning, title: "没有可用的设备", detail: "请先用数据线连接手机")
            return
        }
        switch await wireless.enable(device: device) {
        case .success(let outcome):
            banner = Banner(level: .info, title: "无线连接已启用", detail: outcome.message)
            await monitor.refresh()
            await deviceDidChange()
        case .failure(let message):
            banner = Banner(level: .error, title: "启用无线失败", detail: message)
        }
    }

    func reconnectWireless() async {
        await wireless.reconnectRemembered(monitor: monitor)
    }

    // MARK: - 交换 / 工具

    func revealInFinder(_ entry: LocalEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func openLocalEntry(_ entry: LocalEntry) {
        NSWorkspace.shared.open(entry.url)
    }

    var localBreadcrumbs: [(String, URL)] {
        var result: [(String, URL)] = [("/", URL(fileURLWithPath: "/"))]
        var url = URL(fileURLWithPath: "/")
        for component in localDirectory.standardizedFileURL.pathComponents where component != "/" {
            url.appendPathComponent(component)
            result.append((component, url))
        }
        return result
    }

    var remoteBreadcrumbs: [(String, String)] {
        var result: [(String, String)] = []
        var path = remoteDirectory
        while path.count > 1 {
            let name = (path as NSString).lastPathComponent
            result.insert((name.isEmpty ? path : name, path), at: 0)
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { break }
            path = parent
        }
        result.insert(("/", "/"), at: 0)
        return result
    }
}
