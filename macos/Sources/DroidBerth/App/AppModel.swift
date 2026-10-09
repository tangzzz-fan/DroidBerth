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

    /// 需要用户确认才能预览的远端文件（PRD §23 的大文件保护）。
    struct PendingPreview: Identifiable, Sendable {
        let id = UUID()
        let entry: RemoteEntry
    }

    /// 预览的体量上限：超过它先问一句，不要静默开始下载。
    static let previewSizeLimit: Int64 = 200 * 1024 * 1024

    let settings = AppSettings.shared
    let monitor = DeviceMonitor()
    let wireless = WirelessManager()
    let photos = PhotoLibraryModel()
    let queue = TransferQueue()
    /// 网格视图的缩略图缓存（PRD §13.3）。
    let thumbnails = ThumbnailStore()

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

    /// 分栏视图「当前所在目录」，只服务窗格底部的路径栏（PRD §13.2）。
    ///
    /// 刻意与 `localDirectory` / `remoteDirectory` 分开：那两个是列表 / 网格显示的目录，
    /// 同时也是列视图的**根**。列里点文件夹只更新这两个 `…ColumnDirectory`，不动根 ——
    /// 否则根一变，列视图每点一下就整体回到第一列。
    var localColumnDirectory = ""
    var remoteColumnDirectory = ""

    var photoSelection: Set<String> = []

    var showHiddenFiles = false
    var banner: Banner?
    var exportPhase: ExportPhase = .idle

    /// 绑定给 `.quickLookPreview(_:)`：非 nil 时系统弹出就地预览面板。
    var previewURL: URL?
    /// 正在把远端文件拉到本机。拉取期间再按空格不重复发起。
    var previewLoading = false
    /// 超过 `previewSizeLimit` 的远端文件，等用户确认后再下载（PRD §23）。
    var pendingPreview: PendingPreview?

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
        AppPaths.clearPreviews()
        AppPaths.clearThumbnails()
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
        // 列视图的根与「列里点到了哪」分开记：前者是 localDirectory，后者是这个。
        localColumnDirectory = url.path
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
        // 同 navigateRemote：换目录清筛选，刷新保留。
        clearSearch()
        reloadLocal()
        settings.rememberLocalFolder(url.path)
    }

    func reloadLocal() {
        switch LocalFileSystem.list(localDirectory, showHidden: showHiddenFiles) {
        case .success(let entries):
            // 这里排的是「列表的基准顺序」——入队顺序、多选遍历都依赖它稳定。
            // 展示层的列头排序由 `EntryTable` 负责，两者互不干扰。
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
        // 筛选只作用于「当前这个文件夹」：换了目录就清掉，避免出现
        // 「明明有文件却显示空」的困惑。刷新（reload）不清，保留筛选。
        clearSearch()
        await loadRemote()
    }

    func loadRemote() async {
        guard let device = monitor.activeDevice else {
            remoteEntries = []
            remoteError = nil
            remoteAvailableBytes = nil
            thumbnails.updateDevice(shell: nil, serial: nil)
            return
        }
        guard let shell = monitor.shell(for: device) else {
            remoteEntries = []
            remoteError = "未找到可用的 adb 可执行文件"
            return
        }

        // 缩略图要先知道「往哪台设备、用什么 adb 取头」。换设备时 store 会自行清空缓存。
        thumbnails.updateDevice(shell: shell, serial: device.serial)

        // 列视图的根跟着窗格目录走；列内点选只改 remoteColumnDirectory，不改这里。
        remoteColumnDirectory = remoteDirectory

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
    /// 设备端的同侧拖拽＝移动（Phase 4 已接上），Mac 端的同侧拖拽仍只给提示 ——
    /// 本地文件的移动交给 Finder，本产品不做。
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
                // 设备窗格内的拖拽 = 设备端移动（PRD §24）。
                let movePaths = remotePayloads.flatMap(\.paths)
                Task { await moveRemotePaths(movePaths, toDirectory: remoteDirectory) }
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
                    detail: "Mac 窗格内部的移动交给 Finder，本产品不做"
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
        /// ⌘X 剪切的设备端条目，粘回设备窗格 = 移动（PRD §22）。
        case move
        case unsupported
    }

    static func pasteRoute(
        from source: TransferDragPayload.Side,
        to target: Pane,
        isCut: Bool = false
    ) -> PasteRoute {
        switch (source, target) {
        case (.local, .device): .upload
        case (.remote, .mac): .download
        // 只有「剪切」才在设备端内部产生移动；普通拷贝的设备端内部粘贴没有定义。
        case (.remote, .device) where isCut: .move
        default: .unsupported
        }
    }

    /// 内部剪贴板。与拖拽共用 `TransferDragPayload`，所以两条路径的载荷语义一致。
    private(set) var clipboard: TransferDragPayload?
    /// 剪贴板里那一份是「剪切」还是「拷贝」。剪切 = 移动语义。
    private(set) var clipboardIsCut = false

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
        clipboardIsCut = false
        writeToPasteboard(payload)
        banner = Banner(
            level: .info,
            title: "已复制 \(payload.paths.count) 个项目",
            detail: payload.side == .local ? "切到设备窗格后按 ⌘V 上传" : "切到 Mac 窗格后按 ⌘V 下载"
        )
    }

    /// ⌘X。本产品里「剪切」只对**设备端**有定义 —— Mac 端的移动是 Finder 的事，
    /// 在双栏工具里给本地文件做剪切会绕过 Finder 的废纸篓语义，不做。
    func cutSelection() {
        guard focus == .device else {
            banner = Banner(
                level: .info,
                title: "Mac 端的移动交给 Finder",
                detail: "这里的「剪切」只作用于设备窗格：切到设备窗格按 ⌘X，换到目标目录再按 ⌘V"
            )
            return
        }
        let entries = remoteEntries.filter { remoteSelection.contains($0.id) }
        guard !entries.isEmpty else {
            banner = Banner(level: .info, title: "请先选择要移动的项目", detail: "在设备窗格里选中文件或文件夹")
            return
        }
        let payload = TransferDragPayload(side: .remote, origin: .pane, paths: entries.map(\.path))
        clipboard = payload
        clipboardIsCut = true
        writeToPasteboard(payload)
        banner = Banner(
            level: .info,
            title: "已剪切 \(payload.paths.count) 个项目",
            detail: "换到目标目录后按 ⌘V 移动"
        )
    }

    /// ⌘V。方向由「剪贴板来源 → 当前聚焦窗格」决定。
    func pasteIntoFocus() {
        guard let clipboard else { return }
        switch Self.pasteRoute(from: clipboard.side, to: focus, isCut: clipboardIsCut) {
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

        case .move:
            Task { await moveRemotePaths(clipboard.paths, toDirectory: remoteDirectory) }

        case .unsupported:
            banner = Banner(
                level: .info,
                title: "同一侧不产生传输",
                detail: "设备栏内部的 ⌘C/⌘V 是复制，尚未支持；要移动请用 ⌘X 剪切"
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

    private func writeToPasteboard(_ payload: TransferDragPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(
            data,
            forType: NSPasteboard.PasteboardType(UTType.droidBerthTransfer.identifier)
        )
    }

    // MARK: - 搜索（PRD §10 / §13.1）

    var searchQuery = ""

    /// 查询作用于哪个窗格。
    ///
    /// 刻意**不**跟随焦点实时变化：那样 Tab 一下结果就会跳，用户会以为丢了东西。
    /// 只在「查询被编辑」的那一刻锁定到当时的聚焦窗格——编辑是明确动作，跳变可预期。
    private(set) var searchScope: Pane = .mac

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespaces)
    }

    var isSearching: Bool { !trimmedQuery.isEmpty }

    var searchScopeIsMac: Bool { searchScope == .mac }

    func setSearchQuery(_ value: String) {
        searchQuery = value
        searchScope = focus
    }

    func clearSearch() {
        searchQuery = ""
    }

    /// 展示用列表。选择态、上传下载仍以完整列表为准，过滤只影响看得见的东西。
    var visibleLocalEntries: [LocalEntry] {
        guard isSearching, searchScopeIsMac else { return localEntries }
        return localEntries.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    var visibleRemoteEntries: [RemoteEntry] {
        guard isSearching, !searchScopeIsMac else { return remoteEntries }
        return remoteEntries.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    /// 被筛掉的条目数，用来在状态栏里说明「不是文件夹空了，是被过滤了」。
    func hiddenBySearchCount(in pane: Pane) -> Int {
        guard isSearching, searchScope == pane else { return 0 }
        switch pane {
        case .mac: return max(localEntries.count - visibleLocalEntries.count, 0)
        case .device: return max(remoteEntries.count - visibleRemoteEntries.count, 0)
        }
    }

    /// 搜索框的占位文案：把「作用于哪个窗格」写在明面上（PRD §10 要求作用于聚焦窗格）。
    var searchPrompt: String {
        switch focus {
        case .mac: "搜索「\(macSource == .files ? "这台 Mac" : "照片图库")」"
        case .device: "搜索「\(activeDevice?.displayName ?? "Android 设备")」"
        }
    }

    // MARK: - Quick Look 预览（PRD §23）

    /// 有且仅有一个可预览的选中项。
    ///
    /// 多选时不给预览：面板一次只呈现一个文件，硬挑第一个会让人误以为其它
    /// 选中项也进了预览。此时把空格还给系统（见 `PaneKeyMonitor`）。
    var canQuickLook: Bool {
        switch (focus, macSource) {
        case (.mac, .files): localSelection.count == 1
        case (.mac, .photos): photoSelection.count == 1
        case (.device, _): remoteSelection.count == 1
        }
    }

    /// 空格键入口。返回值语义与 `PaneKeyMonitor.onQuickLook` 一致：
    /// true = 已消费（无论成功还是给了明确反馈），false = 交还系统。
    @discardableResult
    func quickLookFocusedSelection() -> Bool {
        switch (focus, macSource) {
        case (.mac, .files):
            let picked = localEntries.filter { localSelection.contains($0.id) }
            guard picked.count == 1, let entry = picked.first else { return false }
            previewURL = entry.url
            return true

        case (.mac, .photos):
            guard photoSelection.count == 1 else { return false }
            banner = Banner(
                level: .info,
                title: "照片图库暂不支持快速查看",
                detail: "图库条目要先导出成文件才能预览；现在可以双击打开"
            )
            return true

        case (.device, _):
            let picked = remoteEntries.filter { remoteSelection.contains($0.id) }
            guard picked.count == 1, let entry = picked.first else { return false }
            guard !entry.isDirectory else {
                banner = Banner(
                    level: .info,
                    title: "文件夹不支持预览",
                    detail: "\(entry.name) 是文件夹，预览需要单个文件"
                )
                return true
            }
            if let size = entry.size, size > Self.previewSizeLimit {
                pendingPreview = PendingPreview(entry: entry)
                return true
            }
            Task { await pullForPreview(entry) }
            return true
        }
    }

    /// 远端文件没法就地预览：先落到 `$TMPDIR/DroidBerth/preview/` 再交给 Quick Look。
    ///
    /// 与正式下载刻意走两条路：预览不需要进度条、不进传输面板、落地即弃，用一次
    /// `adb pull` 就够；塞进 `TransferQueue` 反而会在面板里留下一次性任务。
    func pullForPreview(_ entry: RemoteEntry) async {
        guard !previewLoading else { return }
        guard let device = monitor.activeDevice, device.state.isUsable else {
            banner = Banner(level: .warning, title: "没有可用的设备", detail: nil)
            return
        }

        previewLoading = true
        defer { previewLoading = false }

        // 面板开着时不清理：正在显示的文件就躺在预览目录里，删掉会让面板报错。
        // 面板已关（常见情况）时顺手清掉上一轮残留，避免临时目录在一次会话里堆积。
        if previewURL == nil { AppPaths.clearPreviews() }
        let target = AppPaths.makePreviewItem(named: entry.name)
        let serial = device.serial
        let remotePath = entry.path
        let binary = ADBBinary.shared

        banner = Banner(
            level: .info,
            title: "正在准备预览…",
            detail: "先把 \(entry.name)（\(ByteFormat.size(entry.size))）下载到本机"
        )

        let outcome = await Task.detached(priority: .userInitiated) { () -> PreviewPullOutcome in
            // 定位 adb 要跑 sidecar，放到主线程外，免得按空格时界面卡一下
            guard let adb = binary.path else { return .missingADB }
            let result = ProcessRunner.run(
                adb,
                ["-s", serial, "pull", remotePath, target.path],
                timeout: 300
            )
            guard result.ok else { return .failed(Self.describe(result)) }
            return .success
        }.value

        switch outcome {
        case .success:
            banner = nil
            previewURL = target
        case .missingADB:
            banner = Banner(level: .error, title: "未找到 adb", detail: "请重新构建 app")
        case .failed(let message):
            banner = Banner(level: .error, title: "预览前下载失败", detail: message)
        }
    }

    func confirmPendingPreview() {
        guard let pending = pendingPreview else { return }
        pendingPreview = nil
        Task { await pullForPreview(pending.entry) }
    }

    func cancelPendingPreview() {
        pendingPreview = nil
    }

    /// 把 `adb pull` 的输出压成一句人话。进度行（`[ 45%]`）没有信息量，丢掉。
    private nonisolated static func describe(_ result: ProcessResult) -> String {
        if let spawnError = result.spawnError { return spawnError }
        if result.timedOut { return "下载超时（超过 5 分钟）" }
        let lines = (result.stdout + "\n" + result.stderr)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
        guard let last = lines.last else {
            return "adb 退出码 \(result.exitCode.map(String.init) ?? "nil")"
        }
        return last
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
        await deleteRemoteEntries(entries)
    }

    /// 删除给定的设备端条目。
    ///
    /// 抽成「显式目标」版本，是因为网格视图的右键菜单无法依赖系统帮忙选中
    /// （`LazyVGrid` 没有 `contextMenu(forSelectionType:)`），必须能对右键的那一项
    /// 直接动作，见 `EntryGrid.menu(for:)`。
    func deleteRemoteEntries(_ entries: [RemoteEntry]) async {
        guard !entries.isEmpty else { return }
        guard let device = monitor.activeDevice, let shell = monitor.shell(for: device) else { return }

        let paths = entries.map(\.path)
        let result = await Task.detached(priority: .userInitiated) { shell.remove(paths) }.value
        if result.ok {
            remoteSelection.subtract(paths)
            await loadRemote()
        } else {
            banner = Banner(level: .error, title: "删除失败", detail: result.failureMessage)
        }
    }

    // MARK: - 设备端重命名 / 移动（PRD §13.1 右键、§24 窗格内拖拽）

    /// 设备端名称校验。抽成纯函数：校验规则要能被单测钉住，而且 UI 侧想在提交前
    /// 实时禁用「确定」也要用它。
    static func validateRemoteName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "名称不能为空" }
        if name == "." || name == ".." { return "「\(name)」不是合法的名称" }
        if name.contains("/") { return "名称不能包含「/」" }
        if name.count > 255 { return "名称过长（最多 255 个字符）" }
        return nil
    }

    func renameRemoteEntry(_ entry: RemoteEntry, to rawName: String) async {
        if let problem = Self.validateRemoteName(rawName) {
            banner = Banner(level: .error, title: "名称不合法", detail: problem)
            return
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != entry.name else { return }

        let parent = (entry.path as NSString).deletingLastPathComponent
        let destination = parent.hasSuffix("/") ? parent + name : parent + "/" + name

        // 冲突预检：同目录已有同名就拒绝。`mv` 默认会静默覆盖，而覆盖一个手机上的
        // 文件是不可逆的 —— 宁可让用户换个名字。列表本来就在手上，不额外开销。
        if remoteEntries.contains(where: { $0.path == destination }) {
            banner = Banner(level: .error, title: "已有同名项目", detail: "「\(name)」已存在，换一个名称再试")
            return
        }

        guard let device = monitor.activeDevice, let shell = monitor.shell(for: device) else {
            banner = Banner(level: .error, title: "未找到 adb", detail: nil)
            return
        }

        let result = await Task.detached(priority: .userInitiated) {
            shell.move(entry.path, to: destination)
        }.value

        guard result.ok else {
            banner = Banner(level: .error, title: "重命名失败", detail: result.failureMessage)
            return
        }

        // 改的若是「当前目录」本身，窗格路径与历史都要跟着走，否则会停在一个不存在的路径上。
        if remoteDirectory == entry.path {
            remoteDirectory = destination
            remoteHistory = remoteHistory.map { $0 == entry.path ? destination : $0 }
        }
        remoteSelection = [destination]
        await loadRemote()
    }

    /// 设备端移动（PRD §24：把设备文件拖到设备窗格内）。
    ///
    /// 入口收 `path` 而不是 `RemoteEntry`：⌘X 剪切后用户会先切到目标目录，此时源条目
    /// 已经不在 `remoteEntries` 里了，只有路径还留着。
    func moveRemotePaths(_ paths: [String], toDirectory destination: String) async {
        guard !paths.isEmpty else { return }
        let target = Self.normalizedDirectory(destination)

        // 已经在目标目录里的不动 —— 否则「把文件拖到它自己所在窗格」会变成一个假的成功。
        let pending = paths.filter { Self.parentDirectory(of: $0) != target }
        guard !pending.isEmpty else {
            banner = Banner(level: .info, title: "没有需要移动的项目", detail: "它们已经在 \(target) 里了")
            return
        }

        // 不能把目录移进它自己或它的子目录。
        let recursive = pending.filter { target == $0 || target.hasPrefix($0 + "/") }
        guard recursive.isEmpty else {
            banner = Banner(
                level: .error,
                title: "不能移动到自身内部",
                detail: recursive.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
            )
            return
        }

        guard let device = monitor.activeDevice, let shell = monitor.shell(for: device) else {
            banner = Banner(level: .error, title: "未找到 adb", detail: nil)
            return
        }

        // 冲突预检：目标目录里已有同名 → **整批拒绝**。与重命名同一条理由：
        // `mv` 的默认行为是静默覆盖，而这里覆盖的是用户手机上的数据。
        let names = pending.map { ($0 as NSString).lastPathComponent }
        let conflicts = await Task.detached(priority: .userInitiated) { () -> [String] in
            guard case .success(let listed) = shell.list(target) else { return [] }
            let existing = Set(listed.map(\.name))
            return names.filter { existing.contains($0) }
        }.value

        guard conflicts.isEmpty else {
            banner = Banner(
                level: .error,
                title: "目标目录已有同名项目",
                detail: "\(conflicts.joined(separator: "、"))。为避免覆盖，本次一个都没有移动"
            )
            return
        }

        let result = await Task.detached(priority: .userInitiated) {
            shell.move(pending, intoDirectory: target)
        }.value

        guard result.ok else {
            banner = Banner(level: .error, title: "移动失败", detail: result.failureMessage)
            return
        }

        // 剪切粘贴完成后撤销剪切态，与 Finder 一致（剪切是一次性的意图）。
        if clipboardIsCut { clipboardIsCut = false }
        remoteSelection = []
        await loadRemote()
        banner = Banner(level: .info, title: "已移动 \(pending.count) 个项目", detail: "→ \(target)")
    }

    func moveRemoteEntries(_ entries: [RemoteEntry], toDirectory destination: String) async {
        await moveRemotePaths(entries.map(\.path), toDirectory: destination)
    }

    static func parentDirectory(of path: String) -> String {
        normalizedDirectory((path as NSString).deletingLastPathComponent)
    }

    /// 去掉尾部斜杠（根目录除外），便于用 `==` 比较两个目录。
    private static func normalizedDirectory(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
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

    /// 设备菜单 →「断开连接」。
    ///
    /// 只有无线连接能在 app 内断开（`adb disconnect`）。USB 没有对应的「软断开」——
    /// 拔线才是断开。这里如实说明，不假装做了一个其实什么也没做的动作。
    func disconnectDevice() async {
        guard let device = monitor.activeDevice else {
            banner = Banner(level: .info, title: "没有可用的设备", detail: nil)
            return
        }
        guard device.isWireless else {
            banner = Banner(
                level: .info,
                title: "USB 连接无法在 app 内断开",
                detail: "直接拔掉数据线即可。只有无线连接的设备能在这里断开"
            )
            return
        }

        await wireless.disconnect(address: device.serial)
        monitor.selectedSerial = nil
        await monitor.refresh()
        await deviceDidChange()
        banner = Banner(level: .info, title: "已断开无线连接", detail: device.serial)
    }

    /// 设备菜单 →「设备信息」。
    ///
    /// 走既有的 banner 而不是新开一个面板：信息是**一次性**的，而弹窗是一个需要
    /// 占位的界面承诺（关掉之后那块区域还得处理）。等真有常驻信息面板的需求再说。
    func showDeviceInfo() async {
        guard let device = monitor.activeDevice, let shell = monitor.shell(for: device) else {
            banner = Banner(level: .info, title: "没有可用的设备", detail: nil)
            return
        }

        let version = device.displayName
        let serial = device.serial
        let connection = device.connectionLabel

        let lines = await Task.detached(priority: .userInitiated) { () -> [String] in
            var result = ["型号：\(version)", "序列号：\(serial)", "连接：\(connection)"]
            let android = shell.androidVersion()
            if let release = android.release {
                let sdk = android.sdk.map(String.init) ?? "—"
                result.append("Android \(release)（API \(sdk)）")
            }
            if let bytes = shell.availableBytes(at: "/sdcard") {
                result.append("可用空间：\(ByteFormat.size(bytes))")
            }
            return result
        }.value

        banner = Banner(level: .info, title: "设备信息", detail: lines.joined(separator: "\n"))
    }

    // MARK: - 交换 / 工具

    func revealInFinder(_ entry: LocalEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func openLocalEntry(_ entry: LocalEntry) {
        NSWorkspace.shared.open(entry.url)
    }

    var localBreadcrumbs: [(String, URL)] {
        Self.localBreadcrumbs(for: localDirectory)
    }

    var remoteBreadcrumbs: [(String, String)] {
        Self.remoteBreadcrumbs(for: remoteDirectory)
    }

    // MARK: - 窗格布局（PRD §10「交换两侧」）

    /// 左右窗格是否互换。
    ///
    /// **读法说明**：PRD §10 写的是「把两个窗格的**位置**互换」。本地路径与设备路径
    /// 不可能互相赋值，所以「位置」只能读作**窗格在窗口里的摆放位置** —— 这也正是
    /// 双栏文件管理器的经典语义（Total Commander 的 Ctrl+U「交换面板」）。
    /// 「目录路径互换」在本地 ↔ 远端之间没有定义，不实现。
    ///
    /// 存进设置而不是只放在内存：这是明确的布局偏好，每次启动都要重按一次会很烦。
    var panesSwapped: Bool {
        get { settings.panesSwapped }
        set { settings.panesSwapped = newValue }
    }

    var leftPane: Pane { panesSwapped ? .device : .mac }
    var rightPane: Pane { panesSwapped ? .mac : .device }

    func swapPanes() {
        panesSwapped.toggle()
    }

    // MARK: - 浏览形态（PRD §13）

    /// 视图形态**按窗格独立**（PRD §13「两侧各自支持列表/网格视图」）。
    ///
    /// 存进设置而不是内存：这是明确的浏览偏好，每次启动都要重选一遍会很烦。
    func viewMode(for pane: Pane) -> ViewMode {
        pane == .mac ? settings.macViewMode : settings.deviceViewMode
    }

    func setViewMode(_ mode: ViewMode, for pane: Pane) {
        switch pane {
        case .mac: settings.macViewMode = mode
        case .device: settings.deviceViewMode = mode
        }
    }

    /// 工具栏分段控件绑的是**聚焦窗格**的形态（PRD §10）。
    var focusedViewMode: ViewMode {
        get { viewMode(for: focus) }
        set { setViewMode(newValue, for: focus) }
    }

    /// ⌘+ / ⌘- （PRD §13.3）。尺寸是全局偏好 —— 两栏用同一个图标大小才不显得碎。
    func enlargeGridIcons() { settings.adjustGridIconSize(by: AppSettings.gridIconSizeStep) }
    func shrinkGridIcons() { settings.adjustGridIconSize(by: -AppSettings.gridIconSizeStep) }
    var canEnlargeGridIcons: Bool { settings.canEnlargeGridIcons }
    var canShrinkGridIcons: Bool { settings.canShrinkGridIcons }

    // MARK: - 分栏视图（PRD §13.2）

    /// 取某个目录的子项，供分栏视图按需加载。
    ///
    /// 返回 `BrowserEntry` 而不是各自的类型：列视图两侧共用一套实现，路径语义
    /// （`id == path`）也与列表 / 网格一致，所以选择态、上传下载、Quick Look 都不用改。
    ///
    /// 本地是同步的文件系统调用；设备端要走一次 `adb shell ls` 子进程，**必须留在
    /// 主线外** —— 分栏视图的 delegate 是同步接口，那条路径见 `EntryColumns` 的说明。
    func browserChildren(path: String, origin: BrowserEntry.Origin) async -> [BrowserEntry] {
        switch origin {
        case .local:
            guard case .success(let entries) = LocalFileSystem.list(
                URL(fileURLWithPath: path),
                showHidden: showHiddenFiles
            ) else { return [] }
            return entries.sorted(by: Self.localSort).map(\.asBrowserEntry)

        case .remote:
            guard let device = monitor.activeDevice,
                  let shell = monitor.shell(for: device) else { return [] }
            let listed = await Task.detached(priority: .userInitiated) { () -> [RemoteEntry] in
                switch shell.list(path) {
                case .success(let entries): return entries
                case .failure: return []
                }
            }.value
            return listed.sorted(by: Self.remoteSort).map(BrowserEntry.init(remote:))

        case .photo:
            // 照片图库没有目录层级，列视图对它没有意义（照片窗格会回退成列表）。
            return []
        }
    }

    /// 在分栏视图里双击一个设备端文件 = 预览。
    ///
    /// 不能复用 `quickLookFocusedSelection`：那条路径靠 `remoteEntries` 反查，而列视图
    /// 选中的文件可能位于**子目录**里，根本不在当前 `remoteEntries` 中。这里直接由
    /// `BrowserEntry` 还原出 `RemoteEntry`。
    func previewRemote(_ entry: RemoteEntry) {
        guard !entry.isDirectory else { return }
        focus = .device
        remoteSelection = [entry.id]
        if let size = entry.size, size > Self.previewSizeLimit {
            pendingPreview = PendingPreview(entry: entry)
        } else {
            Task { await pullForPreview(entry) }
        }
    }

    /// 任意目录的面包屑。列表 / 网格用的是「当前目录」，分栏用的是「列里点到的目录」。
    static func localBreadcrumbs(for directory: URL) -> [(String, URL)] {
        var result: [(String, URL)] = [("/", URL(fileURLWithPath: "/"))]
        var url = URL(fileURLWithPath: "/")
        for component in directory.standardizedFileURL.pathComponents where component != "/" {
            url.appendPathComponent(component)
            result.append((component, url))
        }
        return result
    }

    static func remoteBreadcrumbs(for directory: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var path = directory
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

    /// ⌘⌥← / ⌘⌥→ 按**视觉位置**聚焦，而不是按 Mac / 设备 —— 交换之后不能反直觉。
    func focusLeftPane() { focus = leftPane }
    func focusRightPane() { focus = rightPane }

    /// 最近打开过的 Mac 文件夹（已过滤掉已被删除 / 移走的）。
    var recentLocalFolders: [URL] {
        settings.recentLocalFolders
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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
    /// 涉及不可逆风险，**明确不做** —— 本地文件的删除交给 Finder。
    var canDeleteSelection: Bool {
        focus == .device && !remoteSelection.isEmpty && activeDevice != nil
    }
}

/// `pullForPreview` 在主线外跑 `adb pull` 的结果。
///
/// 声明在文件作用域而不是 `AppModel` 里：它要穿过 `Task.detached` 的
/// `@Sendable` 边界，放在 `@MainActor` 类型内部容易连带继承隔离。
private enum PreviewPullOutcome: Sendable {
    case success
    case missingADB
    case failed(String)
}
