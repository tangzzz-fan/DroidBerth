# UI 精简（方案 A）+ P0 第一批 — Ticket 队列

日期：2026-10-08。方案 A 已拍板；每票完成 → 构建/测试 → commit（push 单独确认）。
依据：`MainView.swift`（523 行 @ f4c65d7）、实现文档 §5.3/§7、PRD §10。

## UI 精简（方案 A）

### T1 `refactor: 砍 DeviceBar，设备操作并入系统工具栏`
- 删 `DeviceBar` struct（MainView:78-171）与 body 中的调用（:13-18）
- 工具栏首位加设备 Menu（placement: .navigation）：设备列表（当前项打勾）+ 重新检测 + 启用无线 + 尝试重连；busy 时挂 mini ProgressView
- serial 文本（:103-105）与无线徽章（:106-110）删除（connectionLabel 已含连接方式）
- DeviceBar 四态提示（:145-168）迁到设备窗格空态：扩展 :333 的 emptyMessage 逻辑为 `deviceEmptyMessage`
- 验收：构建通过；无设备/未授权文案在设备窗格可见；设备切换仍触发 deviceDidChange

### T2 `refactor: 砍 PaneHeader，来源与位置切换并入导航条`
- 删 PaneHeader struct（:480-501）与两处调用（:177-190 / :288-303）
- Mac 窗格：来源 Picker（Finder 位置/照片图库）移到导航条右端；photos 模式下同一条导航条仍显示 Picker（中间内容替换）
- 设备窗格：位置快捷菜单（DCIM/Movies/Pictures/Download）移到导航条右端
- 验收：构建通过；两种来源切换可用；焦点高亮（:221/:364 背景色）保留

### T3 `refactor: 低频功能收进更多菜单 + 修设备空间错位`
- 工具栏重组：设备Menu | 上传 下载 | ⋯ 更多（新建文件夹、显示隐藏文件 Toggle、刷新媒体库、设置）
- 「隐藏文件」checkbox（:251-253）从导航条移除
- 修错位：`localStatusBar` 删除设备可用空间（:270-274），设备窗格状态条保留（:355-359）
- 验收：构建通过；更多菜单五项全部可用；Mac 窗格底部不再显示设备空间

## P0 第一批（已拍板，UI 精简后执行）

### T4 `test: 立 DroidBerthTests target`
- project.yml 加 bundle.unit-test target + scheme 挂 test；Tests/DroidBerthTests/ 空冒烟测试
- 验收：xcodebuild test 通过（前置 build-sidecar.sh）

### T5 `fix: MediaScanner.isIndexed 按媒体类型分流`
- 纯函数 mediaTable(forExtension:) + verdict 三态（indexed/notIndexed/notMedia）；非媒体不广播不查询
- TransferQueue.start() 与 AppModel.scanRemoteSelection() 文案跟着区分
- 先写测试看红，再改实现转绿

### T6 `feat: ⌘C/⌘V 跨栏 = 传输`
- AppModel PaneClipboard + copySelection/pasteIntoFocus；路由判定纯函数 pasteRoute + 单测
- DroidBerthApp commands 加 ⌘C/⌘V；同栏粘贴 banner 提示

### T7 `feat: 设备端重命名`
- DeviceShell.move() 薄封装；AppModel.renameRemoteEntry + validateRemoteName 纯函数 + 单测
- EntryTable contextMenu「重命名…」（单选远端）+ alert（预填原名）

### T8 `feat: 拖拽上传（Mac 栏 → 设备栏）`
- AppModel 抽出 uploadFiles(_ urls:)（uploadSelection 瘦身，行为不变）
- 设备窗格 .dropDestination(for: URL.self) + isTargeted 高亮
- 边界：照片来源不参与拖拽
