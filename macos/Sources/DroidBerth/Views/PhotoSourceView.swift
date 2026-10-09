import AppKit
@preconcurrency import Photos
import SwiftUI

struct PhotoSourceView: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.photos.access {
        case .authorized, .limited:
            library
        case .denied, .restricted:
            deniedView
        case .unknown:
            promptView
        }
    }

    // MARK: - 主界面

    private var library: some View {
        VStack(spacing: 0) {
            if model.photos.access == .limited {
                limitedBar
                Divider()
            }

            HStack(spacing: 0) {
                albumList
                    .frame(width: 168)
                Divider()
                VStack(spacing: 0) {
                    // 照片图库沿用 Mac 窗格的浏览形态设置（PRD §13「两侧各自支持
                    // 列表/网格视图」）。**缩略图暂缺**：图库条目的 path 是
                    // localIdentifier，缩略图要走 PhotoKit 的 PHImageManager，
                    // 不在本轮范围内 —— 网格里先回退类型图标，见改造方案 §4.1。
                    switch model.viewMode(for: .mac) {
                    case .list:
                        EntryTable(
                            entries: model.photos.items.map(\.asBrowserEntry),
                            selection: $model.photoSelection,
                            emptyMessage: photosEmptyMessage,
                            onOpen: { _ in },
                            onUpload: { Task { await model.uploadSelection() } },
                            onRefresh: { Task { await model.photos.loadItems() } }
                        )
                    case .grid:
                        EntryGrid(
                            entries: model.photos.items.map(\.asBrowserEntry),
                            selection: $model.photoSelection,
                            emptyMessage: photosEmptyMessage,
                            iconSize: model.settings.gridIconSize,
                            thumbnails: model.thumbnails,
                            onOpen: { _ in },
                            onUpload: { entries in
                                // 网格右键上传：先把选择对齐到目标，再走既有的
                                // 「导出 → 推送」链路，不另写一套照片导出。
                                model.photoSelection = Set(entries.map(\.id))
                                Task { await model.uploadSelection() }
                            },
                            onRefresh: { Task { await model.photos.loadItems() } },
                            foldersFirst: false
                        )
                    }
                    statusBar
                }
            }
        }
        .task {
            if model.photos.albums.isEmpty {
                await model.photos.loadAlbums()
            }
        }
    }

    private var albumList: some View {
        List(selection: albumSelection) {
            ForEach(model.photos.albums) { album in
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: album.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(album.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(album.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(album.id)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.photos.loadingAlbums {
                ProgressView().controlSize(.small)
            } else if model.photos.albums.isEmpty {
                Text("没有相簿")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("\(model.photos.items.count) 个项目")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !model.photoSelection.isEmpty {
                Text("已选 \(model.photoSelection.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.photos.loadingItems {
                ProgressView().controlSize(.small)
            }
            exportStatus
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch model.exportPhase {
        case .idle:
            EmptyView()
        case .running(let done, let total, let current):
            HStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 110)
                Text("正在导出 \(done)/\(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !current.isEmpty {
                    Text(current)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140, alignment: .trailing)
                }
            }
        case .finished(let exported, let failed):
            Label(
                failed == 0 ? "已导出 \(exported) 个" : "导出 \(exported) 个，失败 \(failed) 个",
                systemImage: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(failed == 0 ? Color.green : Color.orange)
        }
    }

    // MARK: - 权限

    private var limitedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.plus").foregroundStyle(.orange)
            Text("当前只允许访问部分照片")
                .font(.caption)
            Spacer()
            Button("管理访问范围…") { openPrivacySettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }

    private var deniedView: some View {
        ContentUnavailableView {
            Label("没有照片图库访问权限", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(model.photos.access == .restricted
                 ? "系统策略限制了照片访问，无法读取图库。"
                 : "在「系统设置 → 隐私与安全性 → 照片」里勾选 DroidBerth 后重新打开窗口。")
        } actions: {
            Button("打开系统设置") { openPrivacySettings() }
        }
    }

    private var promptView: some View {
        ContentUnavailableView {
            Label("需要照片图库权限", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("读取照片与视频原始文件需要你的授权。授权后即可把图库里的内容直接推送到 Android 设备。")
        } actions: {
            Button("授权访问") { Task { await model.photos.requestAccess() } }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 绑定

    private var albumSelection: Binding<String?> {
        Binding(
            get: { model.photos.selectedAlbumID },
            set: { model.photos.selectedAlbumID = $0 }
        )
    }

    // MARK: - 动作

    private var photosEmptyMessage: String {
        model.photos.loadError ?? (model.photos.loadingItems ? "正在载入…" : "这个相簿是空的")
    }

    private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func symbol(for kind: PhotoAlbum.Kind) -> String {
        switch kind {
        case .all: "photo.stack"
        case .favorites: "heart"
        case .videos: "film"
        case .screenshots: "camera.viewfinder"
        case .user: "rectangle.stack"
        case .smart: "gearshape.2"
        }
    }
}
