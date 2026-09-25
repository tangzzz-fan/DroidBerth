# DroidBerth Swift 原生外壳 MVP 实现文档

| 项 | 值 |
|---|---|
| 分支 | `spike/swift-native-adb` |
| 日期 | 2026-09-26 |
| 目的 | 记录 MVP 的**实际实现形态**、**已实测到的边界**、以及**未验证项** |
| 前序 | `docs/0926_02_swift-native-spike-plan.md`（Go/No-Go 已判 **Go**）、`docs/0926_01_PRD.md` |
| 规模 | `macos/` 36 个 Swift 文件 / 4611 行；sidecar（Rust）原样复用 1787 行 / 5 文件，**未改一行** |

> **阅读约定**：沿用 spike 方案的做法，区分「已实测」「推断」「未验证」。
> 第 7 节把未验证项集中列出，不藏在正文里。
>
> **与前序文档的关系**：spike 回答的是「这条技术路线成不成立」；
> 本文记录「成立之后实际做成了什么、验证到哪一步、哪里还是空的」。两者不重叠。

---

## 1. 结论摘要

| 项 | 状态 |
|---|---|
| SwiftUI 原生外壳替换 Tauri/WKWebView | **已实现**，Release 可构建、可运行 |
| 复用已验证的 Rust sidecar | **成立**，sidecar 一行未改 |
| 签名链 | **通过**（三项判据全中，见 §3.4） |
| 双向文件传输 | **真机实测通过**（上传 / 下载 / 文件夹递归 / 重名 / SHA 回验 / 进度上报） |
| 图片上传 + 系统相册入库 | **真机实测通过** |
| 照片图库作为来源 | **已实现，未验证**（需人工点授权） |
| 公证与 staple | **未做**（本次不涉及） |
| 视觉与交互验收 | **部分完成**：双击/右键打开文件夹已由用户人工确认可用；拖拽手感与整体布局仍未验收（见 §5.3） |

---

## 2. 交付形态

### 2.1 工程结构

```
macos/
  project.yml                        xcodegen 工程定义（79 行）
  Resources/
    Info.plist                       权限描述 + bundle 元数据
    DroidBerth.entitlements          3 条 hardened runtime 豁免
  Scripts/
    build-sidecar.sh                 编译 Rust sidecar 并暂存到 macos/Sidecar/
  Sources/DroidBerth/
    DroidBerthApp.swift              入口 + 快捷键命令
    Sidecar/                         ← 与 Rust sidecar 的边界
      SidecarLocator.swift           相对自身可执行文件定位
      SidecarClient.swift            version / resolve / doctor / exec 子命令封装
      ProcessRunner.swift            Process + Pipe 封装（双路抽干 + 超时 + 升级 SIGKILL）
      Models.swift                   resolve / exec / doctor 的 Codable
    ADB/                             ← 设备侧能力
      ADBBinary.swift                单例缓存 sidecar 解析出的 adb 路径
      DeviceMonitor.swift            设备轮询（@Observable）
      AndroidDevice.swift            设备模型 + adb 输出解析
      DeviceShell.swift              ls / mkdir / rm / getprop / df 等封装
      RemoteEntry.swift              远端条目 + ls -la 解析
      RemoteListing+Recursive.swift  ls -lR 多目录解析
      PtyProcess.swift               pty 封装（进度上报的唯一来源）
      MediaScanner.swift             媒体入库（am broadcast + content query 复核）
      WirelessManager.swift          USB → 无线切换（tcpip / connect）
    Transfer/                        ← 传输内核
      TransferPlanner.swift          展开成计划（递归、重名、空间校验）
      TransferJob.swift              单个任务的 Observable 状态
      TransferQueue.swift            并发泵 + 执行 + 媒体扫描收尾
      ProgressParser.swift           解析 adb 的 \r[ 8%] 进度段
    Local/LocalFileSystem.swift      Mac 侧目录列举 / 位置 / 唯一化命名
    Photos/
      PhotoLibraryModel.swift        PhotoKit 相册与条目
      PhotoExporter.swift            PHAsset → 临时文件（懒加载）
    Support/
      BrowserEntry.swift             统一外壳条目（本地/远端/照片三种来源）
      ByteFormat.swift               字节与日期格式化 + 扩展名分类
      AppPaths.swift                 暂存目录
    App/
      AppModel.swift                 编排层（551 行，全项目最大文件）
      AppSettings.swift              UserDefaults 持久化设置
      AppearanceController.swift     外观三档
    Views/
      MainView.swift                 双栏主界面 + 顶部设备栏 + 状态栏
      EntryTable.swift               通用条目表格（三种来源共用）
      PhotoSourceView.swift          照片图库来源
      TransferPanel.swift            传输队列面板
      SettingsView.swift             设置
      SpikeView.swift / SpikeChecks.swift / SpikeReport.swift
                                     上一轮的验证面板（保留，可反复重跑）
```

