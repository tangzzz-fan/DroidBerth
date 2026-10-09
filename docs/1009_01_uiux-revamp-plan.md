# DroidBerth UI/UX 改造分阶段方案

| 项 | 值 |
|---|---|
| 版本 | v1.0（草案） |
| 日期 | 2026-10-09 |
| 范围 | `macos/` Swift 原生外壳的交互层与视觉层 |
| 前置 | PRD v2.0（`docs/0926_01_PRD.md`） |
| 依据 | 现有代码审阅（36 个 Swift 文件 / 4578 行）+ PRD §8–§25 |

---

## 0. 结论与判断

**问题不在「视觉过时」，而在交互层缺失。**

PRD §10–§25 定义了一整套 Finder 级交互（拖拽、跨栏传输、三种视图、Quick Look、全键盘导航），但 MVP 只落地了「列表 + 右键菜单 + 深色模式」三块。当前形态更接近**一个能传文件的表格页**，而不是文件管理器。

同时，**PRD 自身的 UX 章节已经过时**：它写于 2026-09-26，当时判断继续走 Tauri；此后技术路线切到 Swift 原生（`docs/0926_02`、`0926_03`），PRD 里所有**实现约束**都指向 WKWebView，成为失效判据。

因此改造顺序必须是：**先修 PRD（Phase 0）→ 再修 UX（Phase 1+）**。若不先修，后续每次交互评审都会拿错尺子。

---

## 1. Phase 0：PRD UX 章节对齐 Swift 原生（前置，必须先做）

### 1.1 为什么必须前置

PRD 的产品意图（双栏、拖拽、⌘C/⌘V 跨栏、三视图）**全部仍然有效**，不需要推翻。
需要改的是**实现约束**——它们描述的是 Tauri/WKWebView 的能力边界，对 SwiftUI 不成立，继续留在文档里会误导实现者。

### 1.2 精确改动清单

| PRD 章节 | 现内容 | 问题 | 改法 |
|---|---|---|---|
| §8 原则一 | 「照 HIG 自绘，并承认这是自绘」 | SwiftUI 系统控件本就是原生的，无需自绘 | 改为「优先系统控件（SwiftUI / AppKit），不自造系统已有之物」 |
| §8 原则二 | `titleBarStyle: "Overlay"` + 78px 交通灯预留 | Tauri 专有属性 | 删除。SwiftUI 走 `.toolbar` + `ToolbarItem` + `.windowStyle(.hiddenTitleBar)`（按需） |
| §8 原则三 | 材质只能用 `backdrop-filter` 近似，且「不做比硬仿好」 | 前提消失：SwiftUI 有原生 `.regularMaterial` / `.bar` | 改为「材质用原生 Material API；导航层可用，内容区不用」 |
| §10 窗口与工具栏 | 同 §8，含交通灯预留区 | 同上 | 重写为 `NSToolbar` / SwiftUI `toolbar` 布局，保留控件清单 |
| §21 外观 | 「在 Tauri 里必须 Rust 侧设 `NSApp.appearance`」 | 结论正确、路径过时（`AppearanceController` 已实现） | 保留结论，更新为「经 `NSApplication.shared.appearance` 驱动」 |
| §23 Quick Look | `tauri-plugin-quicklook` 包装 `QLPreviewPanel`，`qlmanage -p` 兜底 | 方案过时 | 改为 SwiftUI `.quickLookPreview(_:)`（macOS 14+）；保留远端文件需先落地的约束 |
| §13.2 分栏视图 | 「`NSBrowser` 的自绘复刻」 | 措辞过时 | 改为「`NSViewRepresentable` 包装 `NSBrowser`」或明确自绘范围 |
| §5 非功能需求 | 内存 ≤150 MB 标注为「Tauri + WebView 基线」 | 基线过时 | 按 Swift 原生重设目标并实测 |
| §0 变更表 #3 / #4 | 以 Tauri 为理由 | 历史记录 | 加注「技术路线已于 0926 切至 Swift 原生，本行理由仅存历史」 |
| §6.2 / §7 | 含 Tauri 相关约束与路线 | 部分过时 | 逐条复核，标注「Tauri 路线，仅存对照」 |

