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

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label(emptyMessage, systemImage: "tray")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(entries, selection: $selection) {
                TableColumn("名称") { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.systemImage)
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        Text(entry.name).lineLimit(1)
                    }
                }
                .width(min: 180, ideal: 280)

                TableColumn("种类") { entry in
                    Text(entry.kindLabel).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90)

                TableColumn("大小") { entry in
                    Text(ByteFormat.size(entry.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90)

                TableColumn("修改日期") { entry in
                    Text(ByteFormat.date(entry.modified))
                        .foregroundStyle(.secondary)
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
}