### 2.2 构建与运行

```bash
./macos/Scripts/build-sidecar.sh                 # 必须先跑，否则 preBuildScript 直接 fail
cd macos
USER=$(id -un) /opt/homebrew/bin/xcodegen generate
USER=$(id -un) xcodebuild -project DroidBerth.xcodeproj -scheme DroidBerth \
  -configuration Release -derivedDataPath build/dd build
open build/dd/Build/Products/Release/DroidBerth.app
```

`USER=$(id -un)` 不是装饰 —— 本机 Bash 环境里 `USER` 未设置，
XcodeGen 会报 `Couldn't find current username` 且**静默不生成工程**。

> **产物路径注意**：本仓同时存在 `macos/build/Release/`（旧，`-target` 构建）与
> `macos/build/dd/Build/Products/Release/`（`-derivedDataPath build/dd`）。
> **验证 UI 改动前必须核对进程启动时间 vs 源码 mtime**，否则会看着旧二进制下结论。
> 这一点在本次实现中真实踩到过（见 §5.4）。

### 2.3 打包与签名现状（实测）

当前 Release 产物三个 Mach-O 的实际情况：

| Mach-O | Identifier | flags | Timestamp | TeamIdentifier | entitlements |
|---|---|---|---|---|---|
| `DroidBerth` | `dev.tango.droidberth` | `0x10000(runtime)` | `Sep 26, 2026 at 07:40:20` | `UKXWZ3FS84` | 3 条 |
| `droidberth-adb` | `droidberth-adb` | `0x10000(runtime)` | `Sep 26, 2026 at 07:32:42` | `UKXWZ3FS84` | **无** |
| `adb` | `adb` | `0x10000(runtime)` | `Sep 26, 2026 at 07:32:42` | `UKXWZ3FS84` | **无** |

架构：`DroidBerth` 与 `droidberth-adb` 为 arm64，`adb` 为 universal（x86_64 + arm64）。
`project.yml` 设 `ARCHS: arm64` —— 即**主动放弃 Intel**（理由见 §3.5）。

三条关键设置的由来（前两条是实测逼出来的，不是抄的）：

| 设置 | 状态 |
|---|---|
| `OTHER_CODE_SIGN_FLAGS: "--timestamp"` | **必需**。Xcode 在**不设**它时是显式传 `--timestamp=none`（不是「省略」）。「缺 `--timestamp` 不是缺陷」这条结论**不能从 Tauri 外推到 Xcode** |
| `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` | **必需**。默认为 `YES`，会往 Release 里注入 `com.apple.security.get-task-allow`，**直接挡公证** |
| `ENABLE_USER_SCRIPT_SANDBOXING: NO` | **必要性未证实**。见下方说明 |

> **关于 `ENABLE_USER_SCRIPT_SANDBOXING`**：直觉上它「必须」为 `NO`，
> 因为 preBuildScript 要执行 `$SRCROOT/Sidecar/droidberth-adb version`。
> **实测推翻了这条推断** —— 把它设为 `YES` 并清空 derived data 重建，
> **`BUILD SUCCEEDED`**，脚本在 `sandbox-exec` 下正常执行了 sidecar 自检
> （脚本阶段的 `SCRIPT_INPUT_ANCESTOR_*` 已包含 `SRCROOT`，读执行权是够的）。
>
> 也就是说这条设置当前**没有已知的必要性**，保留它属于防御性配置。
> 不改的理由是「没有证据说明它有害」；但要记住它**不是**一个已验证的必需项 ——
> 别把它当成签名链的一部分去推理。

