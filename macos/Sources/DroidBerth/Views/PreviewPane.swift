import SwiftUI

/// 预览窗格（PRD §11 的「显示预览窗格 ⇧⌘P」）。
///
/// 三个刻意的设计决定：
///
/// 1. **放在窗口右缘（Finder 的约定），但显示的是「聚焦窗格」的选中项。**
///    双栏工具里如果做成「每个窗格各带一个预览栏」，横向空间会被吃掉两次。
///    头部写明来源（这台 Mac / 照片图库 / 设备名），免得被误当成设备栏的附属。
/// 2. **开关式、默认关。** 它是一栏常驻宽度，不该替用户决定要不要占。这也正是它
///    与 §3.2 被否掉的常驻侧边栏的区别 —— 那个是「永远在」，这个是「你可以关」。
/// 3. **绝不触发完整下载。** 缩略图只走 `ThumbnailStore` 的 64 KB 文件头通道；
///    完整下载仍然只由「空格 Quick Look」和「下载到 Mac」触发。
struct PreviewPane: View {
    @Bindable var model: AppModel

    private let width: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
            }
        }
        .frame(width: width)
        .background(.quaternary.opacity(0.18))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("预览")
                .font(.headline)
                .fontWeight(.medium)
            Spacer(minLength: 6)
            Text(model.previewOwner)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        let summary = model.previewSummary
        if summary.entries.isEmpty {
            emptyState
        } else if let single = summary.single {
            singleItem(single, summary: summary)
        } else {
            multiItem(summary)
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.dashed")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("未选中项目")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("选中一个文件或文件夹，这里会显示它的信息")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 48)
    }

    // MARK: - 单个条目

    private func singleItem(_ entry: BrowserEntry, summary: AppModel.PreviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail(entry)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(3)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.kindLabel)
                        .font(.caption)
                        .foregroundStyle(Color.columnText)
                    Text(ByteFormat.size(entry.size))
                        .font(.caption)
                        .foregroundStyle(Color.columnText)
                        .monospacedDigit()
                    Text(ByteFormat.date(entry.modified))
                        .font(.caption)
                        .foregroundStyle(Color.columnText)
                }

                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Spacer(minLength: 16)

            transferAction(summary)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    // MARK: - 多选

    private func multiItem(_ summary: AppModel.PreviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3))
                Text("\(summary.count)")
                    .font(.system(size: 34))
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(height: 110)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("已选 \(summary.count) 个项目")
                    .font(.callout)
                    .fontWeight(.medium)

                // 合计只算「知道大小」的那些，并把未知的单独说出来 ——
                // 给一个偏小的合计数字比不给更糟（用户会据此判断这一批有多重）。
                if summary.knownBytes > 0 {
                    Text("合计 \(ByteFormat.size(summary.knownBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("\(summary.directoryCount) 个文件夹 · \(summary.fileCount) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if summary.unknownSizeCount > 0 {
                    Text("含 \(summary.unknownSizeCount) 个大小未知")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Spacer(minLength: 16)

            transferAction(summary)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    // MARK: - 缩略图

    @ViewBuilder
    private func thumbnail(_ entry: BrowserEntry) -> some View {
        Group {
            switch model.thumbnails.state(for: entry) {
            case .loaded(let image):
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loading:
                placeholder(entry, showsSpinner: true)

            case .idle, .unavailable:
                placeholder(entry, showsSpinner: false)
            }
        }
        // 选中项换了就要重新请一次缩略图 —— `.id` 让 SwiftUI 把新条目当成新视图，
        // `onAppear` 才会再触发。少了这一条，换选之后预览会一直停在旧缩略图上。
        .id(entry.id)
        .onAppear { model.thumbnails.request(entry) }
    }

    private func placeholder(_ entry: BrowserEntry, showsSpinner: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3))
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else {
                EntryIconView(entry: entry, size: 52)
            }
        }
    }

    // MARK: - 传输按钮

    /// **按来源给一个**按钮，而不是两个都给 —— 预览栏里出现用不上的按钮只是噪音。
    ///
    /// 动作直接复用工具栏那两条路径（`uploadSelection` / `downloadSelection`），
    /// 因此落点分流、冲突策略、记住上次目录的行为与工具栏完全一致。
    @ViewBuilder
    private func transferAction(_ summary: AppModel.PreviewSummary) -> some View {
        switch summary.pane {
        case .mac:
            Button(summary.count == 1 ? "上传到设备" : "上传 \(summary.count) 个到设备") {
                Task { await model.uploadSelection() }
            }
            .disabled(model.activeDevice == nil || model.uploadSelectionCount == 0)

        case .device:
            Button(summary.count == 1 ? "下载到 Mac" : "下载 \(summary.count) 个到 Mac") {
                Task { await model.downloadSelection() }
            }
            .disabled(model.activeDevice == nil)
        }
    }
}
