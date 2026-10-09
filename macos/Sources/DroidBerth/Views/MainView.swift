import QuickLook
import SwiftUI

@MainActor
struct MainView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showDeleteConfirm = false
    @State private var showPlaces = false
    @State private var keyMonitor: PaneKeyMonitor?
    @State private var macDropTargeted = false
    @State private var deviceDropTargeted = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                pane(model.leftPane)
                    .frame(minWidth: 340)
                pane(model.rightPane)
                    .frame(minWidth: 340)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !model.queue.isEmpty || model.settings.transferPanelPinned {
                Divider()
                TransferPanel(queue: model.queue, settings: model.settings)
            }
        }
        .overlay(alignment: .top) { bannerOverlay }
        .toolbar { toolbar }
        .task {
            AppearanceController.apply(model.settings.appearance)
            model.start()
            if keyMonitor == nil {
                let monitor = PaneKeyMonitor()
                monitor.onCycleFocus = { backwards in
                    model.cycleFocus(backwards: backwards)
                }
                monitor.onQuickLook = { model.quickLookFocusedSelection() }
                monitor.start()
                keyMonitor = monitor
            }
        }
        .onDisappear { keyMonitor?.stop() }
        .quickLookPreview($model.previewURL)
        .onReceive(NotificationCenter.default.publisher(for: .droidBerthNewFolder)) { _ in
            guard model.activeDevice != nil else { return }
            showNewFolder = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .droidBerthDeleteSelection)) { _ in
            guard model.canDeleteSelection else { return }
            showDeleteConfirm = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .droidBerthFocusSearch)) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .droidBerthOpenSettings)) { _ in
            showSettings = true
        }
        .onChange(of: model.monitor.selectedSerial) { _, _ in
            Task { await model.deviceDidChange() }
        }
        .onChange(of: model.showHiddenFiles) { _, _ in
            model.reloadLocal()
        }
        .onChange(of: model.settings.appearance) { _, newValue in
            AppearanceController.apply(newValue)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: model.settings)
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.makeRemoteDirectory(named: name) }
            }
        } message: {
            Text("将在 \(model.remoteDirectory) 下创建")
        }
        .alert("删除 \(model.remoteSelection.count) 个项目？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await model.deleteRemoteSelection() }
            }
        } message: {
            Text("此操作不可撤销。设备端没有回收站，删除后无法恢复。")
        }
        .alert(
            "预览需要先下载",
            isPresented: Binding(
                get: { model.pendingPreview != nil },
                set: { if !$0 { model.cancelPendingPreview() } }
            ),
            presenting: model.pendingPreview
        ) { _ in
            Button("取消", role: .cancel) { model.cancelPendingPreview() }
            Button("下载并预览") { model.confirmPendingPreview() }
        } message: { pending in
            Text("\(pending.entry.name) 有 \(ByteFormat.size(pending.entry.size))，预览需要先完整下载到本机。")
        }
    }

    // MARK: - 窗格分发

    /// 左右窗格由 `model.panesSwapped` 决定，因此 ⇄ 交换只需换这里的分发。
    @ViewBuilder
    private func pane(_ target: AppModel.Pane) -> some View {
        switch target {
        case .mac: macPane
        case .device: devicePane
        }
    }

    // MARK: - Mac 窗格

    private var macPane: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: model.macSource == .files ? "这台 Mac" : "照片图库",
                systemImage: model.macSource == .files ? "laptopcomputer" : "photo.on.rectangle",
                isFocused: model.focus == .mac
            ) {
                Picker("", selection: $model.macSource) {
                    ForEach(AppModel.MacSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            .onTapGesture { model.focus = .mac }

            Divider()

            if model.macSource == .files {
                fileNavigationBar
                Divider()
                EntryTable(
                    entries: macEntries,
                    selection: $model.localSelection,
                    emptyMessage: macEmptyMessage,
                    onOpen: { entry in
                        guard let local = model.localEntries.first(where: { $0.id == entry.id }) else { return }
                        if local.isDirectory {
                            model.navigateLocal(to: local.url)
                        } else {
                            model.openLocalEntry(local)
                        }
                    },
                    onReveal: { entry in
                        guard let local = model.localEntries.first(where: { $0.id == entry.id }) else { return }
                        model.revealInFinder(local)
                    },
                    onUpload: { Task { await model.uploadSelection() } },
                    onRefresh: { model.reloadLocal() },
                    dragSide: .local,
                    foldersFirst: model.settings.foldersFirst
                )
                localStatusBar
            } else {
                PhotoSourceView(model: model)
            }
        }
        .modifier(PaneFocusStyle(isFocused: model.focus == .mac))
        .dropDestination(for: TransferDragPayload.self) { payloads, _ in
            model.focus = .mac
            model.performDrop(payloads, onto: .mac)
            return true
        } isTargeted: { macDropTargeted = $0 }
        .modifier(PaneDropHighlight(isTargeted: macDropTargeted))
    }

    private var fileNavigationBar: some View {
        HStack(spacing: 8) {
            Button { model.localGoBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoLocalBack)
                .buttonStyle(.borderless)
            Button { model.localGoForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoLocalForward)
                .buttonStyle(.borderless)
            Button { model.localGoUp() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)

            placesButton

            PathBreadcrumb(items: model.localBreadcrumbs.map { item in (item.0, { model.navigateLocal(to: item.1) }) })

            Spacer()

            Toggle("隐藏文件", isOn: $model.showHiddenFiles)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// 位置入口。
    ///
    /// 刻意**不做常驻侧边栏**：这是一个双栏传输工具，第三栏会永久吃掉横向空间，
    /// 而「位置」是偶发动作。真正的痛点是「回到上次传的那个项目文件夹」，
    /// 所以弹窗里把「最近使用」放在最前面（见 `PlacesPopover`）。
    private var placesButton: some View {
        Button { showPlaces.toggle() } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showPlaces, arrowEdge: .bottom) {
            PlacesPopover(model: model, onPick: { url in
                model.navigateLocal(to: url, resetHistory: true)
                showPlaces = false
            }, onChooseOther: {
                showPlaces = false
                chooseLocalFolder()
            })
        }
        .help("位置")
    }

    private var localStatusBar: some View {
        HStack {
            Text("\(model.localEntries.count) 个项目")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.localSelection.count > 0 {
                Text("已选 \(model.localSelection.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.localSelection.count == 1 {
                Text("空格预览")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if model.hiddenBySearchCount(in: .mac) > 0 {
                Text("筛选后 \(model.visibleLocalEntries.count) / \(model.localEntries.count)")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if let bytes = model.remoteAvailableBytes, model.activeDevice != nil {
                Text("设备可用 \(ByteFormat.size(bytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var macEntries: [BrowserEntry] {
        model.visibleLocalEntries.map(\.asBrowserEntry)
    }

    private var macEmptyMessage: String {
        if let error = model.localError { return error }
        if model.hiddenBySearchCount(in: .mac) > 0 { return "没有匹配「\(model.searchQuery)」的项目" }
        return "这个文件夹是空的"
    }

    // MARK: - 设备窗格

    private var devicePane: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: model.activeDevice?.displayName ?? "Android 设备",
                systemImage: model.activeDevice?.isWireless == true ? "wifi" : "iphone.gen3",
                isFocused: model.focus == .device
            ) {
                Menu {
                    ForEach(model.deviceQuickLocations, id: \.1) { item in
                        Button(item.0) { Task { await model.navigateRemote(to: item.1) } }
                    }
                } label: {
                    Label("位置", systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 92)
            }
            .onTapGesture { model.focus = .device }

            Divider()

            HStack(spacing: 8) {
                Button { Task { await model.remoteGoBack() } } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoRemoteBack)
                    .buttonStyle(.borderless)
                Button { Task { await model.remoteGoForward() } } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoRemoteForward)
                    .buttonStyle(.borderless)
                Button { Task { await model.remoteGoUp() } } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)

                PathBreadcrumb(items: remoteBreadcrumbItems)

                Spacer()

                if model.remoteLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            EntryTable(
                entries: model.visibleRemoteEntries.map(BrowserEntry.init(remote:)),
                selection: $model.remoteSelection,
                emptyMessage: deviceEmptyMessage,
                onOpen: { entry in
                    guard let remote = model.remoteEntries.first(where: { $0.id == entry.id }) else { return }
                    if remote.isDirectory {
                        Task { await model.navigateRemote(to: remote.path) }
                    }
                },
                onDelete: { showDeleteConfirm = true },
                onDownload: { Task { await model.downloadSelection() } },
                onNewFolder: { showNewFolder = true },
                onRefresh: { Task { await model.loadRemote() } },
                dragSide: .remote,
                foldersFirst: model.settings.foldersFirst
            )

            HStack {
                Text("\(model.remoteEntries.count) 个项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.remoteSelection.count > 0 {
                    Text("已选 \(model.remoteSelection.count) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.remoteSelection.count == 1 {
                    Text("空格预览")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if model.hiddenBySearchCount(in: .device) > 0 {
                    Text("筛选后 \(model.visibleRemoteEntries.count) / \(model.remoteEntries.count)")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if let bytes = model.remoteAvailableBytes {
                    Text("可用 \(ByteFormat.size(bytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .modifier(PaneFocusStyle(isFocused: model.focus == .device))
        .dropDestination(for: TransferDragPayload.self) { payloads, _ in
            model.focus = .device
            model.performDrop(payloads, onto: .device)
            return true
        } isTargeted: { deviceDropTargeted = $0 }
        .modifier(PaneDropHighlight(isTargeted: deviceDropTargeted))
    }

    // MARK: - 设备菜单

    private var deviceMenu: some View {
        Menu {
            if model.monitor.usableDevices.isEmpty {
                Text("插入设备后出现在这里")
            } else {
                Section {
                    ForEach(model.monitor.usableDevices) { device in
                        Button {
                            model.monitor.selectedSerial = device.serial
                        } label: {
                            if device.serial == model.monitor.selectedSerial {
                                Label("\(device.displayName) · \(device.connectionLabel)", systemImage: "checkmark")
                            } else {
                                Text("\(device.displayName) · \(device.connectionLabel)")
                            }
                        }
                    }
                }
                Section {
                    Button("重新检测设备") {
                        Task { await model.monitor.refresh() }
                    }
                    if let device = model.activeDevice, !device.isWireless {
                        Button("启用无线连接") {
                            Task { await model.enableWireless() }
                        }
                        .disabled(model.wireless.busy)
                    }
                    if model.activeDevice == nil, !model.settings.rememberedWirelessDevices.isEmpty {
                        Button("尝试无线重连") {
                            Task { await model.reconnectWireless() }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(model.activeDevice == nil ? Color.secondary : Color.accentColor)
                Text(model.activeDevice?.displayName ?? "未连接设备")
                    .lineLimit(1)
                if model.wireless.busy {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }

    private var deviceEmptyMessage: String {
        if let remoteError = model.remoteError { return remoteError }
        if model.hiddenBySearchCount(in: .device) > 0 { return "没有匹配「\(model.searchQuery)」的项目" }
        if model.activeDevice != nil { return "这个文件夹是空的" }
        switch model.monitor.status {
        case .sidecarMissing:
            return "找不到 sidecar，请重新构建 app"
        case .adbMissing:
            return "app 包内缺少 adb 可执行文件"
        case .failed(let message):
            return message
        case .idle:
            if let unauthorized = model.monitor.devices.first(where: { $0.state == .unauthorized }) {
                return "\(unauthorized.displayName) 未授权：请在手机上勾选「始终允许」后点确定"
            }
            return "未检测到 Android 设备，请用数据线连接并在手机上允许 USB 调试"
        }
    }

    // MARK: - 工具栏与提示

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            deviceMenu
        }

        // PRD §10 要求 ⇄ 居中。放在两栏之间语义上也对 —— 它交换的正是这两栏。
        ToolbarItem(placement: .principal) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { model.swapPanes() }
            } label: {
                Label("交换两侧", systemImage: "arrow.left.arrow.right")
            }
            .help("左右窗格互换（⇧⌘X）")
        }

        // 上传 / 下载是这个产品的核心动作，刻意留在工具栏而不是收进 ⋯：
        // 把主要动作藏进菜单是净损失（PRD §10 把它们列在 ⋯ 里，此处偏离）。
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.uploadSelection() }
            } label: {
                Label("上传到设备", systemImage: "arrow.up.to.line")
            }
            .disabled(model.uploadSelectionCount == 0 || model.activeDevice == nil)
            .help("把 Mac 窗格中选中的项目上传到设备当前目录（⇧⌘U）")

            Button {
                Task { await model.downloadSelection() }
            } label: {
                Label("下载到 Mac", systemImage: "arrow.down.to.line")
            }
            .disabled(model.remoteSelection.isEmpty || model.activeDevice == nil)
            .help("把设备窗格中选中的项目下载到 Mac 当前目录（⇧⌘S）")

            searchField

            moreMenu
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(model.searchPrompt, text: searchBinding)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .frame(width: 130)

            if model.isSearching {
                // 把「查询作用在哪个窗格」写在明面上：作用域只在编辑时锁定，
                // 不跟随焦点实时变化，否则 Tab 一下结果就跳。
                Text(model.searchScopeIsMac ? "Mac" : "设备")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help(model.searchScopeIsMac ? "筛选「这台 Mac」窗格" : "筛选设备窗格")

                Button { model.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("清除筛选")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var searchBinding: Binding<String> {
        Binding(get: { model.searchQuery }, set: { model.setSearchQuery($0) })
    }

    private var moreMenu: some View {
        Menu {
            Button("新建文件夹…") { showNewFolder = true }
                .disabled(model.activeDevice == nil)
            Button("刷新媒体库") {
                Task { await model.scanRemoteSelection() }
            }
            .disabled(model.remoteSelection.isEmpty || model.activeDevice == nil)

            Divider()

            Button("刷新") { model.refreshFocusedPane() }
            Toggle("显示隐藏文件", isOn: $model.showHiddenFiles)
            // `AppModel.settings` 是 let，取不到可写 keyPath，用 Bindable 包一层。
            Toggle("文件夹排在最前", isOn: Bindable(model.settings).foldersFirst)

            Divider()

            Button("交换两侧") { model.swapPanes() }
            Button("快速查看") { model.quickLookFocusedSelection() }
                .disabled(!model.canQuickLook)
            Button("设置…") { showSettings = true }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
        .help("更多操作")
    }

    @ViewBuilder
    private var bannerOverlay: some View {
        if let banner = model.banner {
            HStack(spacing: 10) {
                Image(systemName: icon(for: banner.level))
                    .foregroundStyle(color(for: banner.level))
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.callout).bold()
                    if let detail = banner.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(radius: 6)
            .padding(12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func icon(for level: AppModel.Banner.Level) -> String {
        switch level {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(for level: AppModel.Banner.Level) -> Color {
        switch level {
        case .info: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }

    private var remoteBreadcrumbItems: [(String, () -> Void)] {
        model.remoteBreadcrumbs.map { item in
            let path = item.1
            let action: () -> Void = { Task { await model.navigateRemote(to: path) } }
            return (item.0, action)
        }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.localDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.navigateLocal(to: url, resetHistory: true)
        }
    }
}

/// 「位置」弹窗。
///
/// 「最近使用」排在「位置」之前，是因为主场景里用户反复回到的是**同一个项目文件夹**
/// （几百 GB 的素材目录），而不是桌面 / 下载这些固定位置。
private struct PlacesPopover: View {
    @Bindable var model: AppModel
    let onPick: (URL) -> Void
    let onChooseOther: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !model.recentLocalFolders.isEmpty {
                sectionHeader("最近使用") {
                    Button("清除") { model.settings.forgetRecentLocalFolders() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.recentLocalFolders, id: \.path) { url in
                    row(url.lastPathComponent, "clock", url.path)
                }
                Divider().padding(.vertical, 4)
            }

            sectionHeader("位置", trailing: { EmptyView() })
            ForEach(LocalFileSystem.places()) { place in
                row(place.name, place.systemImage, place.url.path)
            }

            Divider().padding(.vertical, 4)
            Button { onChooseOther() } label: {
                rowLabel("其它…", "ellipsis.circle", nil)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(width: 290)
    }

    private func sectionHeader<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    private func row(_ name: String, _ symbol: String, _ path: String?) -> some View {
        Button {
            guard let path else { return }
            onPick(URL(fileURLWithPath: path, isDirectory: true))
        } label: {
            rowLabel(name, symbol, path)
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ name: String, _ symbol: String, _ path: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if let path, path != name {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// 聚焦窗格的视觉标识。
///
/// PRD §25 要求「聚焦态不能只靠颜色区分」，因此这里同时给出**形状变化**
/// （系统色描边）与**文字加重**（由 `PaneHeader` 负责），以适配色觉障碍。
private struct PaneFocusStyle: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .background(isFocused ? Color.accentColor.opacity(0.06) : Color.clear)
            .overlay {
                Rectangle()
                    .strokeBorder(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
    }
}

/// 拖拽悬停时的落点高亮（PRD §24「拖拽进入目标区域时高亮」）。
private struct PaneDropHighlight: ViewModifier {
    let isTargeted: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isTargeted {
                ZStack {
                    Color.accentColor.opacity(0.12)
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

struct PaneHeader<Accessory: View>: View {
    let title: String
    let systemImage: String
    let isFocused: Bool
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
            Text(title)
                .font(.headline)
                .fontWeight(isFocused ? .semibold : .regular)
                .lineLimit(1)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct PathBreadcrumb: View {
    let items: [(String, () -> Void)]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(item.0) { item.1() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }
}
