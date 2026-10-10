import AppKit
import SwiftUI

/// 分栏视图（PRD §13.2）。
///
/// **直接包 `NSBrowser`，不自绘复刻** —— 列宽、列间距、选中态、滚动位置全部交给
/// AppKit，天然对齐 HIG（PRD §13.2 的实现提示）。
///
/// 三处必须写清楚的实现要点：
///
/// 1. **子项列表是异步填的。** `NSBrowser` 的 delegate 是同步接口，而设备端列目录
///    要走一次 `adb shell ls` 子进程 —— 同步等它会把主线程冻住。所以 delegate 只读
///    缓存：没有就返回 0 并起一个异步加载，加载完 `reloadColumn` 把行补上。
/// 2. **根目录变更才重新 `loadColumnZero`。** 否则「在列里点文件夹」会把当前目录
///    反馈成新的根，列视图每点一下就整体回到第一列。根由外部（顶栏 / 位置弹窗 /
///    面包屑）驱动，见 `appliedRoot`。
/// 3. **选择变化没有通知可监听。** `NSBrowser` 只发了列宽配置变化的通知，
///    选中态要靠 delegate 的 `selectionIndexesForProposedSelection`（item-based 专用）
///    接。这个坑写在这里，免得下一个人去找 `selectionDidChangeNotification`。
struct EntryColumns: NSViewRepresentable {
    /// 第一列要列出的目录。只在它变化时重建列。
    let rootPath: String
    /// 当前选中的条目 id（与列表 / 网格共用同一份选择语义）。
    @Binding var selection: Set<String>
    /// 列视图「当前所在目录」，供窗格底部的路径栏显示（PRD §13.2：路径栏在窗格底部）。
    @Binding var currentDirectory: String
    /// 取某个目录的子项。本地是同步实现包一层，设备端是真异步。
    let listChildren: (String) async -> [BrowserEntry]
    /// 双击一个**文件**时调用（文件夹由 `NSBrowser` 自己展开）。
    let onOpenFile: (BrowserEntry) -> Void
    /// 选中项变化时回调（nil = 没有选中）。
    ///
    /// 存在的理由：列视图选中的条目可能位于**子目录**，不在窗格当前的条目列表里，
    /// 所以预览窗格 / Quick Look / ⌘C 没法从列表反查出来。外面据此记一份快照。
    var onSelectEntry: ((BrowserEntry?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSBrowser {
        let browser = NSBrowser()
        browser.delegate = context.coordinator
        browser.target = context.coordinator
        browser.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        browser.allowsMultipleSelection = false
        browser.allowsEmptySelection = true
        browser.minColumnWidth = 170
        browser.hasHorizontalScroller = true
        browser.columnResizingType = .userColumnResizing

        context.coordinator.appliedRoot = rootPath
        browser.loadColumnZero()
        return browser
    }

    func updateNSView(_ browser: NSBrowser, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncRoot(browser, rootPath: rootPath)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSBrowserDelegate {
        var parent: EntryColumns
        /// 已经作为「根」铺进第一列的目录。用来区分「外部导航」与「列内点选」。
        var appliedRoot: String?

        private var cache: [String: [BrowserEntry]] = [:]
        private var loading: Set<String> = []

        init(_ parent: EntryColumns) {
            self.parent = parent
        }

        // MARK: 根同步

        func syncRoot(_ browser: NSBrowser, rootPath: String) {
            guard appliedRoot != rootPath else { return }
            appliedRoot = rootPath
            cache.removeAll()
            loading.removeAll()
            browser.loadColumnZero()
        }

        // MARK: 选择

        /// 用户改动选中项时（鼠标或键盘）。返回值即最终选中项，这里原样放行。
        func browser(
            _ browser: NSBrowser,
            selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet,
            inColumn column: Int
        ) -> IndexSet {
            if let row = proposedSelectionIndexes.first,
               let item = browser.item(atRow: row, inColumn: column) as? ColumnItem {
                apply(item.entry)
            } else {
                parent.selection = []
                parent.currentDirectory = parent.rootPath
                parent.onSelectEntry?(nil)
            }
            return proposedSelectionIndexes
        }

        /// 列数变化时兜底刷新一次（例如程序化加载完 root 之后）。不在最后一列时
        /// 单独换文件不会触发这里，所以主钩子是上面那个。
        func browser(_ browser: NSBrowser, didChangeLastColumn oldLastColumn: Int, toColumn column: Int) {
            refreshFromSelectionPath(browser)
        }

        private func refreshFromSelectionPath(_ browser: NSBrowser) {
            guard let indexPath = browser.selectionIndexPath, indexPath.count > 0,
                  let item = browser.item(at: indexPath) as? ColumnItem else {
                return
            }
            apply(item.entry)
        }

        private func apply(_ entry: BrowserEntry) {
            parent.selection = [entry.id]
            // 路径栏显示「当前所在目录」：选中文件夹就是它自己，选中文件就是它所在目录。
            parent.currentDirectory = entry.isDirectory
                ? entry.path
                : (entry.path as NSString).deletingLastPathComponent
            parent.onSelectEntry?(entry)
        }

        @objc func handleDoubleClick(_ sender: NSBrowser) {
            let column = sender.clickedColumn
            let row = sender.clickedRow
            guard column >= 0, row >= 0,
                  let item = sender.item(atRow: row, inColumn: column) as? ColumnItem else { return }
            // 文件夹交给 NSBrowser 自己展开；只有文件需要外部接管（打开 / 预览）。
            guard !item.entry.isDirectory else { return }
            parent.onOpenFile(item.entry)
        }

        // MARK: NSBrowserDelegate（item-based）

        func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
            // 文件不该有子列。虽然 isLeafItem 已经声明了这一点，但设备端 `ls -la <文件>`
            // 会把这个文件自己回显成一条记录，看起来就像它有子项 —— 这里再挡一道。
            if let item = item as? ColumnItem, !item.entry.isDirectory { return 0 }

            let path = directoryPath(for: item)
            if let children = cache[path] { return children.count }
            // 异步填：先返回 0，加载完再 reloadColumn 把行补上（见类型注释第 1 条）。
            load(path, column: columnIndex(for: item), browser: browser)
            return 0
        }

        func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
            let path = directoryPath(for: item)
            guard let children = cache[path], children.indices.contains(index) else {
                return NSNull()
            }
            return ColumnItem(children[index])
        }

        func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
            guard let item = item as? ColumnItem else { return false }
            return !item.entry.isDirectory
        }

        func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
            (item as? ColumnItem)?.entry.name
        }

