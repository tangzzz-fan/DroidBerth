import AppKit
import SwiftUI

/// 网格视图（PRD §13.3）。
///
/// 与 `EntryTable` 是同一层的两个形态：共享同一份 `selection` 绑定，因此
/// 上传 / 下载 / 删除 / ⌘C⌘V / 空格预览 / 拖拽这些既有能力**不需要改一行**就自动生效
/// —— 它们读的都是 `AppModel.localSelection` / `remoteSelection`。
///
/// 与列表的两处**刻意不同**：
/// - 没有列头，所以没有按列排序。顺序固定为「文件夹优先 + 本地化名称」，即
///   图标视图的既有约定 —— 那份排序由 `GridNavigation.order` 给出，方向键用的是同一份。
/// - 右键菜单按**显式目标**动作，见 `menu(for:)` 的说明。
///
/// 键盘导航（方向键 / 字母跳转 / 回车重命名）由 `PaneKeyMonitor` + `AppModel` 驱动，
/// 这里只负责三件事：**排序**（与模型同一份）、**回报一屏几列**、**把落点滚进视野**。
struct EntryGrid: View {
    let entries: [BrowserEntry]
    @Binding var selection: Set<String>
    /// ⇧ 区间选择与方向键共用的锚点。放在模型里而不是本视图的 `@State`：
    /// 键盘移动是从模型发起的，锚点若留在视图里，鼠标点一次再按 ⇧→ 就会从别处开始。
    @Binding var anchor: String?
    /// 键盘移动后要求滚到可见的条目 id；滚动完成由本视图置回 nil。
    @Binding var scrollTarget: String?
    /// 布局后回报「一屏几列」—— ↑ / ↓ 按它跳一整行，而列数只有在这里才知道。
    let onColumnCountChange: (Int) -> Void
    /// 空态的结构化描述（图标 + 文案 + 可选动作），与列表视图共用同一个类型。
    let emptyState: PaneEmptyState
    /// 网格图标边长（pt），由 ⌘+ / ⌘- 调整（PRD §13.3）。
    let iconSize: Double
    let thumbnails: ThumbnailStore
    let onOpen: (BrowserEntry) -> Void
    var onReveal: ((BrowserEntry) -> Void)?
    var onDownload: (([BrowserEntry]) -> Void)?
    var onUpload: (([BrowserEntry]) -> Void)?
    var onDelete: (([BrowserEntry]) -> Void)?
    var onNewFolder: (() -> Void)?
    var onRefresh: (() -> Void)?
    /// 设备端重命名（PRD §13.1）。只在单选且来源为 `.remote` 时出现。
    var onRename: ((BrowserEntry) -> Void)?
    /// 非 nil 时格子可拖拽，载荷按此侧标记（PRD §24）。
    var dragSide: TransferDragPayload.Side?
    var foldersFirst: Bool = true

    /// 图标两侧留给文件名的宽度。随字号缩放（PRD §25 动态字体）—— 定死的话
    /// 大字号下两行名称会被裁掉。
    @ScaledMetric(relativeTo: .caption) private var labelAllowance: CGFloat = 34

    /// PRD §25：键盘连续移动时若开着「减弱动态效果」，滚进视野也不该有动画。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spacing: CGFloat = 12

