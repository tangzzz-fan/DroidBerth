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

    /// 本地窗格的**授权状态**（E7）。
    ///
    /// 类型定义在 `Support/LocalPlacePolicy.swift` —— 与「某个位置能不能用」放在一起，
    /// 因为两者是同一件事的两个层次（个体 / 全局），而且那里能被守卫直接编译到。
    /// 判定逻辑是同文件的 `FolderAccess.state(...)`。

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

        /// **每条提示都进日志** —— 有意放在 `init` 里。
        ///
        /// `banner = Banner(...)` 在全仓有几十处，散在传输 / 设备 / 文件操作各条路径上。
        /// 逐个补日志调用一定会漏，而漏掉的那一条恰好就是下次要查的那条。
        /// 提示是「用户已经被告知的事」，日志必须能对得上 —— 否则用户说「它刚才报错了」，
        /// 而日志里什么都没有。
        ///
        /// 副作用放在 `init` 里通常不是好味道，这里是刻意的取舍：可漏性 > 纯净性。
        init(level: Level, title: String, detail: String? = nil) {
            self.level = level
            self.title = title
            self.detail = detail
            let message = title + (detail.map { " · \($0)" } ?? "")
            switch level {
            case .info: AppLog.info("提示：\(message)", .ui)
            case .warning: AppLog.warning("警告：\(message)", .ui)
            case .error: AppLog.error("错误：\(message)", .ui)
            }
        }
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

    var localDirectory: URL = AppPaths.defaultLocalStartDirectory
    private(set) var localEntries: [LocalEntry] = []
    var localSelection: Set<String> = []
    private(set) var localHistory: [URL] = []
    private(set) var localHistoryIndex = -1
    var localError: String?

    /// 有书签的目录。**两侧共用同一条列表**是刻意的：
    /// 沙盒下只有它能带用户到容器外的任意目录（它是授权的载体），而侧载版顺带得到
    /// 「最近使用」。旧的那套 `settings.recentLocalFolders` 存的是**路径** ——
    /// 在沙盒里根本读不了，留着就是同一概念的两套实现。已删。
    private(set) var bookmarkedFolders: [BookmarkedFolder] = []
    /// 本地窗格的授权状态。见 `LocalAccess`。
    private(set) var localAccess: LocalAccess = .notRequired
    /// 当前 `start` 着的授权目录。security-scoped 访问**必须成对**（`start` / `stop`），
    /// 所以由模型独占持有 —— 每个导航点各 start 一次必然泄漏。
    private var activeScope: URL?

    var remoteDirectory = "/sdcard"
    private(set) var remoteEntries: [RemoteEntry] = []
    var remoteSelection: Set<String> = []
    private(set) var remoteHistory: [String] = []
    private(set) var remoteHistoryIndex = -1
    var remoteError: String?
    var remoteLoading = false
    var remoteAvailableBytes: Int64?

    /// 设备上可浏览的存储卷（PRD §12.2）。按 serial 缓存一次，换设备时重取。
    private(set) var deviceVolumes: [DeviceShell.StorageVolume] = [DeviceShell.internalVolume]
    private var volumesLoadedForSerial: String?

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

    /// 正在把远端文件拉到本机。拉取期间再按空格不重复发起。
    var previewLoading = false
    /// 超过 `previewSizeLimit` 的远端文件，等用户确认后再下载（PRD §23）。
    var pendingPreview: PendingPreview?

    /// 设备窗格当前所在的存储卷。路径落在哪个卷的子树里就是哪个卷。
    ///
    /// 与「常用文件夹」配套：`/sdcard/DCIM` 和 `/storage/XXXX-XXXX/DCIM` 是两个不同的
    /// 目录，快捷位置必须跟着当前卷走，否则在 SD 卡上点「DCIM」会跳回内部存储。
    var currentDeviceVolume: DeviceShell.StorageVolume {
        let path = remoteDirectory
        return deviceVolumes.first { volume in
            volume.isRemovable && (path == volume.path || path.hasPrefix(volume.path + "/"))
        } ?? DeviceShell.internalVolume
    }

    var deviceQuickLocations: [(String, String)] {
        let root = currentDeviceVolume.path
        return ["DCIM", "Movies", "Pictures", "Download"].map { ($0, root + "/" + $0) }
    }

    /// 取一次设备上的存储卷。刻意按 serial 只在换设备时取：它要跑一次 `adb shell ls`，
    /// 而每次目录跳转都取等于给浏览加一次无谓的子进程。
    func refreshDeviceVolumes() async {
        guard let device = monitor.activeDevice, let shell = monitor.shell(for: device) else {
            deviceVolumes = [DeviceShell.internalVolume]
            volumesLoadedForSerial = nil
            return
        }
        guard volumesLoadedForSerial != device.serial else { return }

        let volumes = await Task.detached(priority: .utility) { shell.storageVolumes() }.value
        // 期间可能已经换了设备，写回去只会污染新设备的状态。
        guard monitor.activeDevice?.serial == device.serial else { return }
        deviceVolumes = volumes
        volumesLoadedForSerial = device.serial
    }

    /// 远端隐藏项的过滤（PRD §10「显示隐藏文件」）。
    ///
    /// 三条判据：
    /// 1. **判据是「名字以点开头」**。Android 文件系统没有 macOS 的 `UF_HIDDEN` 标志，
    ///    点前缀是唯一可用的判据（`.nomedia` / `.thumbnails` / `.trash` / `.pending`）。
    /// 2. **刻意不下沉到 `DeviceShell.list`**。`TransferPlanner` 用同一份列表做重名冲突
    ///    检测，而隐藏文件在设备上确实存在、确实会撞名 —— 把过滤放在那儿会让冲突检测失明。
    ///    过滤只属于**呈现层**。
    /// 3. 列表、网格、分栏三种视图共用这一个入口，否则三种视图对同一个开关会给出不同结果。
    static func filterHidden(_ entries: [RemoteEntry], showHidden: Bool) -> [RemoteEntry] {
        guard !showHidden else { return entries }
        return entries.filter { !$0.name.hasPrefix(".") }
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
        // Finder 的「服务 → 发送到 DroidBerth」可能在 App 启动**之前**就被点了 ——
        // 系统会把 App 拉起来，而那些请求此刻已经到达，所以在 provider 里排队，装 handler 时补投。
        FinderServiceProvider.shared.install { [weak self] urls in
            self?.handleFinderService(urls)
        }
        monitor.start()
        // 先读回书签、定授权状态 —— 它决定下面该落在哪，以及列表要不要真的去列。
        let resolution = refreshBookmarkedFolders()
        navigateLocal(to: restoredStartDirectory(from: resolution), resetHistory: true)
        Task { await bootstrapRemote() }
    }

    private func bootstrapRemote() async {
        try? await Task.sleep(for: .seconds(1))
        if let device = monitor.activeDevice, let remembered = settings.destination(for: device.serial) {
            remoteDirectory = remembered
        }
        await refreshDeviceVolumes()
        fallBackToInternalVolumeIfNeeded()
        await loadRemote()
    }

    func deviceDidChange() async {
        if let device = monitor.activeDevice, let remembered = settings.destination(for: device.serial) {
            remoteDirectory = remembered
        }
        remoteHistory = []
        remoteHistoryIndex = -1
        await refreshDeviceVolumes()
        fallBackToInternalVolumeIfNeeded()
        await loadRemote()
    }

    /// 记住的目标目录可能在外置卷上，而那块卡已经拔了。落到不存在的路径上会让设备窗格
    /// 直接报错 —— 回到内部存储，比在错误信息里解释「卷不在了」有用。
    private func fallBackToInternalVolumeIfNeeded() {
        guard isOnUnmountedVolume(remoteDirectory) else { return }
        remoteDirectory = DeviceShell.internalVolume.path
    }

    /// 设备窗格是不是停在某个存储卷的**根**上（还没进具体目录）。
    private var isAtDeviceVolumeRoot: Bool {
        deviceVolumes.contains { $0.path == remoteDirectory }
    }

    /// 路径是否落在一块**当前没挂载**的外置卷上（卡被拔了／OTG 断了）。
    private func isOnUnmountedVolume(_ path: String) -> Bool {
        guard path.hasPrefix("/storage/") else { return false }
        return !deviceVolumes.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    // MARK: - 本地目录的授权（E7）

    /// 读回书签列表 → 分类成「可用 / 已失效」→ 定授权状态。
    ///
    /// **失效的项直接丢掉**：留着只会每次启动都尝试、每次都失败，
    /// 而且会把真正有效的那些挤到后面（列表有上限）。
    @discardableResult
    private func refreshBookmarkedFolders() -> BookmarkedFolders.Resolution {
        let stored = BookmarkedFolders.load()
        let resolution = BookmarkedFolders.resolveAll(stored) { item in
            // 解析成功还不够 —— 目录可能已经被删、或所在的外置磁盘没插上。
            // 那种情况下 bookmark 有时仍会解析出一个**不存在的路径**；用它只会得到
            // 一个「打不开这个位置」的错误，而用户真正的处境是「上次那个文件夹没了」，
            // 那正是 `expired` 要表达的意思。
            guard let url = BookmarkedFolders.resolveURL(of: item) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
            return url
        }
        if !resolution.stale.isEmpty {
            BookmarkedFolders.save(resolution.resolved.map(\.folder))
            AppLog.info("清掉 \(resolution.stale.count) 个已失效的目录授权", .ui)
        }
        bookmarkedFolders = resolution.resolved.map(\.folder)
        localAccess = FolderAccess.state(
            isSandboxed: AppPaths.containerDirectory != nil,
            storedCount: stored.count,
            resolvedCount: bookmarkedFolders.count)
        return resolution
    }

    /// 启动时该落在哪。
    ///
    /// 侧载版：行为不变（`defaultLocalStartDirectory`，即家目录）。
    /// 沙盒版：**第一个能解析的书签**优先 —— 那才是「上次传素材的地方」。
    /// 还没有任何授权时退回起始目录（真实「下载」），而界面会因为 `.missing`
    /// 直接显示引导，所以不会真的去列容器内容。
    private func restoredStartDirectory(from resolution: BookmarkedFolders.Resolution) -> URL {
        guard localAccess == .granted else { return AppPaths.defaultLocalStartDirectory }
        return resolution.first?.url ?? AppPaths.defaultLocalStartDirectory
    }

    /// 记下一个目录 —— 沙盒版的**授权入口**；侧载版走同一条路，于是顺带成了「最近使用」。
    ///
    /// 返回是否记住了：建不出书签时返回 `false`，界面据此提示，而不是让用户以为
    /// 选好了、下次启动却发现没记住。
    @discardableResult
    func rememberFolder(_ url: URL) -> Bool {
        guard let item = BookmarkedFolders.item(for: url) else { return false }
        let merged = BookmarkedFolders.merging(
            item, resolvedPath: url.path, into: bookmarkedFolders, now: Date())
        bookmarkedFolders = merged
        BookmarkedFolders.save(merged)
        if AppPaths.containerDirectory != nil { localAccess = .granted }
        return true
    }

    /// 「位置」弹窗里的「清除」。
    func forgetBookmarkedFolders() {
        bookmarkedFolders = []
        BookmarkedFolders.save([])
        guard AppPaths.containerDirectory != nil else { return }
        localAccess = .missing
        localEntries = []
        localError = nil
    }

    /// 「或先用『下载』」—— 把「下载」**当作一次正式授权**记下来。
    ///
    /// 它确实是一次授权（用户明确表示要用这个位置），所以走同一套书签机制，
    /// 而不是开一条「临时放行」的旁路 —— 旁路会多出一个半授权态，
    /// 而那个态在下次启动时无法恢复。
    func useDownloadsAsStartFolder() {
        let url = AppPaths.defaultLocalStartDirectory
        rememberFolder(url)
        navigateLocal(to: url, resetHistory: true)
    }

    /// 保证「当前正在访问的授权目录」正好是包含 `url` 的那一个。
    ///
    /// 只维持**一个**：目标没变就不动，变了先把旧的 `stop` 掉。
    /// 非沙盒下这两个调用都是空操作，所以侧载版整段跳过（省掉一轮 bookmarK 解析）。
    private func updateSecurityScope(for url: URL) {
        guard localAccess != .notRequired else { return }
        if let active = activeScope,
           url.path == active.path || url.path.hasPrefix(active.path + "/") {
            return
        }
        // 取**最长**匹配：嵌套授权时里层那个更具体，用它才拿得到真正的权限。
        let match = bookmarkedFolders
            .compactMap { item -> URL? in
                guard let resolved = BookmarkedFolders.resolveURL(of: item) else { return nil }
                let path = resolved.path
                guard url.path == path || url.path.hasPrefix(path + "/") else { return nil }
                return resolved
            }
            .max { $0.path.count < $1.path.count }

        activeScope?.stopAccessingSecurityScopedResource()
        activeScope = nil
        if let match, match.startAccessingSecurityScopedResource() {
            activeScope = match
        }
    }

    /// 释放当前持有的 security-scoped 访问。成对释放 —— 只影响进程寿命内的资源，
    /// 但少了 `stop` 会让别的进程也拿不到该目录。
    func releaseSecurityScopes() {
        activeScope?.stopAccessingSecurityScopedResource()
        activeScope = nil
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
        // 沙盒版：进入某个授权目录的**子树**之前要先把 scope 开起来，否则读不了。
        updateSecurityScope(for: url)
        reloadLocal()
        // 侧载版没有「授权」这件事，于是这条列表顺带承担了「最近使用」。
        // 沙盒版**不能**这么做：那里它是授权的载体，塞一个没有权限的路径进去会顶掉
        // 真正有效的授权，而下次启动就会在一个读不了的目录上醒来。
        if localAccess == .notRequired {
            rememberFolder(url)
        }
    }

    func reloadLocal() {
        // 沙盒版在**没授权 / 授权全失效**时不去列目录：那时 `localDirectory` 指向的是
        // App 自己的容器，列出来只会把管道当用户文件（`list` 也会拒绝，于是变成一个
        // 看不懂的错误）。界面据此显示引导或「重新选择」。
        switch localAccess {
        case .missing, .expired:
            localEntries = []
            localError = nil
            return
        case .notRequired, .granted:
            break
        }
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
            remoteEntries = Self.filterHidden(entries, showHidden: showHiddenFiles).sorted(by: Self.remoteSort)
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
        // 存储卷的根就是尽头：再往上会到 `/storage`，那不是可浏览的位置。
        guard !deviceVolumes.contains(where: { $0.path == remoteDirectory }) else { return }
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

    /// Mac 窗格选中的本地文件 URL（列视图也能还原子目录里的选中项）。
    var selectedLocalURLs: [URL] {
        focusedLocalURLs()
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

    /// 上传落点的**唯一判据**（PRD §15 落点分流 / §18）。
    ///
    /// 收成「按候选文件名」的纯函数，是为了让**窗格内上传**与 **Finder 服务上传**共用同一份规则 ——
    /// 候选名不同（一个是窗格选中项，一个是 Finder 传来的文件），判据必须同一个。
    /// 两处各写一遍必然分叉，而这类分叉在本项目真实发生过（文件类型图标那一次）。
    func uploadDestination(
        for device: AndroidDevice,
        candidateNames: [String]
    ) -> (path: String, reason: String) {
        // 用户已经进到某个目录里了，就不该再把文件按类型挪去别处 —— 分流与「记住上次」
        // 只在窗格停在**卷根**上时介入。
        guard isAtDeviceVolumeRoot else {
            return (remoteDirectory, "设备窗格当前目录")
        }
        if let remembered = settings.destination(for: device.serial),
           !isOnUnmountedVolume(remembered) {
            return (remembered, "上次使用的目录")
        }
        if settings.routingEnabled, let name = candidateNames.first {
            // 分流目标跟随**当前卷**：在 SD 卡上就该分到 SD 卡，而不是内部存储。
            let root = currentDeviceVolume.path
            if name.isVideoFile { return (root + "/Movies", "按文件类型分流") }
            if name.isImageFile { return (root + "/DCIM", "按文件类型分流") }
            return (root + "/Download", "按文件类型分流")
        }
        return (remoteDirectory, "设备窗格当前目录")
    }

    /// 窗格内上传的便利入口（候选名 = 当前选中项）。
    func uploadDestination(for device: AndroidDevice) -> (path: String, reason: String) {
        uploadDestination(for: device, candidateNames: uploadCandidateNames)
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

    // MARK: - Finder 服务（PRD §P1「Services 菜单入口」）

    /// Finder 的「右键 → 服务 → 发送到 DroidBerth」把文件交过来时走这里。
    ///
    /// **刻意不重写传输逻辑**：落点判据复用 `uploadDestination(for:candidateNames:)`，
    /// 传输本身复用 `uploadFiles(_:toRemotePath:reason:)` —— 后者的落点校验
    /// （PRD §12.2 的不可写目录）、冲突策略、入队与「记住上次目录」因此都只有一份实现。
    /// 本函数只多做两件事：**等设备**（App 可能刚被系统拉起来）与**记日志**。
    func handleFinderService(_ urls: [URL]) {
        AppLog.notice("Finder 服务：收到 \(urls.count) 个项目", .transfer)
        // 服务多半是后台触发的，把窗口提到前面来，用户才看得见随后的 banner 与传输面板。
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

        // App 未运行时由系统按 `NSPortName` 拉起，此刻设备往往还没枚举完 —— 等一会儿，
        // 而不是直接报「没有设备」（那会让用户以为得重来一遍）。
        if !(monitor.activeDevice?.state.isUsable ?? false) {
            banner = Banner(
                level: .info,
                title: "正在等待设备",
                detail: "已从 Finder 收到 \(existing.count) 个项目，正在识别 Android 设备…"
            )
            guard await waitForUsableDevice() != nil else {
                banner = Banner(
                    level: .warning,
                    title: "没有可用的设备",
                    detail: "已从 Finder 收到 \(existing.count) 个项目，但没有等到可用的 Android 设备。连上设备后请重新执行一次。"
                )
                AppLog.warning("Finder 服务：等不到可用设备，\(existing.count) 个项目未上传", .transfer)
                return
            }
        }

        guard let device = monitor.activeDevice else { return }
        let destination = uploadDestination(for: device, candidateNames: existing.map(\.lastPathComponent))
        await uploadFiles(existing, toRemotePath: destination.path,
                          reason: "Finder 服务 · \(destination.reason)")
    }

    /// 等一台可用设备。只在 Finder 服务这条路径上用 —— 它是唯一「App 可能刚被拉起」的入口。
    private func waitForUsableDevice(timeout: TimeInterval = 20) async -> AndroidDevice? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await monitor.refresh()
            if let device = monitor.activeDevice, device.state.isUsable { return device }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    // MARK: - 下载

    func downloadSelection() async {
        guard monitor.activeDevice?.state.isUsable == true else {
            banner = Banner(level: .warning, title: "没有可用的设备", detail: nil)
            return
        }

        let entries = focusedRemoteEntries()
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
            let urls = focusedLocalURLs()
            guard !urls.isEmpty else { return }
            payload = TransferDragPayload(side: .local, origin: .pane, paths: urls.map(\.path))

        case .device:
            let entries = focusedRemoteEntries()
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
        let entries = focusedRemoteEntries()
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
    ///
    /// **第一件事是判「面板是不是开着」** —— 空格在 Finder 里是**切换**，开着的面板
    /// 要能收回去。这里必须用 `QuickLookPresenter.isVisible`（面板自身的状态），
    /// 不能靠「上次我们请求了什么」：用户可能用 Esc 或关闭按钮关掉了面板，
    /// 那份记忆就过期了。
    @discardableResult
    func quickLookFocusedSelection() -> Bool {
        if QuickLookPresenter.shared.isVisible {
            QuickLookPresenter.shared.dismiss()
            return true
        }

        switch (focus, macSource) {
        case (.mac, .files):
            let entries = localPreviewEntries()
            guard let index = entries.firstIndex(where: { localSelection.contains($0.id) }) else {
                return false
            }
            QuickLookPresenter.shared.present(items: entries.map(\.url), startAt: index)
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
            let picked = focusedRemoteEntries()
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

    /// 面板开着时跟着选择走 —— 与 Finder 一致：面板不关，内容换成新选中的那个。
    ///
    /// 只在**本地**窗格做：设备端条目本身不在本机，跟着走意味着每换一个文件就 `adb pull`
    /// 一次，那是个不该有的隐式下载。设备端的预览仍然只由空格显式触发。
    func syncQuickLookToSelection() {
        guard QuickLookPresenter.shared.isVisible else { return }
        switch (focus, macSource) {
        case (.mac, .files):
            let entries = localPreviewEntries()
            guard let index = entries.firstIndex(where: { localSelection.contains($0.id) }) else { return }
            QuickLookPresenter.shared.follow(items: entries.map(\.url), startAt: index)
        case (.mac, .photos), (.device, _):
            break
        }
    }

    /// 交给 Quick Look 的本地条目。
    ///
    /// **文件夹也放进来**：`QLPreviewPanel` 原生长于预览文件夹（图标 + 元数据），
    /// 而 Finder 的预览面板同样允许停在文件夹上。所以这里不筛类型。
    private func localPreviewEntries() -> [LocalEntry] {
        guard let snapshot = columnSnapshot(for: .mac, selection: localSelection) else {
            return localEntries
        }
        return [snapshot.asLocalEntry]
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
        if !QuickLookPresenter.shared.isVisible { AppPaths.clearPreviews() }
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
            QuickLookPresenter.shared.present(items: [target], startAt: 0)
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

        // 重名预检（PRD §16「重名时提示，不静默改名」）。`mkdir -p` 对已存在的目录
        // **静默成功**，而在不区分大小写的设备卷上 `Photos` 与 `photos` 就是同一个目录
        // （实测见 `NameComparison`）—— 不检查的话，「新建」会退化成一次看不出问题的空动作。
        if !NameConflict.conflicting([trimmed], existing: remoteEntries.map(\.name)).isEmpty {
            banner = Banner(level: .error, title: "已有同名项目", detail: "「\(trimmed)」已存在，换一个名称再试")
            return
        }

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
        await deleteRemoteEntries(focusedRemoteEntries())
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

    // MARK: - 诊断（日志与崩溃收集）

    /// 是否正在导出诊断包。界面据此禁用按钮并显示进度 —— 导出会跑一遍自检与
    /// sidecar doctor，几秒到十几秒。
    private(set) var diagnosticsExporting = false

    /// 导出诊断包。
    ///
    /// 收集放后台线程（要起子进程），完成后**在访达里把 zip 选中** ——
    /// 用户的下一步动作就是把它发出去，不该再让他们自己去翻文件。
    func exportDiagnostics() async {
        guard !diagnosticsExporting else { return }
        diagnosticsExporting = true
        banner = Banner(
            level: .info,
            title: "正在收集诊断信息…",
            detail: "要跑一遍自检，可能需要十几秒"
        )
        let outcome = await Task.detached(priority: .userInitiated) {
            DiagnosticsExporter.collect()
        }.value
        diagnosticsExporting = false
        NSWorkspace.shared.activateFileViewerSelecting([outcome.zipURL])
        banner = Banner(
            level: outcome.warnings.isEmpty ? .info : .warning,
            title: outcome.warnings.isEmpty
                ? "诊断报告已生成"
                : "诊断报告已生成（\(outcome.warnings.count) 项没拿到）",
            detail: outcome.zipURL.lastPathComponent
        )
    }

    /// 在访达里选中日志目录。设置面板里显示了这个路径，按钮就该打开同一个地方。
    func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logsDirectory])
    }

    // MARK: - 设备端重命名 / 移动（PRD §13.1 右键、§24 窗格内拖拽）

    /// 设备端名称校验。抽成纯函数：校验规则要能被单测钉住，而且 UI 侧想在提交前
    /// 实时禁用「确定」也要用它。
    ///
    /// **规则本身在 `DeviceNameRules` 里**（连同实测证据）—— 判据是「设备端到底接受什么」，
    /// 不是「FAT32 规范说什么」。这里只做转发，避免规则出现第二份。
    static func validateRemoteName(_ raw: String) -> String? {
        DeviceNameRules.validationMessage(for: raw)
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
        //
        // **必须按折叠判据比**：设备端卷不区分大小写（实测见 `NameComparison`），
        // 所以 `b.txt` → `A.TXT` 在设备上就是改到已有的 `a.txt` 上 —— 精确比较会漏判，
        // 然后 `mv` 把 `a.txt` 的内容覆盖掉。把被改的条目本身排除掉，
        // 是为了不挡住「只改大小写」这种合法操作。
        if !NameConflict.conflicting([destination], existing: remoteEntries.map(\.path), excluding: entry.path).isEmpty {
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
        // 同样**按折叠判据比** —— 设备端卷不区分大小写（实测见 `NameComparison`）。
        let names = pending.map { ($0 as NSString).lastPathComponent }
        let conflicts = await Task.detached(priority: .userInitiated) { () -> [String] in
            guard case .success(let listed) = shell.list(target) else { return [] }
            return NameConflict.conflicting(names, existing: listed.map(\.name))
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
        let entries = focusedRemoteEntries()
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
        let notIndexed = outcomes.filter { $0.indexability == .notIndexed }.count
        let nonMedia = outcomes.count - indexed - notIndexed

        if notIndexed == 0 {
            var parts: [String] = []
            if indexed > 0 { parts.append("\(indexed) 个文件已进入系统相册索引") }
            if nonMedia > 0 { parts.append("\(nonMedia) 个非媒体文件不参与相册索引") }
            banner = Banner(
                level: .info,
                title: indexed > 0 ? "媒体库已刷新" : "无需刷新媒体库",
                detail: parts.isEmpty ? nil : parts.joined(separator: "；")
            )
        } else {
            var detail = "\(notIndexed) 个文件未索引。可在手机上打开相册下拉刷新；若仍看不到，重启手机后即可出现"
            if nonMedia > 0 { detail += "（另有 \(nonMedia) 个非媒体文件不参与相册索引）" }
            banner = Banner(level: .warning, title: "部分文件未进入相册索引", detail: detail)
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
        remoteBreadcrumbs(for: remoteDirectory)
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

    // MARK: - 聚焦窗格的选中项（统一解析入口）

    /// 列视图选中项的**快照**。
    ///
    /// 列表 / 网格的选择能由当前列表直接还原；**列视图不能** —— 它选中的条目可能位于
    /// **子目录**里（`/sdcard/DCIM/Camera/x.jpg` 根本不在 `/sdcard/DCIM` 的列表里）。
    /// 所以列视图在选中时把条目记在这里，供预览窗格、Quick Look、⌘C/⌘V 还原。
    private var columnSnapshots: [Pane: BrowserEntry] = [:]

    func rememberColumnSelection(_ entry: BrowserEntry?, in pane: Pane) {
        if let entry {
            columnSnapshots[pane] = entry
        } else {
            columnSnapshots.removeValue(forKey: pane)
        }
    }

    /// 聚焦窗格选中的条目。三种视图形态在这里归一，调用方不必各自判断。
    func focusedBrowserSelection() -> [BrowserEntry] {
        switch (focus, macSource) {
        case (.mac, .files):
            if let snapshot = columnSnapshot(for: .mac, selection: localSelection) { return [snapshot] }
            return localEntries.filter { localSelection.contains($0.id) }.map(\.asBrowserEntry)

        case (.mac, .photos):
            return photos.items.filter { photoSelection.contains($0.id) }.map(\.asBrowserEntry)

        case (.device, _):
            if let snapshot = columnSnapshot(for: .device, selection: remoteSelection) { return [snapshot] }
            return remoteEntries.filter { remoteSelection.contains($0.id) }.map(BrowserEntry.init(remote:))
        }
    }

    /// 设备窗格选中的条目。
    ///
    /// 刻意**不看焦点**：右键菜单、弹窗里的「删除」都可能在设备窗格未聚焦时触发，
    /// 那时要的仍然是「设备窗格选中了什么」。
    func focusedRemoteEntries() -> [RemoteEntry] {
        if let snapshot = columnSnapshot(for: .device, selection: remoteSelection) {
            return [snapshot.asRemoteEntry]
        }
        return remoteEntries.filter { remoteSelection.contains($0.id) }
    }

    /// Mac 窗格选中的本地文件 URL。照片图库不在此列 —— 它的条目不是文件路径。
    ///
    /// 同样不看焦点（上传按钮作用于 Mac 窗格，与焦点无关）。
    func focusedLocalURLs() -> [URL] {
        if let snapshot = columnSnapshot(for: .mac, selection: localSelection) {
            return [snapshot.asLocalEntry.url]
        }
        return localEntries.filter { localSelection.contains($0.id) }.map(\.url)
    }

    /// 只有快照**恰好等于当前的单选**时才采用它 —— 否则宁可按当前列表还原，
    /// 免得拿一份过期快照去操作错的条目。
    private func columnSnapshot(for pane: Pane, selection: Set<String>) -> BrowserEntry? {
        guard viewMode(for: pane) == .column,
              let snapshot = columnSnapshots[pane],
              selection == [snapshot.id] else { return nil }
        return snapshot
    }

    // MARK: - 预览窗格（PRD §11 的「显示预览窗格 ⇧⌘P」）

    /// 预览窗格要展示的内容。一次算好，视图直接用，避免在 View 里散着算。
    struct PreviewSummary {
        let owner: String
        let pane: Pane
        let entries: [BrowserEntry]

        var count: Int { entries.count }
        var single: BrowserEntry? { entries.count == 1 ? entries.first : nil }
        var directoryCount: Int { entries.filter(\.isDirectory).count }
        var fileCount: Int { entries.count - directoryCount }
        /// 已知大小的条目之和。**大小未知的不混进合计**，否则会给一个偏小的数字让人误判。
        var knownBytes: Int64 { entries.compactMap(\.size).reduce(0, +) }
        var unknownSizeCount: Int { entries.filter { $0.size == nil }.count }
    }

    var previewSummary: PreviewSummary {
        PreviewSummary(owner: previewOwner, pane: focus, entries: focusedBrowserSelection())
    }

    var previewOwner: String {
        switch (focus, macSource) {
        case (.mac, .files): "这台 Mac"
        case (.mac, .photos): "照片图库"
        case (.device, _): activeDevice?.displayName ?? "Android 设备"
        }
    }

    func togglePreviewPane() {
        settings.showPreviewPane.toggle()
    }

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
            return Self.filterHidden(listed, showHidden: showHiddenFiles)
                .sorted(by: Self.remoteSort)
                .map(BrowserEntry.init(remote:))

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

    /// 设备端的面包屑。
    ///
    /// 走到哪个存储卷就**用卷标签顶掉那一层路径**：`/storage/1234-5678` 直接显示成
    /// 「SD 卡」，`/sdcard` 显示成「内部存储」，并吞掉中间的 `/storage` —— 那个目录
    /// 不是可浏览的「位置」，把它摆进面包屑只会让路径栏多一个无处可去的层级。
    /// 卷之外的路径（`/`）走原本的逐层展开。
    func remoteBreadcrumbs(for directory: String) -> [(String, String)] {
        for volume in deviceVolumes
        where directory == volume.path || directory.hasPrefix(volume.path + "/") {
            var result: [(String, String)] = [("/", "/"), (volume.label, volume.path)]
            var path = volume.path
            if directory != volume.path {
                let rest = directory.dropFirst(volume.path.count + 1)
                for component in rest.split(separator: "/") where !component.isEmpty {
                    path += "/" + component
                    result.append((String(component), path))
                }
            }
            return result
        }

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

    /// 「位置」弹窗与设置界面里那条列表的**标题**。
    ///
    /// 同一条列表在两侧的**含义不同**：侧载版是「你最近去过哪」，沙盒版是
    /// 「你授权过哪些目录」—— 后者是**权限**而不是历史，叫「最近使用」会让人
    /// 以为它只是一份记录（于是不敢清除、也不知道清除了会失去访问权）。
    /// 所以按运行环境取词，且只在这一处取 —— 两处各写一遍就会分叉。
    var bookmarkedFolderSectionTitle: String {
        AppPaths.containerDirectory == nil ? "最近使用" : "已授权"
    }

    /// 还没授权（或授权全失效）—— 此时**导航控件与面包屑都没有意义**。
    ///
    /// 留着它们会让界面自相矛盾：路径栏写着「下载」，内容区却说「先选一个要传的文件夹」。
    /// 那看起来就是个 bug，而它恰恰出现在用户**第一次打开 app 的那一屏**。
    var needsFolderAccess: Bool {
        localAccess == .missing || localAccess == .expired
    }

    /// 设置界面里那条列表的说明文字。同样只在这一处取词 ——
    /// 沙盒版「清除」清掉的是**权限**，不点明的话用户会以为只是清一份历史记录。
    var bookmarkedFolderSummary: String {
        let count = bookmarkedFolders.count
        guard AppPaths.containerDirectory != nil else {
            return "「位置」弹窗里显示 \(count) 项"
        }
        return "「位置」弹窗里显示 \(count) 项；清除后要重新选择才能访问这些目录"
    }

    // MARK: - 网格视图的键盘导航（PRD §13.3）

    /// 每侧网格当前的列数，由 `EntryGrid` 在布局后回报。
    ///
    /// 为什么必须由视图回报：`LazyVGrid` 的 `.adaptive` 铺几列是 SwiftUI 按可用宽决定的，
    /// 视图之外拿不到；而 ↑ / ↓ 要按**一行的条数**跳，猜一个列数会让上下键落到别处。
    /// 「怎么算列数」只有一份实现（`GridNavigation.columnCount`），视图拿它算、这里拿它跳。
    private var gridColumns: [Pane: Int] = [:]

    func reportGridColumnCount(_ count: Int, for pane: Pane) {
        let clamped = max(count, 1)
        guard gridColumns[pane] != clamped else { return }
        gridColumns[pane] = clamped
    }

    /// ⇧ 区间选择与方向键共用的锚点。
    ///
    /// 放在模型里而不是 `EntryGrid` 的 `@State`：键盘移动是从这里发起的，锚点若留在视图里，
    /// 鼠标点一下再按 ⇧→ 的区间就会从别处开始 —— 两份锚点必然分叉。
    private var gridAnchors: [Pane: String] = [:]

    func gridAnchor(for pane: Pane) -> String? { gridAnchors[pane] }

    func setGridAnchor(_ id: String?, for pane: Pane) {
        if let id {
            gridAnchors[pane] = id
        } else {
            gridAnchors.removeValue(forKey: pane)
        }
    }

    /// 键盘移动后要求网格滚到可见的条目 id。
    ///
    /// **只在键盘移动时设置**：鼠标点到的条目本来就在视野里，若也走滚动，
    /// 就会出现「点一下视图自己动一下」的副作用。
    private var gridScrollTargets: [Pane: String] = [:]

    func gridScrollTarget(for pane: Pane) -> String? { gridScrollTargets[pane] }

    func setGridScrollTarget(_ id: String?, for pane: Pane) {
        if let id {
            gridScrollTargets[pane] = id
        } else {
            gridScrollTargets.removeValue(forKey: pane)
        }
    }

    /// 聚焦窗格此刻是不是「一个支持键盘导航的网格」。
    ///
    /// 照片图库的网格刻意不在内：它的顺序来自 PhotoKit（`PhotoLibraryModel.items`），
    /// 与 `GridNavigation` 拿到的不是同一份列表 —— 硬接上去会让 ↓ 跳到看不见的地方。
    /// 返回 false 时按键原样交还系统。
    private var focusedGridIsNavigable: Bool {
        switch (focus, macSource) {
        case (.mac, .files): viewMode(for: .mac) == .grid
        case (.device, _): viewMode(for: .device) == .grid
        case (.mac, .photos): false
        }
    }

    /// 聚焦窗格里网格要显示的条目，顺序与屏幕上一致。
    private func focusedGridEntries() -> [BrowserEntry] {
        switch (focus, macSource) {
        case (.mac, .files):
            return GridNavigation.order(
                visibleLocalEntries.map(\.asBrowserEntry), foldersFirst: settings.foldersFirst
            )
        case (.device, _):
            return GridNavigation.order(
                visibleRemoteEntries.map(BrowserEntry.init(remote:)), foldersFirst: settings.foldersFirst
            )
        case (.mac, .photos):
            return []
        }
    }

    private func selection(in pane: Pane) -> Set<String> {
        pane == .mac ? localSelection : remoteSelection
    }

    private func setSelection(_ ids: Set<String>, in pane: Pane) {
        if pane == .mac {
            localSelection = ids
        } else {
            remoteSelection = ids
        }
    }

    /// 光标当前位置：优先锚点，锚点失效（条目被删掉 / 换了目录）再退回当前单选的那一项。
    private func gridCursorIndex(in entries: [BrowserEntry]) -> Int? {
        if let anchor = gridAnchors[focus], let index = entries.firstIndex(where: { $0.id == anchor }) {
            return index
        }
        let picked = selection(in: focus)
        return entries.firstIndex { picked.contains($0.id) }
    }

    /// 网格的方向键。返回 true 表示已消费。
    ///
    /// 没有选中项时第一下落在首项，而不是「按了没反应」—— 点完空白处再按 → 会从第一格开始。
    @discardableResult
    func moveGridSelection(_ move: GridNavigation.Move, extending: Bool) -> Bool {
        guard focusedGridIsNavigable else { return false }
        let entries = focusedGridEntries()
        guard !entries.isEmpty else { return false }

        let pane = focus
        let start = gridCursorIndex(in: entries) ?? 0
        let target = GridNavigation.targetIndex(
            from: start, move: move, columns: gridColumns[pane] ?? 1, count: entries.count
        )
        guard entries.indices.contains(target) else { return false }

        if extending, let anchor = gridAnchors[pane],
           let anchorIndex = entries.firstIndex(where: { $0.id == anchor }) {
            let range = anchorIndex <= target ? anchorIndex...target : target...anchorIndex
            setSelection(Set(entries[range].map(\.id)), in: pane)
        } else {
            setSelection([entries[target].id], in: pane)
            gridAnchors[pane] = entries[target].id
        }
        gridScrollTargets[pane] = entries[target].id
        return true
    }

    /// 一轮字母跳转的起点下标。
    ///
    /// `su` 的第 2 枚字母要在**同一批候选**里把前缀重新筛一遍；从「上一次落点」往后找
    /// 会把刚筛出来的那一项正好跳过去（`s` 跳到 sunset 之后再敲 `u`，会跳到 sunrise）。
    /// 所以只在**新一轮的第一枚字母**上重算起点。
    private var gridTypeSelectOrigins: [Pane: Int] = [:]

    /// 网格的字母跳转。返回 true 表示已消费（没命中就返回 false，让按键回到系统，
    /// 不会变成「按了没反应」）。
    @discardableResult
    func typeSelectInGrid(_ query: String, isContinuation: Bool) -> Bool {
        guard focusedGridIsNavigable else { return false }
        let entries = focusedGridEntries()
        guard !entries.isEmpty else { return false }

        let pane = focus
        let origin: Int
        if isContinuation, let remembered = gridTypeSelectOrigins[pane] {
            origin = remembered
        } else {
            // 从「当前项的下一个」开始找：连着敲同一个字母因此在所有命中项之间轮转。
            origin = (gridCursorIndex(in: entries) ?? -1) + 1
            gridTypeSelectOrigins[pane] = origin
        }

        guard let index = GridNavigation.typeSelectIndex(query, in: entries, from: origin) else {
            return false
        }
        setSelection([entries[index].id], in: pane)
        gridAnchors[pane] = entries[index].id
        gridScrollTargets[pane] = entries[index].id
        return true
    }

    /// 回车重命名的目标（PRD §13.1）。
    ///
    /// 三条同时成立才给：① 聚焦窗格在设备端；② 恰好选中一项；③ 视图形态是列表或网格。
    ///
    /// **分栏刻意排除。** `renameRemoteEntry` 的冲突预检比的是**当前目录**的列表，
    /// 而分栏选中的条目可能位于子目录（`/sdcard/DCIM/Camera/x.jpg` 并不在 `/sdcard/DCIM` 里），
    /// 那份列表里没有它的同目录兄弟 ⇒ 预检漏判 ⇒ `mv` 静默覆盖用户手机上的文件
    /// （`mv` 默认覆盖，设备端又没有回收站）。宁可这个键位在分栏里不存在，
    /// 也不要一个会丢数据的入口 —— 分栏本来也没有右键「重命名…」，两边一致。
    var renameCandidate: BrowserEntry? {
        guard focus == .device,
              activeDevice != nil,
              viewMode(for: .device) != .column,
              remoteSelection.count == 1 else { return nil }
        return focusedBrowserSelection().first
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