### 1.3 产出

- `docs/0926_01_PRD.md` 就地升版为 **v2.1**，新增 §0.1「相对 v2.0 的变更」记录本次改动
- 更新 `README.md` 的「当前状态」表：把「视觉与交互验收 = 未做」细化为指向本方案

### 1.4 验收点

PRD 内不再出现任何作为**实现依据**的 Tauri/WKWebView/CSS 约束；所有 UX 章节的约束在 SwiftUI 下可执行。

---

## 2. Phase 1：交互骨架（P0 — 体感现代化，投入产出比最高）

> **执行状态（2026-10-09）**：1.4 / 1.1 / 1.2 / 1.3 已实现并通过 `swiftc` 编译验证，**运行时行为待人工验收**。剩余已知偏离见 §2.6。

### 2.1 拖拽传输

| 方向 | 行为 |
|---|---|
| Mac 窗格 → 设备窗格 | 上传 |
| 设备窗格 → Mac 窗格 | 下载 |
| Finder → 窗口任意位置 | 上传到设备窗格当前目录 |
| 设备窗格 → Finder | 下载到 Finder 目标位置 |
| 设备窗格内部 | 设备端移动（`mv`，P2） |

要求：拖入时高亮目标区域；多选显示数量徽章；`Android/data`、`Android/obb` 等不可写目录显示禁止光标而非静默失败。

- 实现：`EntryTable` 行加 `.draggable(...)`（`Transferable` / `NSItemProvider`），窗格容器加 `.dropDestination(...)`
- 落地复用现成的 `TransferPlanner.upload` / `.download`，无需新写传输逻辑
- 涉及：`Views/EntryTable.swift`、`Views/MainView.swift`、`App/AppModel.swift`

### 2.2 ⌘C / ⌘V 跨栏传输（PRD §22）

- Mac 栏选中 → ⌘C → 设备栏 ⌘V = 上传；反向 = 下载
- 焦点在文本框（重命名 / 新建文件夹 / 搜索）时恢复文本语义（responder chain）
- 实现：`.onCopyCommand` / `.onPasteCommand` 或 `Edit` 菜单命令 + 焦点判断
- 涉及：`DroidBerthApp.swift`、`Views/MainView.swift`

### 2.3 空格 Quick Look（PRD §23）

- 本地文件：`.quickLookPreview($url)`
- 远端文件：先落到 `$TMPDIR/DroidBerth/preview/` 再预览；> 200 MB 先弹确认
- 涉及：`App/AppModel.swift`、`Support/AppPaths.swift`、`Views/MainView.swift`

> **实现坑（务必记住）**：`.quickLookPreview(_:)` **不在 `SwiftUI` 模块里**，它由
> `QuickLook` + `SwiftUI` 的 cross-import overlay（`_QuickLook_SwiftUI`）提供。
> 只写 `import SwiftUI` 会报 `has no member 'quickLookPreview'`——这正是
> `f4c65d7` 那次「SwiftUI 没有 quickLookPreview」错误结论的根因。正确写法是
> **同时 `import QuickLook`**，之后 `_QuickLook_SwiftUI.framework` 会自动链接。
> 另：该 API 的实际可用性标注是 macOS 11.0+，不是 PRD 写的 14.0+。

### 2.4 窗格聚焦与键盘导航（PRD §22 / §25）

- 焦点态：**系统色描边 + 窗格头加粗**，不能只靠颜色区分（当前仅 `Color.accentColor.opacity(0.06)`，不达标）
- `Tab` 在「Mac 窗格 → 设备窗格 → 传输面板」循环
- `⌘⌥← / ⌘⌥→` 切窗格；`⌘↑` 上级；`⌘[ / ⌘]` 后退/前进；`⌘R` 刷新；`⌘⌫` 删除
- 涉及：`Views/MainView.swift`

### 2.5 验收点

能从 Finder 直接拖文件进窗口完成上传；能把设备文件拖到 Finder 完成下载；⌘C/⌘V 跨栏生效；空格可预览；Tab 可循环聚焦；焦点态有可见描边。