> 关掉 `get-task-allow` 的代价：在启用 SIP 的机器上**无法调试该二进制**。
> 所以这是「准备分发时才改」的设置，不是开发期设置。

---

## 3. 架构

### 3.1 分层与依赖方向

```
Views ──→ AppModel ──→ Transfer / ADB / Local / Photos ──→ Sidecar / ProcessRunner
              │
              └──→ AppSettings（UserDefaults）
```

- **`AppModel` 是唯一的编排层**（`@MainActor @Observable`），持有 `settings` / `monitor` /
  `wireless` / `photos` / `queue` 五个子系统，并管理双栏各自的目录、选区与历史栈。
  Views 只做展示与转发，不含业务判断。
- **`Support/BrowserEntry`** 是把三种来源（本地 / 远端 / 照片）折成同一张表格的适配层。
  它带 `origin` 字段供右键菜单分流，但不携带任何行为。
- 依赖是单向的：`Views → AppModel → 子系统 → 进程层`，没有反向引用。

### 3.2 进程模型：两条不同的路径

这是本实现里最容易看错的一点 —— **sidecar 不是所有 adb 调用的代理**。

| 路径 | 谁在用 | 怎么起 | 用途 |
|---|---|---|---|
| **sidecar `droidberth-adb`** | `SpikeChecks`（验证面板） | `ProcessRunner`（Process + Pipe） | `version` / `resolve` / `doctor` / `exec` / `raw` |
| **`adb` 直调** | `DeviceShell` / `DeviceMonitor` / `WirelessManager` | `ProcessRunner` | `shell` / `ls` / `mkdir` / `rm` / `getprop` / `df` / `devices` |
| **`adb` 直调（pty）** | `TransferQueue` | `PtyProcess`（`openpty` + `posix_spawn`） | `push` / `pull` |

也就是说 sidecar 在产品路径里承担的是 **定位器 + 诊断器**：

```
ADBBinary.shared.path
  └─ SidecarLocator.locate()        相对 Bundle.main.executableURL 的同级目录找 droidberth-adb
       └─ SidecarClient.resolve()   让 Rust 侧决定 adb 在哪（沿用已验证的 adb::resolve）
            └─ 得到真实 adb 路径 → 之后所有设备操作直接调 adb
```

**为什么这样切**：`resolve` 与 `doctor` 是上一轮已经验证过的判据设计（14 项检查），
复用它们等于免费继承一套诊断能力；而每次 `shell` 都绕一层 sidecar 只会多一次进程启动开销，
没有任何收益。

`SpikeChecks` 里保留的 `exec` 路径是**有意保留的对照实现** —— 它能让同一件事
（如 `push`）在「经 sidecar」与「直调 adb」两种方式下各自重跑，便于比对。

### 3.3 数据模型与 id 命名空间（关键不变量）

`EntryTable` 的 `Table(entries, selection: $selection)` 是按 **`BrowserEntry.id`** 记选区的，
`primaryAction`（双击）与 `contextMenu` 都把 `BrowserEntry.id` 回传给 `onOpen`，
`MainView` 再拿它去领域模型里回查：

```swift
guard let local = model.localEntries.first(where: { $0.id == entry.id }) else { return }
```

**因此 `BrowserEntry.id` 必须等于领域模型的 `id`。** 当前的不变量：

```
LocalEntry.id  = url.path                 ←→  BrowserEntry.id = path
RemoteEntry.id = path                     ←→  BrowserEntry.id = path
PhotoItem.id   = asset.localIdentifier    ←→  BrowserEntry.path = localIdentifier
```

三者统一为「裸标识符」。**批量操作路径不经过 `BrowserEntry`**
（`AppModel` 直接用 `localSelection.contains($0.id)` 与领域 id 比对），
所以这类缺陷**只影响双击与右键「打开」**，不影响多选后的上传/下载/删除。
排查同类问题时别把这两条混在一起。

### 3.4 传输内核

**计划与执行分离**。`TransferPlanner` 只做纯计算，产出 `[TransferPlan]`（`Sendable`），
不碰进程；`TransferQueue` 负责并发泵、执行、收尾。

`TransferPlanner.upload` 依次做四件事：

