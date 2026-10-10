import SwiftUI

struct EntryTable: View {
    let entries: [BrowserEntry]
    @Binding var selection: Set<String>
    /// 空态的结构化描述（图标 + 文案 + 可选动作）。改造前这里是一个字符串，
    /// 于是四类语义不同的空态共用一个 `tray` 图标，且**挂不上按钮**。
    let emptyState: PaneEmptyState
    let onOpen: (BrowserEntry) -> Void
    var onReveal: ((BrowserEntry) -> Void)?
    var onDelete: (() -> Void)?
    var onDownload: (() -> Void)?
    var onUpload: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onRefresh: (() -> Void)?
    /// 设备端重命名（PRD §13.1）。只对单选且 `.remote` 的条目出现。
    var onRename: ((BrowserEntry) -> Void)?
    /// 非 nil 时该表格的行可被拖拽，载荷按此侧标记（PRD §24）。
    /// 照片来源传 nil —— 图库条目不是文件路径，不参与拖拽。
    var dragSide: TransferDragPayload.Side?
    /// 文件夹排在最前（PRD §13.1，默认开启，可在设置里关）。
    var foldersFirst: Bool = true

    /// 名称列用 Finder 的本地化比较，而不是字典序 —— 否则 "Zebra" 会排在 "apple" 前。
    @State private var sortOrder: [KeyPathComparator<BrowserEntry>] = [
        KeyPathComparator(\BrowserEntry.name, comparator: .localizedStandard)
    ]

    var body: some View {
        if entries.isEmpty {
            PaneEmptyStateView(state: emptyState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(sortedEntries, selection: $selection, sortOrder: sortOrderBinding) {
                TableColumn("名称", value: \.name) { entry in
                    draggableCell(entry) {
                        HStack(spacing: 6) {
                            EntryIconView(entry: entry, size: 16)
                            Text(entry.name).lineLimit(1)
                        }
                    }
                }
                .width(min: 180, ideal: 280)

                TableColumn("种类", value: \.kindLabel) { entry in
                    draggableCell(entry) {
                        Text(entry.kindLabel).foregroundStyle(Color.columnText)
                    }
                }
                .width(min: 70, ideal: 90)

                TableColumn("大小", value: \.sortableSize) { entry in
                    draggableCell(entry) {
                        Text(ByteFormat.size(entry.size))
                            .monospacedDigit()
                            .foregroundStyle(Color.columnText)
                    }
                }
                .width(min: 70, ideal: 90)

                TableColumn("修改日期", value: \.sortableModified) { entry in
                    draggableCell(entry) {
                        Text(ByteFormat.date(entry.modified))
                            .foregroundStyle(Color.columnText)
                    }
                }
                .width(min: 110, ideal: 140)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let picked = entries.filter { ids.contains($0.id) }
                let allRemote = !picked.isEmpty && picked.allSatisfy { $0.origin == .remote }
                let noRemote = picked.allSatisfy { $0.origin != .remote }

                if picked.count == 1, let entry = picked.first {
                    Button("打开") { onOpen(entry) }
                    if let onReveal, entry.origin == .local {
                        Button("在 Finder 中显示") { onReveal(entry) }
                    }
                    if let onRename, entry.origin == .remote {
                        Button("重命名…") { onRename(entry) }
                    }
                    Divider()
                }
                if let onDownload, allRemote {
                    Button("下载到 Mac") { onDownload() }
                }
                if let onUpload, !picked.isEmpty, noRemote {
                    Button("上传到设备") { onUpload() }
                }
                if let onNewFolder, picked.isEmpty {
                    Button("新建文件夹…") { onNewFolder() }
                }
                if let onRefresh, picked.isEmpty {
                    Button("刷新") { onRefresh() }
                }
                if let onDelete, allRemote {
                    Divider()
                    Button("删除…", role: .destructive) { onDelete() }
                }
            } primaryAction: { ids in
                guard ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return }
                onOpen(entry)
            }
        }
    }

    // MARK: - 排序

    /// 文件夹优先 + 用户选择的列 + 名称兜底。
    ///
    /// 排序必须自己做：`Table` 拿到 `sortOrder` 只负责画箭头，不会重排数据。
    /// 用单个比较器而不是「先排序再二次稳定排序」，是为了不依赖 `sorted(by:)`
    /// 的稳定性（Swift 未承诺稳定）。
    private var sortedEntries: [BrowserEntry] {
        let comparators = sortOrder
        return entries.sorted { lhs, rhs in
            if foldersFirst, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            for comparator in comparators {
                switch comparator.compare(lhs, rhs) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 点击列头时 `Table` 会用**默认比较器**重建 comparator（名称列会退化成
    /// 大小写敏感的字典序）。这里把名称列换回本地化比较，其余列原样透传。
    private var sortOrderBinding: Binding<[KeyPathComparator<BrowserEntry>]> {
        Binding(
            get: { sortOrder },
            set: { updated in
                sortOrder = updated.map { comparator in
                    guard comparator.keyPath == \BrowserEntry.name else { return comparator }
                    return KeyPathComparator(
                        \BrowserEntry.name,
                        comparator: .localizedStandard,
                        order: comparator.order
                    )
                }
            }
        )
    }

    // MARK: - 拖拽

    /// 每一列的单元格都挂同一个拖拽载荷，因此从行内任意位置都能发起拖拽，
    /// 而不只是「名称」列。
    @ViewBuilder
    private func draggableCell<Content: View>(
        _ entry: BrowserEntry,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let payload = payload(for: entry) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .draggable(payload) {
                    dragPreview(for: entry, count: payload.paths.count)
                }
        } else {
            content()
        }
    }

    private func payload(for entry: BrowserEntry) -> TransferDragPayload? {
        guard let dragSide else { return nil }
        // 拖的若是选中项之一，带上整个选择；否则只拖这一行（与 Finder 一致）
        let ids = selection.contains(entry.id) ? selection : [entry.id]
        let picked = entries.filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return nil }
        return TransferDragPayload(side: dragSide, origin: .pane, paths: picked.map(\.path))
    }

    /// 多选时在拖拽预览上显示数量徽章（PRD §24）。
    private func dragPreview(for entry: BrowserEntry, count: Int) -> some View {
        HStack(spacing: 6) {
            EntryIconView(entry: entry, size: 16)
            Text(count == 1 ? entry.name : "\(count) 个项目")
                .font(.callout)
                .lineLimit(1)
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
