import Foundation

enum ConflictPolicy: String, CaseIterable, Sendable {
    case keepBoth
    case overwrite

    var label: String {
        switch self {
        case .keepBoth: "保留两者"
        case .overwrite: "覆盖"
        }
    }
}

/// 窗格的浏览形态（PRD §13）。
enum ViewMode: String, CaseIterable, Sendable {
    case list
    case column
    case grid

    var label: String {
        switch self {
        case .list: "列表"
        case .column: "分栏"
        case .grid: "网格"
        }
    }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .column: "rectangle.split.3x1"
        case .grid: "square.grid.2x2"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    var concurrency: Int {
        didSet { defaults.set(concurrency, forKey: Key.concurrency) }
    }

    var conflictPolicy: ConflictPolicy {
        didSet { defaults.set(conflictPolicy.rawValue, forKey: Key.conflictPolicy) }
    }

    var routingEnabled: Bool {
        didSet { defaults.set(routingEnabled, forKey: Key.routingEnabled) }
    }

    var rememberLastDestination: Bool {
        didSet { defaults.set(rememberLastDestination, forKey: Key.rememberLastDestination) }
    }

    var scanAfterTransfer: Bool {
        didSet { defaults.set(scanAfterTransfer, forKey: Key.scanAfterTransfer) }
    }

    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// 传输面板固定（PRD §14）：固定后即使队列为空也常驻，且不自动折叠。
    var transferPanelPinned: Bool {
        didSet { defaults.set(transferPanelPinned, forKey: Key.transferPanelPinned) }
    }

    /// 列表里文件夹是否排在最前（PRD §13.1：默认开启，可在设置里关）。
    var foldersFirst: Bool {
        didSet { defaults.set(foldersFirst, forKey: Key.foldersFirst) }
    }

    /// 左右窗格是否互换（PRD §10「交换两侧」）。布局偏好，跨启动保留。
    var panesSwapped: Bool {
        didSet { defaults.set(panesSwapped, forKey: Key.panesSwapped) }
    }

    /// Mac 窗格的浏览形态（PRD §13.3）。按窗格独立：双栏两侧的形态互不牵连。
    var macViewMode: ViewMode {
        didSet { defaults.set(macViewMode.rawValue, forKey: Key.macViewMode) }
    }

    /// 设备窗格的浏览形态（PRD §13.3）。
    var deviceViewMode: ViewMode {
        didSet { defaults.set(deviceViewMode.rawValue, forKey: Key.deviceViewMode) }
    }

    /// 网格图标边长（pt），PRD §13.3 的 ⌘+ / ⌘- 调整对象。
    var gridIconSize: Double {
        didSet { defaults.set(gridIconSize, forKey: Key.gridIconSize) }
    }

    /// 预览窗格（PRD §11「显示预览窗格 ⇧⌘P」）。**默认关** —— 它是一栏常驻宽度，
    /// 不该替用户决定要不要占。开关状态跨启动保留。
    var showPreviewPane: Bool {
        didSet { defaults.set(showPreviewPane, forKey: Key.showPreviewPane) }
    }

    /// 图标尺寸的上下限与步进。
    ///
    /// 下限 72 保证文件名还能读；上限 240 是「一屏正好铺 8～10 个」的素材浏览档位。
    /// 再大只会让每行只剩两三个，失去俯视整卷的意义。
    static let gridIconSizeRange: ClosedRange<Double> = 72...240
    static let gridIconSizeStep: Double = 24

    func adjustGridIconSize(by delta: Double) {
        let range = Self.gridIconSizeRange
        let clamped = min(max(gridIconSize + delta, range.lowerBound), range.upperBound)
        if clamped != gridIconSize { gridIconSize = clamped }
    }

    var canEnlargeGridIcons: Bool { gridIconSize < Self.gridIconSizeRange.upperBound }
    var canShrinkGridIcons: Bool { gridIconSize > Self.gridIconSizeRange.lowerBound }