1. **展开**：文件直接入列；目录走自建递归 `walk(root:)`（见 §4.2 为什么不能靠 `enumerator`）
2. **建目录**：收集所有父目录，一条 `mkdir -p` 建完
3. **重名处理**：`keepBoth` 策略下先 `ls` 拿已有名字集合，冲突时加 ` (1)`、` (2)` 后缀
4. **空间校验**：`df` 拿可用字节，不够则整体 `blockingError` 拦下（不做半途失败）

`TransferQueue` 的并发泵是 `maxConcurrency = AppSettings.concurrency`（默认 4），
每个任务在 `Task.detached` 里跑，进度回主线程更新 `TransferJob`。
**上传成功后**自动调 `MediaScanner` 做入库 —— 但这一步的判据偏宽，见 §6。

**进度上报靠 pty**：`adb push/pull` 只在 stdout 是 TTY 时输出 `\r[ 8%] <path>`。
`PtyProcess` 用 `openpty` + `posix_spawn`，并关掉
`ECHO|ICANON|ISIG|IEXTEN|OPOST|ICRNL`、设 `TIOCSWINSZ(40,200)`。
push 与 pull **两个方向都实测有进度**，不需要解析非 TTY 输出。

### 3.5 主动放弃 Intel

`project.yml` 设 `ARCHS: arm64`。这是一个**有意识的取舍**，不是遗漏：

spike 阶段实测发现 `droidberth-adb` 只有 arm64 切片，而 Xcode 默认 `ARCHS=standard`
会产出 universal 主二进制 —— 结果是 **Intel Mac 上 app 能启动、sidecar 起不来**，
属于「启动后静默失效」。两条修法（放弃 Intel / 让 sidecar 构建两个 triple 再 `lipo`）
中选了前者，因为目标设备是 Apple Silicon。

**这条要改回来时**：改 `ARCHS` 之前必须先让 `Scripts/build-sidecar.sh` 同时构建
`aarch64-apple-darwin` 与 `x86_64-apple-darwin` 并用 `lipo -create` 合并，否则回到静默失效。

---

## 4. 实现中的三个缺陷

三个都是**定位到根因后修掉**的，且都不是「代码写错一行」这种形状 ——
它们分别是「不收敛的循环」「与文件系统语义不一致」「两套命名空间」。
记录它们是因为**同类形状容易再次出现**。

### 4.1 主线程死循环 —— 面包屑求父目录

**现象**：app 启动后**窗口永不出现**，进程 `STAT=R`、CPU 打满。

**定位**：`sample <pid>` 显示 1232 个样本**全部**落在 `AppModel.localBreadcrumbs`。

**根因**：`FileManager.homeDirectoryForCurrentUser` 返回的 URL `hasDirectoryPath == true`，
对它反复调 `deletingLastPathComponent()` **不收敛于 `/`** —— 会产出 `/..`、`/../..`、
`/../../..` 无限增长，永远到不了不动点。

**一个会误导人的对照**：用字符串构造的 `URL(fileURLWithPath: "/Users/tango/")`
（`hasDirectoryPath == false`）**不会复现**。两者打印出来一模一样，别靠「看起来一样」推断。

**修法**：改用 `pathComponents` 正向拼接。

```swift
var result: [(String, URL)] = [("/", URL(fileURLWithPath: "/"))]
var url = URL(fileURLWithPath: "/")
for component in localDirectory.standardizedFileURL.pathComponents where component != "/" {
    url.appendPathComponent(component)
    result.append((component, url))
}
```

**排查结论**：全仓其余 6 处 `deletingLastPathComponent` 都是**单次调用**，无循环风险，未动。

### 4.2 文件夹上传静默放错位置 —— 符号链接与路径解析不一致

**现象**：上传一个位于 `/tmp/...` 的文件夹，设备上多出一层
`/sdcard/Download/x/private/tmp/x/...`，**且不报任何错**。

**根因**：`FileManager.enumerator(at:)` 返回的是**已解析路径**
（`enumerator(at: /tmp/x)` 吐 `/private/tmp/x/a.txt`），
而 `deletingLastPathComponent().path` 保留未解析形式（给 `/tmp`）→
`hasPrefix` 失败 → 回退成完整绝对路径 → 相对路径计算整体失效。