### 2.6 Phase 1 的已知偏离（实现时确定，不是遗漏）

| 偏离 | 说明 | 处置 |
|---|---|---|
| Tab 只做「Mac 窗格 ↔ 设备窗格」两段循环 | PRD §22 要求三段（含传输面板），但面板目前没有键盘可交互的内容，把焦点移进去无意义 | 随 Phase 2.3 传输面板改造补齐 |
| 设备窗格 → Finder 拖出未实现 | 需要 `NSFilePromiseProvider` 支撑「拖到任意位置才决定落点」，与窗格间拖拽是两套机制 | 另立一票，Phase 2 之后 |
| 同侧拖拽（Mac 内部 / 设备内部移动）只给提示 | 需要 move 语义与设备端 `mv` | Phase 4 |
| ⌘X 剪切只给提示 | 同上 | Phase 4 |
| 照片图库不支持空格预览 | 图库条目要先导出成文件 | Phase 3 |
| Quick Look 菜单项**不挂空格快捷键** | 无修饰键的菜单快捷键会先于文本框拿到事件，会把输入框里的空格吃掉。空格只由 `PaneKeyMonitor` 的本地监听处理，它带 `TextEditingRelay.isEditing` 守卫 | 保持现状；菜单项仅提供可发现性与启用态 |
| 多选时按空格不预览 | 面板一次只呈现一个文件，硬挑第一个会造成误解。此时空格交还系统 | 有意为之 |

---

## 3. Phase 2：工具栏与视觉层（P1）

> **执行状态（2026-10-09）**：3.1 / 3.2（改为位置弹窗）/ 3.3 / 3.4 已实现并通过 `swiftc` 编译与链接验证，**运行时行为待人工验收**。三处刻意偏离见 §3.6。

### 3.1 工具栏重构（PRD §10）

- 左：视图切换分段控件（列表 / 分栏 / 网格），作用于聚焦窗格 —— **延后到 Phase 3**
- 中：`⇄` 交换两侧（**语义已澄清为「交换左右窗格」**，见 PRD §10 的说明）
- 右：搜索框 + `⋯` 溢出菜单；上传 / 下载**保留为常驻按钮**
- 涉及：`Views/MainView.swift`（`toolbar`）、`App/AppModel.swift`、`DroidBerthApp.swift`

### 3.2 位置导航：位置弹窗 + 最近使用（**替代原「可见侧边栏」方案**）

原方案是改用 `NavigationSplitView` 做常驻侧边栏。**评估后放弃**：

- 这是双栏传输工具，第三栏会**永久**吃掉横向空间。窗口最小宽 900pt，减去侧边栏后每栏只剩 ~340pt（当前每栏下限就是 340pt），直接把布局逼到极限
- 「位置」是偶发动作，不值得常驻一栏
- 真正的痛点是**回到上次传的那个项目文件夹**（几百 GB 的素材目录），而不是桌面 / 下载这些固定位置

改为：导航条上的「位置」按钮 → 弹窗，内含**最近使用**（持久化，最多 8 项，可清除）+ 固定位置 + 「其它…」。
- 涉及：`Views/MainView.swift`（`PlacesPopover`）、`App/AppSettings.swift`

### 3.3 传输面板增强（PRD §14）

- 传输速度（MB/s）、剩余时间：数据早已由 `ProgressParser` → `TransferJob` 提供，本次补齐呈现
- 失败行常驻「重试」与「查看原因」（**不藏在 hover 后面**）+ 整行警示色
- 「查看原因」展开后可看完整错误、源 / 目标路径，并可一键拷贝
- 折叠态为单行摘要；有任务时自动展开；可手动固定（pin，持久化）
- 涉及：`Views/TransferPanel.swift`、`Transfer/TransferJob.swift`、`Transfer/TransferQueue.swift`

### 3.4 列表增强（PRD §13.1）

- 列头点击排序（名称 / 种类 / 大小 / 修改日期，升降序），文件夹优先且可在设置里关
- 搜索过滤（作用于聚焦窗格）
- 右键菜单补「新建文件夹」
- 涉及：`Views/EntryTable.swift`、`App/AppModel.swift`、`Support/BrowserEntry.swift`