        /// 行内类型图标。
        ///
        /// `willDisplayCell` 在 item-based 浏览器里是否会被调用，Apple 文档没有明确
        /// 承诺（item 模式的单元格实现是私有的）。写上没有任何代价：不调用就退化成
        /// 纯文本行，调用就与列表 / 网格的图标一致。**需运行时确认**。
        func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
            guard let cell = cell as? NSBrowserCell,
                  let item = browser.item(atRow: row, inColumn: column) as? ColumnItem else { return }
            let entry = item.entry
            let symbol = NSImage(
                systemSymbolName: entry.systemImage,
                accessibilityDescription: entry.isDirectory ? "文件夹" : "文件"
            )
            cell.image = symbol
        }

        // MARK: 加载

        private func load(_ path: String, column: Int, browser: NSBrowser) {
            guard cache[path] == nil, !loading.contains(path) else { return }
            loading.insert(path)

            let lister = parent.listChildren
            Task { [weak self, weak browser] in
                let children = await lister(path)
                guard let self else { return }
                self.loading.remove(path)
                self.cache[path] = children
                // 期间可能被外部导航换了根 —— 那就别往旧结构里塞。
                guard let browser, self.appliedRoot == self.parent.rootPath else { return }
                browser.reloadColumn(column)
            }
        }

        private func directoryPath(for item: Any?) -> String {
            guard let item = item as? ColumnItem else { return parent.rootPath }
            return item.entry.path
        }

        /// 某一项的子项所在的列号。
        ///
        /// item 为 nil（根）→ 第 0 列；深度为 d 的项 → 第 d 列。
        /// 依据是 `NSBrowser` 的铺列方式：第 0 列放根的子项，选中其中的文件夹后，
        /// 它的子项进第 1 列 —— 而那个文件夹的深度恰好是 1。
        private func columnIndex(for item: Any?) -> Int {
            guard let item = item as? ColumnItem else { return 0 }
            return depth(of: item.entry.path)
        }

        private func depth(of path: String) -> Int {
            let root = normalizedRoot
            guard path.hasPrefix(root) else { return 0 }
            let rest = path.dropFirst(root.count)
            if rest.isEmpty { return 0 }
            return rest.split(separator: "/").count
        }

        private var normalizedRoot: String {
            var root = parent.rootPath
            while root.count > 1, root.hasSuffix("/") { root.removeLast() }
            return root == "/" ? "" : root
        }
    }
}

/// `NSBrowser` 的 item。
///
/// 必须是**引用类型**：`NSBrowser` 会把 item 存起来并靠 `isEqual` / `hash` 判断
/// 选中态与是否同一项，Swift 结构体会被装箱成 `__SwiftValue`，比较语义随之失效。
/// 这里按路径定义身份，同路径即同一项。
final class ColumnItem: NSObject {
    let entry: BrowserEntry

    init(_ entry: BrowserEntry) {
        self.entry = entry
    }

    override var description: String { entry.name }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? ColumnItem)?.entry.path == entry.path
    }

    override var hash: Int { entry.path.hashValue }
}