**最坑的一点**：「两边都 `resolvingSymlinksInPath()`」**修不了**。
Foundation 的解析器**不展开 `/tmp`**（实测 `root.resolvingSymlinksInPath()` 仍返回 `/tmp/entest`），
它和 enumerator 用的**不是同一套规则**。

**修法**：`TransferPlanner.walk(root:)` 自建递归，用 `contentsOfDirectory` +
`appendingPathComponent` 拼路径、`lastPathComponent` 拼相对段，彻底绕开文件系统解析。
符号链接目录**跳过不递归**（避免环）。

**触发场景**（不止 `/tmp`）：`/var`，以及 **iCloud 同步开启后的 `~/Desktop` / `~/Documents`**
（开启同步后它们就是符号链接）。也就是说这个缺陷在真实用户环境里比在测试环境里更容易出现。

### 4.3 双击 / 右键「打开」打不开 —— 两套 id 命名空间

**现象**：Mac 窗格里的文件夹双击无反应。

**根因**：见 §3.3。`BrowserEntry.id` 当时是 `"\(origin)-\(path)"`（形如 `local-/Users/…`），
而 `LocalEntry.id` 是裸 `path` —— 回查恒为 `nil`，**静默早退**。
`contextMenu` 的「打开」走同一条 `onOpen`，所以右键同样打不开。

**修法**（三处，缺一不可）：

| 文件 | 改动 |
|---|---|
| `Support/BrowserEntry.swift` | `self.id = path`（去掉 `origin-` 前缀） |
| `Photos/PhotoLibraryModel.swift` | `asBrowserEntry` 的 `path: localIdentifier`（去掉 `photos://`） |
| `Views/PhotoSourceView.swift` | 删掉为翻译两套 id 而写的 `tableSelection`，`selection:` 直通 `$model.photoSelection` |

**同形缺陷的波及面排查**（这一步比修本身更重要）：

- `remotePane.onOpen` 是**同一写法**，因 id 统一而一并修好；
- 6 处 selection 消费点全部核对，批量操作路径**本来就安全**（不经 `BrowserEntry`）；
- 全仓无人依赖 `"local-"` / `"remote-"` / `"photos://"` 前缀；
- `BrowserEntry.path` 全仓**从未被读取**；
- `openLocalSelection` / `openRemoteSelection` 是**死代码**（表格的 `primaryAction`
  自己完成了打开），本次未删，留作后续清理。

**验收状态**：修复后由用户人工确认「双击文件夹可以打开」（2026-09-26）。
开发环境无法截图也无法模拟点击，所以这一步只能由人完成 —— 在此之前本项一直是「链路可解析、
点击行为未验证」，见 §5.3。

---

## 5. 验证方法与被验证的边界

### 5.1 方法：把 app 的真实源码编成探针塞进 `.app` 副本

要验证「某个功能真的能用」，**不能**用复制出来的逻辑写测试 —— 那验的是副本。
做法是让 `swiftc` 直接编译本仓源文件，产物放到 `.app` 副本当主可执行文件：

```bash
swiftc -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos14.0 -swift-version 6 -strict-concurrency=complete -O \
  -o /tmp/probe.app/Contents/MacOS/DroidBerth src/*.swift   # 文件名必须与 CFBundleExecutable 一致
```

这样 `Bundle.main` 的语义与真实 app 完全一致，`SidecarLocator` / `ADBBinary` 能正常解析 sidecar，
**跑的就是要发货的那份代码**。本次两个探针（上传验证 12 段、图片验证 7 段）都走这条路。

补充约束：

- `@Observable` 宏在裸 `swiftc` 下**可以**编译，不需要 `--disable-sandbox`；
- 顶层代码是 `@MainActor` 隔离的，辅助函数要显式标 `@MainActor` 才能读写全局 `var`；
- **测进度必须放大文件 + 缩采样周期**：6 MB / 120 ms 只抓得到终态 `1.0`，
  60 MB / 15 ms 才看到 17 个不同百分比。

### 5.2 已实测（真机 HUAWEI DVC-AN20，USB）