### 3.5 验收点

工具栏含交换 / 搜索 / 溢出菜单；位置弹窗含最近使用；传输面板显示速度与 ETA、失败可重试且可固定；列头可排序；搜索可用。

### 3.6 Phase 2 的已知偏离与实现要点（实现时确定，不是遗漏）

| 项 | 说明 |
|---|---|
| **视图切换分段控件延后** | 分栏与网格是 Phase 3 内容。先摆一个只有「列表」可用的分段控件属于**假可用**，比没有更糟。⌘1/⌘2/⌘3 一并延后 |
| **上传 / 下载不进 ⋯** | PRD §10 把它们列在 ⋯ 里。这两个是本产品的核心动作，藏进菜单是净损失，保留为常驻按钮（File 菜单 + ⇧⌘U / ⇧⌘S 仍在） |
| **不做常驻侧边栏** | 见 §3.2 的理由。这是对原方案的**主动否决**，不是没做完 |
| **⇄ 的语义按「交换左右窗格」实现** | PRD §10 原文「把两个窗格的位置互换」含混：本地路径与设备路径不可能互相赋值。按双栏管理器的经典语义（交换面板）实现，并在 PRD §10 就地写明 |
| **搜索作用域只在编辑时锁定** | 不跟随焦点实时变化 —— 否则 Tab 一下结果就跳，用户会以为丢了东西。编辑是明确动作，跳变可预期 |
| **换目录清筛选、刷新保留** | 筛选语义是「在当前这个文件夹里找」。换目录后留着旧查询会造成「明明有文件却显示空」 |
| **`Optional` 不是 `Comparable`** | `TableColumn(_:value:)` 要求 `V: Comparable`，Swift 故意不给 `Optional` 定义全序。大小 / 日期列靠 `BrowserEntry.sortableSize` / `sortableModified` 投影成非可空值（未知按 -1 / `.distantPast`，升序时排最前） |
| **列头排序必须自己排** | `Table` 拿到 `sortOrder` 只负责画箭头，**不会重排数据**。`EntryTable` 用单个比较器做「文件夹优先 + 用户列 + 名称兜底」，不依赖 `sorted(by:)` 的稳定性（Swift 未承诺稳定） |
| **名称列要换回本地化比较** | 点击列头时 `Table` 会用**默认比较器**重建 comparator（名称列退化成大小写敏感的字典序，`Zebra` 会排到 `apple` 前）。用一层 `Binding` 包装把它换回 `localizedStandard` |
| **右键「重命名」未做** | 需要设备端 `mv`，属 Phase 4 |
| **⇄ 按视觉位置聚焦** | 交换之后 ⌘⌥← / ⌘⌥→ 必须按**屏幕上的左右**走，不能按 Mac / 设备走，否则反直觉 |

---

## 4. Phase 3：视图扩展与无障碍（P2）

### 4.1 网格视图 + 缩略图（PRD §13.3）

- 目标用户是摄影师 / 视频创作者，**没有缩略图的素材浏览等于不可用**
- 本地缩略图：`QLThumbnailGenerator`；远端：只拉文件头（图片前 64 KB / 视频容器头），不下载完整文件
- `⌘+ / ⌘-` 调整图标大小；生成失败显示类型图标，不留空白
- 依赖：`DeviceShell` 需新增「拉取指定字节范围」能力

### 4.2 分栏视图（PRD §13.2）

- `NSViewRepresentable` 包装 `NSBrowser`；列宽 / 选中态 / 滚动位置需对齐 HIG
- 成本较高，建议最后做

### 4.3 菜单栏补全（PRD §11）

- 补 `View` 菜单（列表 ⌘1 / 分栏 ⌘2 / 网格 ⌘3 / 显示隐藏文件 ⇧⌘. / 交换两侧）
- 补 `Device` 菜单（连接 / 断开 / 设备信息 / 启用无线 / 重新扫描）
- 补 `⌘,` 设置、`⌘⌫` 删除、`Space` Quick Look
- 现状：仅 3 条命令挂在 `.newItem` 组
- 涉及：`DroidBerthApp.swift`