    // 「最近使用的 Mac 文件夹」原本在这里（`recentLocalFolders`，存的是**路径**）。
    //
    // 2026-10-12 删掉，统一到 `BookmarkedFolders`（存 security-scoped bookmark）：
    // 沙盒版**只有书签**能带用户到容器外的目录，而路径在沙盒里根本读不了 ——
    // 两套并存就是同一个概念的两种实现，且只有一套在沙盒里有效。
    //
    // 旧的 UserDefaults 键 `list.recentLocalFolders` 不主动清理：残留数据无害，
    // 而且删用户数据这种事不该由一个「整理代码」的改动顺手做掉。

    private var lastDestination: [String: String] {
        didSet { defaults.set(lastDestination, forKey: Key.lastDestination) }
    }

    private var wirelessAddress: [String: String] {
        didSet { defaults.set(wirelessAddress, forKey: Key.wirelessAddress) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedConcurrency = defaults.integer(forKey: Key.concurrency)
        concurrency = storedConcurrency > 0 ? storedConcurrency : 4
        conflictPolicy = ConflictPolicy(rawValue: defaults.string(forKey: Key.conflictPolicy) ?? "") ?? .keepBoth
        routingEnabled = defaults.object(forKey: Key.routingEnabled) as? Bool ?? true
        rememberLastDestination = defaults.object(forKey: Key.rememberLastDestination) as? Bool ?? true
        scanAfterTransfer = defaults.object(forKey: Key.scanAfterTransfer) as? Bool ?? true
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        transferPanelPinned = defaults.object(forKey: Key.transferPanelPinned) as? Bool ?? false
        foldersFirst = defaults.object(forKey: Key.foldersFirst) as? Bool ?? true
        panesSwapped = defaults.object(forKey: Key.panesSwapped) as? Bool ?? false
        macViewMode = ViewMode(rawValue: defaults.string(forKey: Key.macViewMode) ?? "") ?? .list
        deviceViewMode = ViewMode(rawValue: defaults.string(forKey: Key.deviceViewMode) ?? "") ?? .list
        let storedIconSize = defaults.double(forKey: Key.gridIconSize)
        gridIconSize = storedIconSize > 0 ? storedIconSize : 112
        showPreviewPane = defaults.object(forKey: Key.showPreviewPane) as? Bool ?? false
        lastDestination = defaults.dictionary(forKey: Key.lastDestination) as? [String: String] ?? [:]
        wirelessAddress = defaults.dictionary(forKey: Key.wirelessAddress) as? [String: String] ?? [:]
    }

    func destination(for serial: String) -> String? {
        lastDestination[serial]
    }

    func rememberDestination(_ path: String, for serial: String) {
        guard rememberLastDestination else { return }
        lastDestination[serial] = path
    }

    func address(for serial: String) -> String? {
        wirelessAddress[serial]
    }

    func rememberAddress(_ address: String, for serial: String) {
        wirelessAddress[serial] = address
    }

    func forgetAddress(for serial: String) {
        wirelessAddress.removeValue(forKey: serial)
    }

    var rememberedWirelessDevices: [(serial: String, address: String)] {
        wirelessAddress.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    private enum Key {
        static let concurrency = "transfer.concurrency"
        static let conflictPolicy = "transfer.conflictPolicy"
        static let routingEnabled = "transfer.routingEnabled"
        static let rememberLastDestination = "transfer.rememberLastDestination"
        static let scanAfterTransfer = "media.scanAfterTransfer"
        static let appearance = "ui.appearance"
        static let transferPanelPinned = "ui.transferPanelPinned"
        static let foldersFirst = "list.foldersFirst"
        static let panesSwapped = "ui.panesSwapped"
        static let macViewMode = "view.mac"
        static let deviceViewMode = "view.device"
        static let gridIconSize = "view.gridIconSize"
        static let showPreviewPane = "view.showPreviewPane"
        // `list.recentLocalFolders`（旧的「最近使用」）随该功能一起删除 —— 见上方注释。
        static let lastDestination = "device.lastDestination"
        static let wirelessAddress = "device.wirelessAddress"
    }
}
