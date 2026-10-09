import AppKit
import Foundation
import UniformTypeIdentifiers

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
        await uploadFiles(sources, toRemotePath: destination.path, reason: destination.reason)
    }

    /// 把给定的本地 URL 上传到设备上的指定目录。
    ///
    /// 工具栏按钮（走当前选中项 + 落点分流）与拖拽（走显式落点）共用这一条路径，
    /// 所以落点校验、冲突策略、入队与「记住上次目录」都只有一份实现。
    func uploadFiles(_ urls: [URL], toRemotePath destination: String, reason: String? = nil) async {
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
        guard !urls.isEmpty else { return }
        guard Self.isWritableRemotePath(destination) else {
            banner = Banner(
                level: .warning,
                title: "这个目录不能写入",
                detail: "\(destination) 在 Android 11+ 上禁止写入（PRD §12.2），换一个目录再试"
            )
            return
        }

        let serial = device.serial
        let policy = settings.conflictPolicy

        let expansion = await Task.detached(priority: .userInitiated) {
            TransferPlanner.upload(
                localURLs: urls,
                remoteDirectory: destination,
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
        notes.insert("落点：\(destination)（\(reason ?? "拖拽指定")）", at: 0)
        queue.enqueue(plans: expansion.plans, notes: notes)
        settings.rememberDestination(destination, for: serial)

        if destination != remoteDirectory {
            await navigateRemote(to: destination)
        } else {
            await loadRemote()
        }
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
        guard monitor.activeDevice?.state.isUsable == true else {
            banner = Banner(level: .warning, title: "没有可用的设备", detail: nil)
            return
        }

        let entries = remoteEntries.filter { remoteSelection.contains($0.id) }
        guard !entries.isEmpty else {
            banner = Banner(level: .info, title: "请先选择要下载的项目", detail: "在右侧设备窗格里选中文件或文件夹")
            return
        }

        await downloadEntries(entries, toDirectory: localDirectory)
    }

    /// 把给定的设备端条目下载到 Mac 上的指定目录。
    /// 工具栏按钮与拖拽（拖到 Mac 窗格）共用这一条路径。
    func downloadEntries(_ entries: [RemoteEntry], toDirectory destination: URL) async {
        guard let device = monitor.activeDevice, device.state.isUsable else {
            banner = Banner(level: .warning, title: "没有可用的设备", detail: nil)
            return
        }
        guard let shell = monitor.shell(for: device) else {
            banner = Banner(level: .error, title: "未找到 adb", detail: nil)
            return
        }
        guard !entries.isEmpty else { return }

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

    // MARK: - 拖拽落点

    /// 处理一次窗格落点（PRD §24）。
    ///
    /// `Android/data` 与 `Android/obb` 的禁止反馈由 `uploadFiles` 统一给出；
    /// 同侧拖拽与设备端移动尚未实现，给明确提示而不是静默失败。
    func performDrop(_ payloads: [TransferDragPayload], onto target: Pane) {
        let localPayloads = payloads.filter { $0.side == .local }
        let remotePayloads = payloads.filter { $0.side == .remote }

        switch target {
        case .device:
            let uploadPaths = localPayloads.flatMap(\.paths)
            if !uploadPaths.isEmpty {
                let urls = uploadPaths.map { URL(fileURLWithPath: $0) }
                Task { await uploadFiles(urls, toRemotePath: remoteDirectory) }
            }
            if !remotePayloads.isEmpty {
                banner = Banner(
                    level: .info,
                    title: "设备端移动尚未支持",
                    detail: "把设备文件拖到设备窗格内的移动操作列在后续阶段（改造方案 Phase 4）"
                )
            }

        case .mac:
            let downloadPaths = remotePayloads.flatMap(\.paths)
            if !downloadPaths.isEmpty {
                let entries = downloadPaths.compactMap { path in remoteEntries.first { $0.path == path } }
                Task { await downloadEntries(entries, toDirectory: localDirectory) }
            }
            // 从 Finder 拖入窗口任意位置 = 上传（PRD §12.1）
            let externalPaths = localPayloads.filter { $0.origin == .external }.flatMap(\.paths)
            if !externalPaths.isEmpty {
                let urls = externalPaths.map { URL(fileURLWithPath: $0) }
                Task { await uploadFiles(urls, toRemotePath: remoteDirectory) }
            }
            let samePanePaths = localPayloads.filter { $0.origin == .pane }.flatMap(\.paths)
            if !samePanePaths.isEmpty {
                banner = Banner(
                    level: .info,
                    title: "同一侧不产生传输",
                    detail: "Mac 窗格内部的拖拽是移动操作，尚未支持"
                )
            }
        }
    }

    /// PRD §12.2：`Android/data` 与 `Android/obb` 在 Android 11+ 不可写入，
    /// 因此不在 UI 里暴露。拖拽可以绕过 UI，所以落点必须再校验一次，
    /// 而不是让 adb 传到一半才失败。
    static func isWritableRemotePath(_ path: String) -> Bool {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        let blocked = ["/Android/data", "/Android/obb"]
        return !blocked.contains { normalized.hasSuffix($0) || normalized.contains($0 + "/") }
    }

    // MARK: - 跨栏传输（⌘C / ⌘V，PRD §22）

    /// ⌘C / ⌘V 的路由判定。抽成纯函数，便于单测与后续复用到菜单启用逻辑。
    enum PasteRoute: Equatable, Sendable {
        case upload
        case download
        case unsupported
    }

    static func pasteRoute(from source: TransferDragPayload.Side, to target: Pane) -> PasteRoute {
        switch (source, target) {
        case (.local, .device): .upload
        case (.remote, .mac): .download
        default: .unsupported
        }
    }

    /// 内部剪贴板。与拖拽共用 `TransferDragPayload`，所以两条路径的载荷语义一致。
    private(set) var clipboard: TransferDragPayload?

    var canCopySelection: Bool {
        switch focus {
        case .mac: macSource == .files && !localSelection.isEmpty
        case .device: !remoteSelection.isEmpty
        }
    }

    /// ⌘C。同时把载荷写进通用剪贴板，「粘贴」菜单项据此启用。
    func copySelection() {
        let payload: TransferDragPayload
        switch focus {
        case .mac:
            guard macSource == .files else {
                banner = Banner(
                    level: .info,
                    title: "照片图库暂不支持复制",
                    detail: "请直接把照片拖到设备窗格，或点「上传到设备」"
                )
                return
            }
            let urls = selectedLocalURLs
            guard !urls.isEmpty else { return }
            payload = TransferDragPayload(side: .local, origin: .pane, paths: urls.map(\.path))

        case .device:
            let entries = remoteEntries.filter { remoteSelection.contains($0.id) }
            guard !entries.isEmpty else { return }
            payload = TransferDragPayload(side: .remote, origin: .pane, paths: entries.map(\.path))
        }

        clipboard = payload
        writeToPasteboard(payload)
        banner = Banner(
            level: .info,
            title: "已复制 \(payload.paths.count) 个项目",
            detail: payload.side == .local ? "切到设备窗格后按 ⌘V 上传" : "切到 Mac 窗格后按 ⌘V 下载"
        )
    }

    /// ⌘V。方向由「剪贴板来源 → 当前聚焦窗格」决定。
    func pasteIntoFocus() {
        guard let clipboard else { return }
        switch Self.pasteRoute(from: clipboard.side, to: focus) {
        case .upload:
            let urls = clipboard.paths.map { URL(fileURLWithPath: $0) }
            Task { await uploadFiles(urls, toRemotePath: remoteDirectory) }

        case .download:
            let entries = clipboard.paths.compactMap { path in
                remoteEntries.first { $0.path == path }
            }
            guard !entries.isEmpty else {
                banner = Banner(
                    level: .info,
                    title: "剪贴板里的项目已不在当前目录",
                    detail: "请回到原来的设备目录再粘贴"
                )
                return
            }
            Task { await downloadEntries(entries, toDirectory: localDirectory) }

        case .unsupported:
            banner = Banner(
                level: .info,
                title: "同一侧不产生传输",
                detail: "Mac 栏内部的 ⌘C/⌘V 是复制、设备栏内部是移动，两者都尚未支持"
            )
        }
    }

    func selectAllInFocusedPane() {
        switch (focus, macSource) {
        case (.mac, .files): localSelection = Set(localEntries.map(\.id))
        case (.mac, .photos): photoSelection = Set(photos.items.map(\.id))
        case (.device, _): remoteSelection = Set(remoteEntries.map(\.id))
        }
    }

    func showCutUnsupported() {
        banner = Banner(
            level: .info,
            title: "剪切尚未支持",
            detail: "剪切需要「移动」语义，设备端移动列在后续阶段（改造方案 Phase 4）"
        )
    }

    private func writeToPasteboard(_ payload: TransferDragPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(
            data,
            forType: NSPasteboard.PasteboardType(UTType.droidBerthTransfer.identifier)
        )
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

    // MARK: - 聚焦与键盘导航

    /// Tab 在窗格之间循环。
    ///
    /// PRD §22 要求的是「Mac 窗格 → 设备窗格 → 传输面板」三段循环，但传输面板
    /// 目前还没有键盘可交互的内容，把焦点移进去是无意义的。三段循环留到
    /// Phase 2.3（传输面板改造）时补齐。
    func cycleFocus(backwards: Bool = false) {
        focus = focus == .mac ? .device : .mac
    }

    var canGoBack: Bool {
        switch focus {
        case .mac: canGoLocalBack
        case .device: canGoRemoteBack
        }
    }

    var canGoForward: Bool {
        switch focus {
        case .mac: canGoLocalForward
        case .device: canGoRemoteForward
        }
    }

    func goBack() {
        switch focus {
        case .mac: localGoBack()
        case .device: Task { await remoteGoBack() }
        }
    }

    func goForward() {
        switch focus {
        case .mac: localGoForward()
        case .device: Task { await remoteGoForward() }
        }
    }

    func goUp() {
        switch focus {
        case .mac: localGoUp()
        case .device: Task { await remoteGoUp() }
        }
    }

    func refreshFocusedPane() {
        switch focus {
        case .mac:
            if macSource == .files {
                reloadLocal()
            } else {
                Task { await photos.loadItems() }
            }
        case .device:
            Task { await loadRemote() }
        }
    }

    /// ⌘⌫ 目前只作用于设备端。Mac 端的删除要走 Finder 的「移到废纸篓」语义，
    /// 涉及不可逆风险，不在 Phase 1 范围内（见改造方案 Phase 4）。
    var canDeleteSelection: Bool {
        focus == .device && !remoteSelection.isEmpty && activeDevice != nil
    }
}