| 项 | 证据 |
|---|---|
| sidecar 定位 | `.../DroidBerth.app/Contents/MacOS/droidberth-adb`，退出码 0 |
| 签名链 | 三个 Mach-O 全部 `flags=0x10000(runtime)` + `Timestamp=` + `TeamID=UKXWZ3FS84` |
| 进程封装 | stdout 20000/20000 行、stderr 20000/20000 行、超时 2102 ms 且 `timedOut=true`、无残留子进程 |
| 上传（多文件 + 文件夹递归） | 子目录层级正确；SHA-256 回验一致 |
| 重名 `keepBoth` | 正确产出 `photo-1 (1).jpg`，notes 提示「1 个文件在设备上已存在，将保留两者」 |
| 下载（文件夹递归） | `/sdcard/Download/x/{a.txt, sub/b.txt, sub/deep/c.txt}` 本地落盘内容全部正确 |
| 进度上报 | 60 MB 上传观察到 **17 个不同百分比**（0/8/14/…/100%），峰值 30 MB/s |
| 图片上传 + 相册入库 | 3 张 JPEG 的 `content://media/external/images/media` 均出现对应行 |
| id 对齐回归 | 模拟 `primaryAction` + `onOpen` 回查：3 项全命中，不一致 0 处 |
| 窗口存在 | `CGWindowListCopyWindowInfo` 报 `layer=0 alpha=1.0 740,375 1080x720` |
| 无死循环 | `STAT=S`、CPU 0.0%（对照 §4.1 的 `STAT=R`） |

### 5.3 未验证

| # | 项 | 为什么没验 |
|---|---|---|
| 1 | ~~**视觉与交互验收**（双击是否真的打开、拖拽手感、布局是否符合预期）~~ **双击/右键打开已人工确认可用**（2026-09-26，用户实测）。**拖拽手感与整体布局仍未验收** | 开发环境 `screencapture` 报 `could not create image from display`、`osascript` 无辅助访问权限，**点击行为只能由人确认** |
| 2 | 照片图库作为来源 | 需要人工在授权弹窗上点「允许」。代码路径已实现（`PhotoLibraryModel` + `PhotoExporter`），未跑真机 |
| 3 | App Translocation（spike 的 V1 场景 2） | 触发它需要 `com.apple.quarantine` 属性，而带该属性的**未公证** app 会被 Gatekeeper 直接拒绝启动 —— 在不降低系统安全设置的前提下无法构造。**要验它，得先有一个已公证的产物** |
| 4 | V5–V7（`NSBrowser` 分栏 / `NSFilePromiseProvider` 拖出 / `QLPreviewPanel`） | 未做 |
| 5 | 公证与 staple | 本次不涉及 |
| 6 | 干净 VM 上的安装验证 | 需要另一台机器 |
| 7 | 性能基线 | 没有可比基线。PRD §5 已把指标改为「相对裸 `adb push` 的开销」这一可测形式，尚未测量 |

### 5.4 一个流程性的坑（值得单独记）

用户报告「文件夹还是打不开」时，排查发现**两个在跑的实例都早于修复**：

```
pid 41861  build/Release/…              07:11 构建 / 07:11:04 启动
pid 53032  build/dd/Build/Products/…    07:37:28 启动
源码修复                                 07:39:44 落盘
```

`build/Release/` 与 `build/dd/Build/Products/Release/` 是**两个独立的产物目录**。
**验证 UI 改动前，先 `ps -o pid,lstart` 核对启动时间是否晚于所有相关源码的 mtime。**
不要凭「刚才构建过了」的记忆下判断 —— 构建目录不同就是不同的二进制。

---

## 6. 已知未修缺陷

### `MediaScanner.isIndexed` 的判据偏宽

**现象**：上传 `notes.txt` 也会显示「已进入相册索引」，但相册 app 里看不到它。

**根因**：`MediaScanner.queryURI = "content://media/external/file"` ——
这是 MediaStore 的 **file 表，涵盖所有文件类型**，不只是媒体。
而 `TransferQueue` 又对**所有 `direction == .upload` 的任务**调用扫描，不判文件类型。

直接验证（设备上造 `/sdcard/Download/txtprobe/a.txt`）：

