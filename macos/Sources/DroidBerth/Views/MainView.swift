import SwiftUI

@MainActor
struct MainView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            DeviceBar(model: model, onEnableWireless: {
                Task { await model.enableWireless() }
            }, onReconnect: {
                Task { await model.reconnectWireless() }
            })
            Divider()

            HSplitView {
                macPane
                    .frame(minWidth: 340)
                devicePane
                    .frame(minWidth: 340)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !model.queue.isEmpty {
                Divider()
                TransferPanel(queue: model.queue)
            }
        }
        .overlay(alignment: .top) { bannerOverlay }
        .toolbar { toolbar }
        .task {
            AppearanceController.apply(model.settings.appearance)
            model.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .droidBerthNewFolder)) { _ in
            guard model.activeDevice != nil else { return }
            showNewFolder = true
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
    }

    // MARK: - 顶部设备栏

    private struct DeviceBar: View {
        @Bindable var model: AppModel
        let onEnableWireless: () -> Void
        let onReconnect: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(.secondary)

                if model.monitor.usableDevices.isEmpty {
                    devicePlaceholder
                } else {
                    Picker("", selection: Binding(
                        get: { model.monitor.selectedSerial ?? "" },
                        set: { model.monitor.selectedSerial = $0 }
                    )) {
                        ForEach(model.monitor.usableDevices) { device in
                            Text("\(device.displayName) · \(device.connectionLabel)").tag(device.serial)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)

                    if let device = model.activeDevice {
                        Text(device.serial)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if device.isWireless {
                            Label("无线", systemImage: "wifi")
                                .font(.caption)
                                .foregroundStyle(.teal)
                        }
                    }
                }

                Spacer()

                if model.wireless.busy {
                    ProgressView().controlSize(.small)
                }

                if let device = model.activeDevice, !device.isWireless {
                    Button("启用无线连接") { onEnableWireless() }
                        .controlSize(.small)
                        .disabled(model.wireless.busy)
                }

                if model.activeDevice == nil, !model.settings.rememberedWirelessDevices.isEmpty {
                    Button("尝试无线重连") { onReconnect() }
                        .controlSize(.small)
                }

                Button {
                    Task { await model.monitor.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新检测设备")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }

        @ViewBuilder
        private var devicePlaceholder: some View {
            switch model.monitor.status {
            case .sidecarMissing:
                Label("找不到 sidecar，请重新构建 app", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .adbMissing:
                Label("app 包内缺少 adb 可执行文件", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .idle:
                if let unauthorized = model.monitor.devices.first(where: { $0.state == .unauthorized }) {
                    Label("\(unauthorized.displayName) 未授权", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                    Text("请在手机上勾选「始终允许」后点确定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("未检测到 Android 设备", systemImage: "cable.connector")
                        .foregroundStyle(.secondary)
                    Text("请用数据线连接手机，并在手机上允许 USB 调试")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
                    emptyMessage: model.localError ?? "这个文件夹是空的",
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
                    onRefresh: { model.reloadLocal() }
                )
                localStatusBar
            } else {
                PhotoSourceView(model: model)
            }
        }
        .background(model.focus == .mac ? Color.accentColor.opacity(0.06) : Color.clear)
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

            Menu {
                ForEach(LocalFileSystem.places()) { place in
                    Button(place.name) { model.navigateLocal(to: place.url, resetHistory: true) }
                }
                Divider()
                Button("其它…") { chooseLocalFolder() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)

            PathBreadcrumb(items: model.localBreadcrumbs.map { item in (item.0, { model.navigateLocal(to: item.1) }) })

            Spacer()

            Toggle("隐藏文件", isOn: $model.showHiddenFiles)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
        model.localEntries.map(\.asBrowserEntry)
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
                entries: model.remoteEntries.map(BrowserEntry.init(remote:)),
                selection: $model.remoteSelection,
                emptyMessage: model.remoteError ?? (model.activeDevice == nil ? "未连接设备" : "这个文件夹是空的"),
                onOpen: { entry in
                    guard let remote = model.remoteEntries.first(where: { $0.id == entry.id }) else { return }
                    if remote.isDirectory {
                        Task { await model.navigateRemote(to: remote.path) }
                    }
                },
                onDelete: { showDeleteConfirm = true },
                onDownload: { Task { await model.downloadSelection() } },
                onRefresh: { Task { await model.loadRemote() } }
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
        .background(model.focus == .device ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    // MARK: - 工具栏与提示

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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

            Divider()

            Button {
                showNewFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            .disabled(model.activeDevice == nil)
            .help("在设备当前目录下新建文件夹（⇧⌘N）")

            Button {
                Task { await model.scanRemoteSelection() }
            } label: {
                Label("刷新媒体库", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.remoteSelection.isEmpty || model.activeDevice == nil)
            .help("让设备端相册重新索引选中的文件")

            Button {
                showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
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
