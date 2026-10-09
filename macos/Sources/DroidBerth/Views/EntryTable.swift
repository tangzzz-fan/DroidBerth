import SwiftUI

struct EntryTable: View {
    let entries: [BrowserEntry]
    @Binding var selection: Set<String>
    let emptyMessage: String
    let onOpen: (BrowserEntry) -> Void
    var onReveal: ((BrowserEntry) -> Void)?
    var onDelete: (() -> Void)?
    var onDownload: (() -> Void)?
    var onUpload: (() -> Void)?
    var onRefresh: (() -> Void)?
    /// 非 nil 时该表格的行可被拖拽，载荷按此侧标记（PRD §24）。
    /// 照片来源传 nil —— 图库条目不是文件路径，不参与拖拽。
    var dragSide: TransferDragPayload.Side?

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label(emptyMessage, systemImage: "tray")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(entries, selection: $selection) {
                TableColumn("名称") { entry in
                    draggableCell(entry) {
                        HStack(spacing: 6) {
                            Image(systemName: entry.systemImage)
                                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                                .frame(width: 16)
                            Text(entry.name).lineLimit(1)
                        }
                    }
                }
                .width(min: 180, ideal: 280)

                TableColumn("种类") { entry in
                    draggableCell(entry) {
                        Text(entry.kindLabel).foregroundStyle(.secondary)
                    }
                }
                .width(min: 70, ideal: 90)

                TableColumn("大小") { entry in
                    draggableCell(entry) {
                        Text(ByteFormat.size(entry.size))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 70, ideal: 90)

                TableColumn("修改日期") { entry in
                    draggableCell(entry) {
                        Text(ByteFormat.date(entry.modified))
                            .foregroundStyle(.secondary)
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
                    Divider()
                }
                if let onDownload, allRemote {
                    Button("下载到 Mac") { onDownload() }
                }
                if let onUpload, !picked.isEmpty, noRemote {
                    Button("上传到设备") { onUpload() }
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
            Image(systemName: entry.systemImage)
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
