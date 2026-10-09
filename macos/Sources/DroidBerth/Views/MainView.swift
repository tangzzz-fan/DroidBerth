import QuickLook
import SwiftUI

@MainActor
struct MainView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showDeleteConfirm = false
    @State private var showRename = false
    @State private var renameTarget: RemoteEntry?
    @State private var renameName = ""
    @State private var showPlaces = false
    @State private var keyMonitor: PaneKeyMonitor?
    @State private var macDropTargeted = false
    @State private var deviceDropTargeted = false
    @FocusState private var searchFocused: Bool
    /// PRD §25「Reduce Motion：进度动画退化」。系统打开「减弱动态效果」后，
    /// 位移类动画一律退化成无动画（淡入淡出保留 —— 它不引起前庭不适）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .alert("重命名", isPresented: $showRename, presenting: renameTarget) { target in
            TextField("名称", text: $renameName)
            Button("取消", role: .cancel) {
                renameTarget = nil
                renameName = ""
            }
            Button("重命名") {
                let name = renameName
                renameTarget = nil
                renameName = ""
                Task { await model.renameRemoteEntry(target, to: name) }
            }
            // 名称不合法时直接禁用提交，而不是让用户提交完再吃一个报错。
            .disabled(AppModel.validateRemoteName(renameName) != nil)
        } message: { target in
            Text("把「\(target.name)」重命名（留在同一目录）")
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
                // PRD §25 动态字体：给的是下限而不是定宽，否则大字号下「Finder 位置」会截断。
                .frame(minWidth: 130)
            }
            .onTapGesture { model.focus = .mac }

            Divider()

            if model.macSource == .files {
                fileNavigationBar
                Divider()
                switch model.viewMode(for: .mac) {
                case .list:
                    EntryTable(
                        entries: macEntries,
                        selection: $model.localSelection,
                        emptyMessage: macEmptyMessage,
                        onOpen: openMacEntry,
                        onReveal: revealMacEntry,
                        onUpload: { Task { await model.uploadSelection() } },
                        onRefresh: { model.reloadLocal() },
                        dragSide: .local,
                        foldersFirst: model.settings.foldersFirst
                    )
                case .grid:
                    EntryGrid(
                        entries: macEntries,
                        selection: $model.localSelection,
                        emptyMessage: macEmptyMessage,
                        iconSize: model.settings.gridIconSize,
                        thumbnails: model.thumbnails,
                        onOpen: openMacEntry,
                        onReveal: revealMacEntry,
                        onUpload: uploadLocalEntries,
                        onRefresh: { model.reloadLocal() },
                        dragSide: .local,
                        foldersFirst: model.settings.foldersFirst
                    )
                case .column:
                    EntryColumns(
                        rootPath: model.localDirectory.path,
                        selection: $model.localSelection,
                        currentDirectory: $model.localColumnDirectory,
                        listChildren: { path in
                            await model.browserChildren(path: path, origin: .local)
                        },
                        onOpenFile: openMacEntry
                    )
                }
                // PRD §13.2：分栏视图的路径栏在窗格**底部**。列表 / 网格沿用顶栏面包屑。
                if model.viewMode(for: .mac) == .column {
                    columnPathBar
                }
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

            // 分栏模式的路径栏在窗格底部（PRD §13.2），顶栏就不再重复一条面包屑。
            if model.viewMode(for: .mac) != .column {
                PathBreadcrumb(items: model.localBreadcrumbs.map { item in (item.0, { model.navigateLocal(to: item.1) }) })
            }

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
                    .foregroundStyle(.secondary)
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
                .frame(minWidth: 92)
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

                // 分栏模式的路径栏在窗格底部（PRD §13.2）。
                if model.viewMode(for: .device) != .column {
                    PathBreadcrumb(items: remoteBreadcrumbItems)
                }

                Spacer()

                if model.remoteLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            switch model.viewMode(for: .device) {
            case .list:
                EntryTable(
                    entries: model.visibleRemoteEntries.map(BrowserEntry.init(remote:)),
                    selection: $model.remoteSelection,
                    emptyMessage: deviceEmptyMessage,
                    onOpen: openRemoteEntry,
                    onDelete: { showDeleteConfirm = true },
                    onDownload: { Task { await model.downloadSelection() } },
                    onNewFolder: { showNewFolder = true },
                    onRefresh: { Task { await model.loadRemote() } },
                    onRename: beginRename,
                    dragSide: .remote,
                    foldersFirst: model.settings.foldersFirst
                )
            case .grid:
                EntryGrid(
                    entries: model.visibleRemoteEntries.map(BrowserEntry.init(remote:)),
                    selection: $model.remoteSelection,
                    emptyMessage: deviceEmptyMessage,
                    iconSize: model.settings.gridIconSize,
                    thumbnails: model.thumbnails,
                    onOpen: openRemoteEntry,
                    onDownload: downloadRemoteEntries,
                    onDelete: confirmDeleteRemoteEntries,
                    onNewFolder: { showNewFolder = true },
                    onRefresh: { Task { await model.loadRemote() } },
                    onRename: beginRename,
                    dragSide: .remote,
                    foldersFirst: model.settings.foldersFirst
                )
            case .column:
                EntryColumns(
                    rootPath: model.remoteDirectory,
                    selection: $model.remoteSelection,
                    currentDirectory: $model.remoteColumnDirectory,
                    listChildren: { path in
                        await model.browserChildren(path: path, origin: .remote)
                    },
                    onOpenFile: openRemoteFile
                )
            }

            if model.viewMode(for: .device) == .column {
                remoteColumnPathBar
            }

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
                        .foregroundStyle(.secondary)
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

        // PRD §10：工具栏左＝视图切换，作用于**聚焦窗格**。三段齐了（分栏已在 Phase 3.2 落地）。
        ToolbarItem(placement: .navigation) {
            Picker("浏览形态", selection: viewModeBinding) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.systemImage)
                        .tag(mode)
                        .accessibilityLabel(mode.label)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minWidth: 116)
            .help("切换聚焦窗格的浏览形态（⌘1 列表 / ⌘2 分栏 / ⌘3 网格）")
        }

        // PRD §10 要求 ⇄ 居中。放在两栏之间语义上也对 —— 它交换的正是这两栏。
        ToolbarItem(placement: .principal) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { model.swapPanes() }
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
                .frame(minWidth: 130)

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

    private var viewModeBinding: Binding<ViewMode> {
        Binding(
            get: { model.focusedViewMode },
            set: { model.setViewMode($0, for: model.focus) }
        )
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
            // Reduce Motion：只保留淡入淡出，去掉从顶部滑入的位移。
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
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

    // MARK: - 窗格动作（列表与网格共用）

    /// 下面这几个把 `BrowserEntry` 映射回 `AppModel` 的类型。
    ///
    /// 一律**由 `BrowserEntry` 现场还原**，而不是去 `model.localEntries` /
    /// `remoteEntries` 里按 id 反查：列视图选中的条目可能位于**子目录**里，根本不在
    /// 当前目录的列表中，反查会静默取不到。

    private func openMacEntry(_ entry: BrowserEntry) {
        if entry.isDirectory {
            model.navigateLocal(to: URL(fileURLWithPath: entry.path))
        } else {
            model.openLocalEntry(localEntry(from: entry))
        }
    }

    private func revealMacEntry(_ entry: BrowserEntry) {
        model.revealInFinder(localEntry(from: entry))
    }

    private func openRemoteEntry(_ entry: BrowserEntry) {
        guard entry.isDirectory else { return }
        Task { await model.navigateRemote(to: entry.path) }
    }

    /// 分栏视图里双击设备端文件 = 预览（文件夹由 NSBrowser 自己展开，不会走到这）。
    private func openRemoteFile(_ entry: BrowserEntry) {
        model.previewRemote(remoteEntry(from: entry))
    }

    private func localEntry(from entry: BrowserEntry) -> LocalEntry {
        LocalEntry(
            name: entry.name,
            url: URL(fileURLWithPath: entry.path),
            isDirectory: entry.isDirectory,
            isSymlink: entry.isSymlink,
            size: entry.size,
            modified: entry.modified
        )
    }

    private func remoteEntry(from entry: BrowserEntry) -> RemoteEntry {
        RemoteEntry(
            name: entry.name,
            path: entry.path,
            isDirectory: entry.isDirectory,
            isSymlink: entry.isSymlink,
            size: entry.size,
            modified: entry.modified
        )
    }

    // MARK: - 分栏视图的底部路径栏（PRD §13.2）

    /// Mac 窗格。列表 / 网格的面包屑在顶栏，分栏的在底部 —— PRD §13.2 明文。
    private var columnPathBar: some View {
        let path = model.localColumnDirectory.isEmpty ? model.localDirectory.path : model.localColumnDirectory
        let items = AppModel.localBreadcrumbs(for: URL(fileURLWithPath: path)).map { item in
            (item.0, { model.navigateLocal(to: item.1) })
        }
        return pathBar(items)
    }

    private var remoteColumnPathBar: some View {
        let path = model.remoteColumnDirectory.isEmpty ? model.remoteDirectory : model.remoteColumnDirectory
        let items = AppModel.remoteBreadcrumbs(for: path).map { item -> (String, () -> Void) in
            let target = item.1
            return (item.0, { Task { await model.navigateRemote(to: target) } })
        }
        return pathBar(items)
    }

    private func pathBar(_ items: [(String, () -> Void)]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.tertiary)
            PathBreadcrumb(items: items)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.25))
    }

    private func downloadRemoteEntries(_ entries: [BrowserEntry]) {
        let targets = entries.compactMap { entry in
            model.remoteEntries.first { $0.path == entry.path }
        }
        guard !targets.isEmpty else { return }
        Task { await model.downloadEntries(targets, toDirectory: model.localDirectory) }
    }

    /// 网格里「上传到设备」的显式目标版本。
    ///
    /// 只取 `.local`：照片图库条目的 `path` 是 `localIdentifier`，当文件路径用会指错。
    private func uploadLocalEntries(_ entries: [BrowserEntry]) {
        let urls = entries.filter { $0.origin == .local }.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        Task { await model.uploadFiles(urls, toRemotePath: model.remoteDirectory) }
    }

    /// 网格里删除前先把选择对齐到右键的那一项，再走既有的确认弹窗。
    ///
    /// 复用确认弹窗（它读 `model.remoteSelection`）而不是另做一套，顺带让被右键的
    /// 项拿到选中高亮 —— 与 Finder 右键的行为一致。
    private func confirmDeleteRemoteEntries(_ entries: [BrowserEntry]) {
        model.remoteSelection = Set(entries.map(\.id))
        showDeleteConfirm = true
    }

    /// 右键「重命名…」：预填原名，并把这个条目设为选中（与 Finder 一致）。
    private func beginRename(_ entry: BrowserEntry) {
        let target = remoteEntry(from: entry)
        model.remoteSelection = [target.id]
        renameTarget = target
        renameName = target.name
        showRename = true
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
        .frame(minWidth: 290)
    }

    private func sectionHeader<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