```
content://media/external/file          → Row 0 _id=49323 _data=…/txtprobe
                                         Row 1 _id=49324 _data=…/txtprobe/a.txt   ← 命中
content://media/external/images/media  → No result found.                        ← 相册里没有
```

**结论**：`.txt` 确实进了 MediaStore 的 file 表，但**不会出现在相册 app 里**，
所以那句文案对非媒体文件是**误导**的。

**修法方向**（未实施）：按扩展名分流到 `images/media` / `video/media` / `audio/media`，
并对非媒体文件**根本不报这句**。

### 另一个观察：MediaStore 的行会在文件删除后残留

`rm -rf` 掉 `DCIM/DroidBerth` 后，`content query` 仍返回那些已不存在的行。
**拿相册查询当判据时，必须同时 `ls` 核对文件真的存在。**

### 代码层面的遗留

- `openLocalSelection` / `openRemoteSelection` 是死代码（见 §4.3），未清理。
- `SpikeView` / `SpikeChecks` / `SpikeReport` / `SpikeReportWriter` 是上一轮的验证面板，
  保留在 Release 里（入口 `--spike-report`）。是否随 MVP 一起发布，待定。

---

## 7. 未验证项集中列表

同 §5.3，此处只做优先级排序，供下一步排期：

| 优先级 | 项 | 前置条件 |
|---|---|---|
| ~~高~~ 已完成 | ~~双击 / 右键打开文件夹~~ | **2026-09-26 用户人工确认可用** |
| 高 | 拖拽手感与整体布局验收 | **需要用户人工操作**，无技术前置 |
| 高 | 照片图库来源全链路 | 需要人工点授权弹窗 |
| 中 | `isIndexed` 判据修正（§6） | 无 |
| 中 | 性能基线（相对裸 `adb push` 的开销） | 无 |
| 中 | 文件预览（Quick Look / 视频播放） | 见 `0926_02` §11 —— `quickLookPreview` 与 `VideoPlayer` 均可用，**主要成本在「远端文件需先下载」的交互设计** |
| 低 | V5–V7（分栏 / 拖出 / Quick Look） | 无 |
| 低 | App Translocation | **需要先有已公证产物** |
| 低 | 干净 VM 安装验证 | 需要另一台机器 |

---

## 8. 复现步骤

```bash
# 1. 暂存 sidecar（Rust 工具链由 scripts/env.sh 注入）
./macos/Scripts/build-sidecar.sh

# 2. 生成工程并构建
cd macos
USER=$(id -un) /opt/homebrew/bin/xcodegen generate
USER=$(id -un) xcodebuild -project DroidBerth.xcodeproj -scheme DroidBerth \
  -configuration Release -derivedDataPath build/dd build

# 3. 核对签名三项判据
for f in DroidBerth droidberth-adb adb; do
  codesign -dvvv "build/dd/Build/Products/Release/DroidBerth.app/Contents/MacOS/$f" 2>&1 \
    | grep -E '^(Identifier|TeamIdentifier|Timestamp|CodeDirectory)'
done

# 4. 运行
open build/dd/Build/Products/Release/DroidBerth.app

# 5. 验证面板（把 V1–V4 的判据与证据逐条重跑）
build/dd/Build/Products/Release/DroidBerth.app/Contents/MacOS/DroidBerth --spike-report
# 结果写入 ~/DroidBerth-reports/spike-<timestamp>.json
```

前置条件：xcodegen 2.46.0、Developer ID 证书
（`Developer ID Application: zhenzhi Tang (UKXWZ3FS84)`）、
一台 USB 连接的 Android 设备（仅传输相关验证需要）。

---

## 9. 与其它文档的关系

| 文档 | 关系 |
|---|---|
| `docs/0926_01_PRD.md` | 产品定义。本文不重复其内容 |
| `docs/0926_02_swift-native-spike-plan.md` | Go/No-Go 验证方案与执行记录。本文的 §2.3 / §5.2 直接承接其结论，**不推翻任何一条** |
| `docs/risk-validation-report.md` | Tauri 路线的分发风险验证。其 §3.6「受控实验的结论不能外推到它没覆盖的条件」正是本文 §2.3 三条设置的来源 |
| `docs/reusable-solutions-and-pitfalls.md` | 可复用方案与避坑清单 |