### 4.4 无障碍（PRD §25）

- 每个列表行补 `accessibilityLabel`（文件名 + 种类 + 大小 + 日期 + 所在窗格）——当前 0 处
- Reduce Motion：进度动画退化
- 动态字体支持；文本对比度达 WCAG AA

### 4.5 验收点

网格视图可浏览缩略图；菜单栏含 View / Device；VoiceOver 能读出每行完整信息。

---

## 5. Phase 4（可选）：设备端写操作补全

- 重命名、设备端移动（`mv`）、复制
- 这些是 PRD §13.1 右键菜单的组成部分，当前只实现了删除

---

## 6. 依赖与风险

| 项 | 说明 | 等级 |
|---|---|---|
| 拖拽落地 | 复用 `TransferPlanner`，风险低 | 低 |
| 远端缩略图 | 需给 `DeviceShell` 加「拉指定字节」能力 | 中 |
| 分栏视图 | `NSBrowser` 复刻成本高，建议后置 | 中 |
| 传输速度 / ETA | 需从 `ProgressParser` 提取并暴露时序数据 | 中 |
| 回归验证 | 现有 UI 无自动化测试，改动只能人工验收（`0926_03` §5.3 已记录） | 中 |
| PRD 与代码漂移 | Phase 0 若不做，后续评审持续拿错判据 | 高 |

---

## 7. 建议执行顺序

```
Phase 0（PRD 对齐）                                    ✅ 已完成
  └─ Phase 1.4（聚焦态 + 键盘，成本最低，先建立反馈）    ✅ 已完成
       └─ Phase 1.1（拖拽）→ 1.2（⌘C/⌘V）→ 1.3（Quick Look）  ✅ 已完成
            └─ Phase 2（工具栏 + 位置弹窗 + 传输面板 + 列表增强）  ✅ 已完成
                 └─ Phase 3（网格 → 分栏 → 菜单栏补全 → 无障碍）  ⬜ 下一步
                      └─ Phase 4（可选：设备端重命名与移动）        ⬜
```

理由：Phase 1.4 成本最低且能立刻改善「操作有没有被响应」的感知；拖拽是体感提升最大的一项，放其后；网格视图虽重要，但依赖远端缩略图能力，放在 Phase 3 更稳。

**Phase 2 内的实际执行顺序**（按对主场景的价值，而非文档编号）：
3.3 传输面板 → 3.4 列表增强 → 3.1 工具栏 → 3.2 位置弹窗。
理由：传输失败无法重试 / 看不到原因，是主场景（几百 GB 素材推送）最直接的痛点；排序与搜索是素材管理的刚需；工具栏与位置属于整理性质。

---

## 8. 总验收清单

- [x] PRD 升版 v2.1，UX 章节无 Tauri 实现约束
- [x] 四向拖拽可用，不可写目录有禁止反馈（设备 → Finder 除外，见 §2.6）
- [x] ⌘C/⌘V 跨栏传输可用，文本框内恢复文本语义
- [x] 空格 Quick Look 可用（本地就地、远端先落地）
- [x] 窗格聚焦有描边 + 标题加粗，Tab 可循环（两段循环，见 §2.6）
- [x] 工具栏含交换 / 搜索 / 溢出菜单（视图切换延后到 Phase 3，见 §3.6）
- [x] 传输面板含速度、ETA、失败原因、可固定
- [x] 列头可排序（含文件夹优先开关）；搜索可用
- [x] 位置弹窗含最近使用（替代常驻侧边栏，见 §3.2）
- [x] 菜单栏含 View 组 / ⌘, / ⌘⌫ / ⌘F / ⇧⌘. / ⇧⌘X
- [ ] 网格视图含缩略图
- [ ] 分栏视图（`NSBrowser`）
- [ ] 每行有 VoiceOver 标签
- [ ] **全部交互的运行时人工验收**（本机无 Rust 工具链与 adb，只能做到编译 + 链接验证）