    var body: some View {
        if entries.isEmpty {
            PaneEmptyStateView(state: emptyState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVGrid(columns: columns, spacing: spacing) {
                        ForEach(sortedEntries) { entry in
                            cell(entry)
                        }
                    }
                    // 宽度必须在 `.padding(12)` **之前**量：自适应列数用的是网格自己拿到的
                    // 可用宽，量到带内边距的外框会每边多算 12pt。
                    .background(widthReporter)
                    .padding(12)
                    // ⌘+ / ⌘- 只改格子大小、**不改宽度** —— 少这一条，放大图标后列数变了
                    // 而模型里还是旧值，↑ / ↓ 从此跳错行，且不报任何错。
                    .onChange(of: cellWidth) { _, _ in reportColumns(for: measuredWidth) }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        scrollTarget = nil
                    }
                }
            }
            // 点空白处取消选择（与 Finder 图标视图一致）。格子自己的手势在
            // 各自的命中区域里优先，不会把点格子的操作误判成点空白。
            .contentShape(Rectangle())
            .onTapGesture {
                selection = []
                anchor = nil
            }
        }
    }

    /// 最近一次量到的网格宽度。存下来是为了 `cellWidth` 变化时（⌘± 改图标尺寸）
    /// 能拿它重算列数 —— 那一刻宽度没变，`GeometryReader` 的 `onChange` 不会触发。
    @State private var measuredWidth: CGFloat = 0

    /// 把网格的实际宽度换成一屏列数回报上去。
    ///
    /// 借 `GeometryReader` + `onChange` 而不是在 body 里同步算：`body` 期间不能写
    /// 模型状态，而这两个回调都在布局之后触发。
    private var widthReporter: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { reportColumns(for: proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in reportColumns(for: width) }
        }
    }

    private func reportColumns(for width: CGFloat) {
        measuredWidth = width
        onColumnCountChange(
            GridNavigation.columnCount(width: Double(width), cellWidth: Double(cellWidth), spacing: Double(spacing))
        )
    }

    // MARK: - 布局

    private var iconSide: CGFloat { CGFloat(iconSize) }

    /// 单元格宽度 = 图标 + 两侧留白。名称要能在图标下方折两行。
    private var cellWidth: CGFloat { iconSide + labelAllowance }

    /// 自适应列数：宽度跟随图标尺寸，⌘± 因此直接改变一屏能放几个。
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth * 1.4), spacing: spacing)]
    }

    /// 显示顺序。**与 `AppModel` 走方向键时用的是同一个函数**（`GridNavigation.order`）——
    /// 两边各排一次、排序规则稍有差别，↓ 就会跳到肉眼看不见的地方。
    private var sortedEntries: [BrowserEntry] {
        GridNavigation.order(entries, foldersFirst: foldersFirst)
    }

    // MARK: - 单元格

    private func cell(_ entry: BrowserEntry) -> some View {
        draggableCell(entry) {
            card(entry)
                .onAppear { thumbnails.request(entry) }
                // 双击打开。单双击共存时 SwiftUI 会让单击等一个双击间隔，
                // 因此单击选中会有轻微延迟 —— 运行时若手感不可接受，可改为
                // 单击直接打开（与列表 primaryAction 一致）。
                .onTapGesture(count: 2) { onOpen(entry) }
                .onTapGesture { select(entry) }
                .contextMenu { menu(for: entry) }
                .help(entry.name)
        }
    }

    private func card(_ entry: BrowserEntry) -> some View {
        let isSelected = selection.contains(entry.id)
        return VStack(spacing: 6) {
            thumbnail(entry)
                .frame(width: iconSide, height: iconSide)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(entry.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Text(entry.isDirectory ? "文件夹" : ByteFormat.size(entry.size))
                .font(.caption2)
                .foregroundStyle(Color.columnText)
        }
        .padding(6)
        .frame(width: cellWidth)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func thumbnail(_ entry: BrowserEntry) -> some View {
        switch thumbnails.state(for: entry) {
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

    /// 加载中 / 不可用时的占位。**永远不留空白**（PRD §13.3）。
    private func placeholder(_ entry: BrowserEntry, showsSpinner: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3))
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else {
                EntryIconView(entry: entry, size: iconSide * 0.56)
            }
        }
    }

    // MARK: - 选择

    /// 单击选择，⌘ 切换，⇧ 区间。
    ///
    /// 修饰键在**点击这一刻**读 `NSEvent.modifierFlags`，而不是用
    /// `TapGesture().modifiers(...)` 叠加多个手势：后者会与无修饰键的单击重叠触发
    /// （⌘-点会同时命中「替换」与「切换」），而 `TapGesture` 没有「无修饰键」这个条件。
    private func select(_ entry: BrowserEntry) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
            }
            anchor = entry.id
        } else if flags.contains(.shift),
                  let anchor,
                  let from = sortedEntries.firstIndex(where: { $0.id == anchor }),
                  let to = sortedEntries.firstIndex(where: { $0.id == entry.id }) {
            let range = from <= to ? from...to : to...from
            selection = Set(sortedEntries[range].map(\.id))
        } else {
            selection = [entry.id]
            anchor = entry.id
        }
    }

    // MARK: - 右键菜单

    /// 菜单作用于**显式目标**，而不是 `AppModel` 的当前选择。
    ///
    /// 列表用 `contextMenu(forSelectionType:)`，系统会先帮我们选中右键的那一行；
    /// `LazyVGrid` 没有这层机制。若照抄列表的「零参闭包 + 读 model 选择」，
    /// 右键一个**未选中**的格子会去操作上一个选中项 —— 静默做错事。因此这里把
    /// 目标数组直接交给回调，右键谁就作用于谁（选中项则作用于整片选择，与 Finder 一致）。
    @ViewBuilder
    private func menu(for entry: BrowserEntry) -> some View {
        let targets = selection.contains(entry.id)
            ? sortedEntries.filter { selection.contains($0.id) }
            : [entry]
        let allRemote = targets.allSatisfy { $0.origin == .remote }
        // 「可上传」= 不是设备端条目。刻意不写 `origin == .local`：照片图库条目是
        // `.photo`，路径语义不同但同样可上传，按 `.local` 过滤会把照片网格的
        // 「上传到设备」整条菜单项滤掉。各窗格在各自回调里再决定怎么用这个数组。
        let uploadTargets = targets.filter { $0.origin != .remote }

        if targets.count == 1 {
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
            Button("下载到 Mac") { onDownload(targets) }
        }
        if let onUpload, !uploadTargets.isEmpty {
            Button("上传到设备") { onUpload(uploadTargets) }
        }
        Divider()
        if let onNewFolder {
            Button("新建文件夹…") { onNewFolder() }
        }
        if let onRefresh {
            Button("刷新") { onRefresh() }
        }
        if let onDelete, allRemote {
            Divider()
            Button("删除…", role: .destructive) { onDelete(targets) }
        }
    }

    // MARK: - 拖拽

    @ViewBuilder
    private func draggableCell<Content: View>(
        _ entry: BrowserEntry,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let payload = payload(for: entry) {
            content()
                .draggable(payload) {
                    dragPreview(for: entry, count: payload.paths.count)
                }
        } else {
            content()
        }
    }

    private func payload(for entry: BrowserEntry) -> TransferDragPayload? {
        guard let dragSide else { return nil }
        let ids = selection.contains(entry.id) ? selection : [entry.id]
        let picked = entries.filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return nil }
        return TransferDragPayload(side: dragSide, origin: .pane, paths: picked.map(\.path))
    }

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
