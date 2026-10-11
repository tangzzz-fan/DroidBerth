# DroidBerth

**插上线，把 Mac 上的视频和照片推到手机，像用 Finder 一样浏览两端。**

DroidBerth 是一款 macOS 应用，在 Mac 与 Android 手机之间双向传输文件，**以「Mac → Android」为主场景优化**。
ADB 二进制内嵌在 app 内 —— 用户不需要装 Android SDK、不需要碰终端、不需要理解 ADB。

主用户是**摄影师 / 视频创作者**：手上有大量已在 Mac 上整理好的素材，需要推到 Android 手机上用于看片、给客户看、装到平板或备用机上播放。这决定了默认交互是「推」而不是「拉」，且单次传输量大（几十到几百个文件，单个可能上 GB）。

> **它不是**设备管理器，不是开发者工具，不是备份工具。范围刻意收窄。

**技术路线：Swift 原生（SwiftUI + AppKit），复用 Rust sidecar。** 全仓库单一实现路线，不存在并行的第二套外壳；`macos/` 是唯一的应用工程，`sidecar/` 是唯一的 ADB 定位 / 诊断组件。

> **关键词 / Keywords**：macOS ↔ Android 文件传输 · Mac 传视频 / 照片到手机 · ADB 图形界面（GUI）· Android File Transfer 替代 — macOS ⇄ Android file transfer · adb GUI · Android File Transfer alternative

---

## 与相邻方案的差别

| 方案 | 差别 |
|---|---|
| **Android File Transfer**（Google 官方） | 走 **MTP** 栈；本项目走 **ADB**。差别在技术栈与适用场景，**未做逐项横向实测**，因此不比较快慢 |
| 命令行 `adb push` / `adb pull` | 能力等价。差别在于本项目把这一层包成双栏界面，并把 `adb` **内嵌进 app** —— 用户不需要装 Android SDK、不需要碰终端 |
| 通用 MTP 客户端 / 设备管理器 | 与 ADB 是两条不同的栈，**本项目未评估**；且「设备管理」明确不在范围内 |

> 本项目**不**处理 MTP，**不**做备份，**不**做设备管理。范围与理由见 `docs/0926_01_PRD.md` §1–§3。

---

## 当前状态

**这是一个处于 MVP 阶段的仓库，不是可发布的产品。** 请按下面的「验证状态」理解它的成熟度。

| 层 | 状态 |
|---|---|
| 产品定义 | 完成（`docs/0926_01_PRD.md`，**v2.1**） |
| 技术路线验证 | **完成，判 Go**（`docs/0926_02_swift-native-spike-plan.md`） |
| Swift 原生外壳 MVP | **已实现，核心链路真机验证通过**（`docs/0926_03_swift-native-mvp-implementation.md`） |
| 视觉与交互 | **已补齐（2026-10-11）**：交互层早于 2026-10-10 全绿；随后一轮视觉与图标审计补上三条 P0 —— **应用图标**（原来完全缺失，`scripts/make-icon.py` 是个从未被调用的孤儿脚本）、**文件类型图标单一来源**（原来两栏各写一遍 switch 且已分叉）、**PRD §17.1 的连接引导卡片**（原来只是一行字符串）。另补品牌色定义、空态结构（四类各有图标与动作）与 WCAG AA 的数据列文字。**运行时行为与图标观感待人工验收**；VoiceOver 按要求跳过；动态字体与对比度只做到部分。审计与设计稿见 `docs/1010_01_ui-icon-design-report.md`，**设计令牌唯一来源**是 `docs/design/DESIGN.md` |
| 公证与分发 | **未做**（架构范围已决策：**arm64-only**，放弃 Intel，见 PRD §5.1） |

---

## 仓库结构

```
macos/                    Swift 原生外壳（唯一应用工程）
  project.yml               xcodegen 工程定义
  Sources/DroidBerth/       49 个 Swift 文件
  Resources/                Info.plist + entitlements + icon.{icns,png}（**图标入库**，见「图标不生效」）
  Scripts/build-sidecar.sh  编译 Rust sidecar 并暂存到 macos/Sidecar/
sidecar/droidberth-adb/   Rust sidecar（1788 行 / 5 文件，零第三方依赖）
                          version / doctor / resolve / exec / raw 五个子命令
scripts/                  构建、签名、公证脚本（Swift 路线）
  make-icon.py              App 图标生成器（零依赖；几何与投影参数见 docs/design/DESIGN.md §6）
vendor/                   adb 源码与 platform-tools（见「依赖与许可」）
docs/                     产品文档、验证方案、实现文档、UI/UX 改造方案、视觉审计报告
  design/                  设计令牌（DESIGN.md，唯一来源）+ open-design 稿快照
reports/                  doctor 报告输出
```

### sidecar 在架构里的位置

sidecar **不是所有 adb 调用的代理**，它承担的是**定位器 + 诊断器**：

```
SidecarLocator.locate()          相对 Bundle.main.executableURL 的同级目录找 droidberth-adb
  └─ SidecarClient.resolve()     让 Rust 侧决定 adb 在哪（沿用已验证的 adb::resolve）
       └─ 得到真实 adb 路径 → 之后所有设备操作直接调 adb
```

`doctor` 的 14 项检查是一套可复跑的判据设计，复用它们等于免费继承一套诊断能力；
而每次 `shell` 都绕一层 sidecar 只会多一次进程启动开销，没有收益。

---

## 构建与运行

### 前置条件

- macOS 14+，Apple Silicon（v1 不做 Intel，见 PRD §5.1）
- Xcode（含命令行工具）
- [xcodegen](https://github.com/yonaskolb/XcodeGen) 2.46.0
- Rust 工具链（由 `scripts/env.sh` 注入 `RUSTUP_HOME` / `CARGO_HOME`）
- Developer ID 证书（仅签名 / 公证相关步骤需要）

### 一键构建

```bash
./scripts/build.sh
```

它会依次：**生成 App 图标** → 暂存 sidecar → `xcodegen generate` → `xcodebuild`。
产物：`macos/build/dd/Build/Products/Release/DroidBerth.app`。

> 图标这一步必须在 `xcodegen generate` **之前** —— xcodegen 要求 `project.yml` 里列出的路径
> 存在，缺了 `macos/Resources/icon.icns` 它会直接报错。纯 Python 渲染一张 1024 母版约 50 秒，
> 所以只在 `scripts/make-icon.py` 比产物新时才重跑。

### 图标不生效 / Dock 上还是旧图标

`icon.icns` 已经是**入库的源文件**，所以「新克隆后没图标」不会是这条的原因。真正会咬人的是
**系统侧的 LaunchServices 记录与 Dock 缓存** —— 它们按 **bundle id** 缓存，而这个项目历史上
产生过**十几个同 id 的副本**（`DroidDock/` 旧路径、`/private/tmp/dd-*` 的测试副本、
`/Applications` 的旧副本……）。只要其中一条被标成 `active`，Dock/Finder 就会拿**那一份**的图标。

排查三步（都是只读，先从第一步看起）：

```bash
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 1. 看这个 bundle id 现在有哪些记录、路径还在不在
"$LSR" -dump | grep -B3 -A8 dev.tango.droidberth

# 2. 清掉指向已消失路径的「幽灵记录」，并强制刷新当前产物
"$LSR" -u /path/to/dead/DroidBerth.app        # 可重复，逐个来
"$LSR" -f macos/build/dd/Build/Products/Release/DroidBerth.app

# 3. 丢掉 Dock 的图标缓存
killall Dock
```

**2026-10-11 实测**：那次 `active` 记录指向 `/private/tmp/dd-sandboxtest/...`（早就没了），
`grep` 出来一眼可见；清掉幽灵记录 + `killall Dock` 之后，`NSRunningApplication.icon`
就返回了品牌橙底板。

> 判断「Dock 到底拿到了什么图标」不要靠截图 —— 跑现成的诊断脚本：
>
> ```bash
> mkdir -p /tmp/dockicon && cp scripts/diagnose-dock-icon.swift /tmp/dockicon/main.swift
> swiftc -O -o /tmp/dockicon/run -target arm64-apple-macos14.0 \
>   -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
>   -swift-version 6 -strict-concurrency=complete -Xfrontend -disable-sandbox \
>   /tmp/dockicon/main.swift && /tmp/dockicon/run
> ```
>
> 它读的就是 **`NSRunningApplication.icon`** —— Dock 用的那个值：通用应用图标是白/灰，
> 本项目的图标在 `(w/4, h/2)` 处是 `(240,151,67)` 品牌橙（正中反而是白的，
> 因为两块白面板在中间接缝，**判据看 (w/4, h/2)**）。顺带列出磁盘上各副本的图标状况。

### 分步（等价，便于调试）

```bash
# 0. 生成 App 图标 —— 必须在 xcodegen 之前
python3 scripts/make-icon.py macos/Resources

# 1. 暂存 sidecar —— 必须先跑，否则 Xcode 的 preBuildScript 直接 fail
./macos/Scripts/build-sidecar.sh

# 2. 生成工程并构建
cd macos
USER=$(id -un) /opt/homebrew/bin/xcodegen generate
USER=$(id -un) xcodebuild -project DroidBerth.xcodeproj -scheme DroidBerth \
  -configuration Release -derivedDataPath build/dd build

# 3. 运行
open build/dd/Build/Products/Release/DroidBerth.app
```

`USER=$(id -un)` **不是装饰**：某些 shell 环境里 `USER` 未设置，
XcodeGen 会报 `Couldn't find current username` 且**静默不生成工程**。

### 在 Xcode 里调试

打开 `macos/DroidBerth.xcodeproj`，scheme 的 Run 用 **Debug** 配置。两个前置条件：

1. **Debug 必须带 `com.apple.security.get-task-allow`** —— 调试器 attach 的许可票。
   `project.yml` 里它是**按配置**声明的：Debug `YES`、Release `NO`。
   Release 绝不能带 —— 带它的包**无法公证**，会直接把公证链断掉。
   ```bash
   # 自检：Debug 应有 4 项、Release 应有 3 项（没有 get-task-allow）
   codesign -d --entitlements - macos/build/dd/Build/Products/Debug/DroidBerth.app
   codesign -d --entitlements - macos/build/dd/Build/Products/Release/DroidBerth.app
   ```
2. **系统开发者模式**。若 Xcode 报 `Not allowed to attach to process`，先看它：
   ```bash
   DevToolsSecurity -status              # 应为 "Developer mode is currently enabled."
   sudo DevToolsSecurity -enable         # 需要管理员密码
   ```
   > `DevToolsSecurity -disable` 状态下，非 root 用户的 `task_for_pid` 会被额外限制。
   > 这条与第 1 条是**两个独立的开关**，都关着时症状完全一样
   > （`IDEDebugSessionErrorDomain Code 6` / `DBGLLDBLauncher`），排查时两条都要看。

### 签名与公证

```bash
./scripts/checklist.sh                    # 跑 sidecar 的 14 项自检
./scripts/notarize.sh                     # zip → 公证 → staple → 出 DMG → 公证 DMG
./scripts/resign.sh                       # 需要在 Xcode 之外重签时用
./scripts/verify-clean.sh <dmg> --apply --replace --quarantine
```

### 快捷键

| 快捷键 | 动作 |
|---|---|
| `⇧⌘U` | 上传选中项到设备 |
| `⇧⌘S` | 下载选中项到 Mac |
| `⇧⌘N` | 在设备端新建文件夹 |
| `⌘C` / `⌘V` | **跨栏传输**：Mac 栏选中 → 设备栏粘贴 = 上传；反向 = 下载（焦点在输入框时恢复文本语义） |
| `⌘X` | **设备端剪切**：切到目标目录后 `⌘V` = 移动（Mac 端的移动交给 Finder，不在此列） |
| `Space` | Quick Look 就地预览，**再按一次收起**（面板内可用方向键在条目间切换；远端文件先拉到 `$TMPDIR/DroidBerth/preview/`） |
| `⌘F` | 聚焦搜索框（筛选作用于聚焦窗格，作用域在编辑查询时锁定） |
| `⇧⌘X` | 交换左右窗格 |
| `⇧⌘P` | 显示 / 隐藏预览窗格（窗口右缘，显示聚焦窗格的选中项） |
| `⌘1` / `⌘2` / `⌘3` | 聚焦窗格切到列表 / 分栏 / 网格视图 |
| `⌘+` / `⌘-` | 放大 / 缩小网格图标（72–240 pt） |
| `⇧⌘.` | 显示 / 隐藏隐藏文件 |
| `Tab` / `⇧Tab` | 在左右窗格之间循环聚焦 |
| `⌘⌥←` / `⌘⌥→` | 聚焦**屏幕上的**左 / 右窗格（⇄ 交换后仍按视觉位置走） |
| `⌘[` / `⌘]` | 后退 / 前进 |
| `⌘↑` | 上一层文件夹 |
| `⌘R` | 刷新聚焦窗格 |
| `⌘⌫` | 删除设备端选中项（不可撤销） |
| `⌘,` | 打开设置 |

> `Space` 与 `Tab` 由本地事件监听（`Support/PaneKeyMonitor.swift`）接管，并带「正在编辑文本」守卫，
> 因此输入框里的空格与 Tab 保持系统默认语义。**菜单里刻意不给它们挂快捷键**——无修饰键的菜单
> 快捷键会先于文本框拿到事件。
>
> 全部计划内的快捷键都已接通。开着预览窗格时，**窗口最小宽从 900 提到 1180**（预览栏 260pt，没有弹性）。

### 编译验证（无需 Rust 工具链 / adb）

本机没有 Rust 工具链与 adb 二进制时，完整 `xcodebuild` 跑不通，可以用这一条做 Swift 侧回归：

```bash
swiftc -typecheck -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 6 -strict-concurrency=complete -parse-as-library \
  $(find macos/Sources -name '*.swift')
```

去掉 `-typecheck` 换成 `-o /tmp/x` 还能顺带验证链接（能确认 `_QuickLook_SwiftUI` 这类
Swift overlay 框架被正确自动链接）。

**文件类型图标映射的回归核对**（约 5 秒，29 条断言）：

```bash
mkdir -p /tmp/iconcheck && cp scripts/check-icon-mapping.swift /tmp/iconcheck/main.swift
swiftc -O -o /tmp/iconcheck/run -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 6 -strict-concurrency=complete -Xfrontend -disable-sandbox \
  macos/Sources/DroidBerth/Support/FileTypeIcon.swift \
  macos/Sources/DroidBerth/Support/ByteFormat.swift /tmp/iconcheck/main.swift
/tmp/iconcheck/run
```

它守的是一类**静默**缺陷：同一份事实写两遍之后分叉。它挡的是
`.apk` 在 Mac 栏显示成通用文稿、`.app` 在设备栏显示成通用文稿这类问题 ——
这些都不会被编译器或任何既有测试发现。

**传输语义的回归核对**（约 5 秒；折叠规则 / 冲突与改名 / 名称校验 / 缩略图范围）：

```bash
mkdir -p /tmp/transfercheck && cp scripts/check-transfer-semantics.swift /tmp/transfercheck/main.swift
swiftc -O -o /tmp/transfercheck/run -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 6 -strict-concurrency=complete -Xfrontend -disable-sandbox \
  macos/Sources/DroidBerth/Support/NameComparison.swift \
  macos/Sources/DroidBerth/Transfer/NameConflict.swift \
  macos/Sources/DroidBerth/Support/DeviceNameRules.swift \
  macos/Sources/DroidBerth/Support/ThumbnailPolicy.swift \
  macos/Sources/DroidBerth/Support/ByteFormat.swift /tmp/transfercheck/main.swift
/tmp/transfercheck/run
```

它守的是**同一族**缺陷的第二种形态 —— 前者是「同一份事实写两遍分叉」，
它是「**同一个概念在两端语义不同，代码只按一端写**」，而这一族的默认后果是
**静默覆盖用户手机上的文件**（设备端卷不区分大小写）或**静默的功能缺失**
（远端 64 KB 通道对视频必失败）。断言直接由**实测表**驱动，理由与证据见
`docs/1011_01_device-acceptance-report.md` §2 与 §9。

> 代价要认：这两个脚本**不会**在构建或 CI 里自动跑，靠人记得跑。

### 验证面板

把技术验证的判据逐条重跑（不依赖 UI）：

```bash
build/dd/Build/Products/Release/DroidBerth.app/Contents/MacOS/DroidBerth --spike-report
```

**它把报告打在 stdout 然后 `exit(0)`**（`SpikeReport.emit() -> Never`）—— 所以可以管道、可以重定向，
但**不会**自己写文件。写 JSON 到 `~/DroidBerth-reports/spike-<timestamp>.json` 的是 app 里的
**验证面板**（`SpikeView` 调 `SpikeReportWriter.write`），那条路要开 GUI。

四项判据 `V1`（sidecar 定位）/ `V2`（签名链 `doctor`）/ `V3`（进程封装）/ `V4`（端到端：`push` → `ls -l` 复核 → `rm`）。
**`V4` 在没有设备时标 `manual`，接上设备后才有意义**：

```
SUMMARY: V1=pass V2=fail V3=pass V4=pass      # 接上 Android 模拟器时的实测结果
```

`V2` 在 MVP 阶段**必然 fail** 两项（未公证、未装进 `/Applications`），这是 PRD §28 的发布前动作，不是缺陷。

### 产物路径注意

仓库会同时存在 `macos/build/Release/` 与 `macos/build/dd/Build/Products/Release/` 两个产物目录。
**验证 UI 改动前先核对进程启动时间是否晚于源码 mtime**，否则会看着旧二进制下结论 —— 这个坑真实踩到过。

---

## 排障与诊断

用户报「传不动 / 打不开 / 刚才闪退了」时，**手上必须要有现场**。这套机制就为这一件事，
完整方案与取舍见 [`docs/1011_02_observability-report.md`](docs/1011_02_observability-report.md)。

### 用户侧：一次点击

**帮助 → 导出诊断报告…** → 在桌面生成 `DroidBerth-diagnostics-<时间>.zip`（并自动在访达里选中）。
让用户把这个 zip 发回来即可。包里 9 类内容：环境 / 会话哨兵 / 崩溃报告 / 未捕获异常 / 日志 /
自检报告 / sidecar-doctor / adb 现场 / 设备列表。

**没有自动上传**，包只生成在用户机器上。所有文本**写入前就脱敏**（家目录用户名 → `~`、
设备序列号 → 前 3 位、RSA 指纹 → 前两组）。

### 开发者侧：一条命令

```bash
APP=build/dd/Build/Products/Release/DroidBerth.app/Contents/MacOS/DroidBerth
$APP --diagnose                      # 打印摘要：环境 / 上次是否异常结束 / 崩溃报告 / adb / 日志尾部
$APP --export-diagnostics            # 生成 zip 到桌面，打印路径
$APP --export-diagnostics=/tmp/out   # 指定落点（等号形式与空格形式都支持）
```

> ⚠️ **写命令行分派时的一个坑**：`firstIndex(where: { $0 == "--export-diagnostics" })` 用的是
> **精确相等**，于是 `--export-diagnostics=/tmp/out` 匹配不上、静默落到 GUI 分支 —— 在终端里的
> 表现是「命令挂住不返回」（图形进程不自己退出），而且不报任何错。必须写成
> `$0 == "--export-diagnostics" || $0.hasPrefix("--export-diagnostics=")`。
> 现在还有一个兜底：未识别的 `--xxx` 会往 stderr 说一句再继续。

### 崩溃怎么收

**四类故障要分开处理**，混在一起谈必然做不对：

| 故障 | 现场 | 谁给的 |
| --- | --- | --- |
| app 崩溃（强制解包 nil / 越界 trap / 内存错误） | `~/Library/Logs/DiagnosticReports/` 的 `.ips`，带全线程栈 | 系统 |
| **未捕获的 ObjC 异常** | `NSSetUncaughtExceptionHandler` 记一笔 | **我们**（系统不为它生成 `.ips`） |
| **异常退出但没有信号**（强退 / 掉电 / `SIGKILL`） | 会话哨兵：启动写标记、正常退出补结束时间 | **我们** |
| 子进程故障（adb / sidecar 崩了 / 起不来 / 超时） | 失败才记：命令 + 退出码 + stderr 尾部 | **我们** |

**不自己装 signal handler** —— 崩溃那一刻进程状态已不可信，在里面调 Foundation 会二次崩溃，
反而把系统本来能生成的完整报告弄丢。系统那块写得比我们好，只补它不做的那几格。

### 日志

- 统一日志：`log show --last 1h --predicate 'subsystem == "dev.tango.droidberth"'`
- 磁盘：`~/Library/Logs/DroidBerth/DroidBerth-<日期>.log`（按天分、保留 7 天、单文件 4 MB 滚动）

**刻意只记失败**：设备轮询每 1–5 秒一次 `adb devices -l`，全记进去会把真正出事的那行埋掉。

---

## 验证状态

沿用文档的约定，明确区分「已实测」与「未验证」。

### 已实测（真机 HUAWEI DVC-AN20，USB）

- sidecar 定位与执行、`doctor` 14 项检查
- 签名链：三个 Mach-O 全部 `flags=0x10000(runtime)` + `Timestamp=` + TeamID 一致
- 进程封装：stdout/stderr 各 20000 行不卡死、超时精确生效且无残留子进程
- **上传**：多文件 + 文件夹递归 + 重名 ` (1)` 后缀 + SHA-256 回验一致
- **下载**：文件夹递归层级与内容正确
- **进度上报**：60 MB 上传观察到 17 个不同百分比，峰值 30 MB/s
- **图片上传 + 系统相册入库**：MediaStore 的 `images/media` 表出现对应行

### 已实测（Android 模拟器，2026-10-11）

本机装有 Android Studio 2026.2 与 SDK（`~/Library/Android/sdk`），AVD **`Pixel_10`**。
**这补上了一条不需要手机的自动化路径** —— `--spike-report` 的 `V4` 在有设备时才成立。

> 本节是**环境与连通性**的实测。**功能层面的完整验收**（缩略图成品率、设备卷语义、文件名字符集与长度、
> 媒体入库三态）在同一环境下另跑了一轮，结论与可重跑脚本见
> **`docs/1011_01_device-acceptance-report.md`** 与 `docs/device-acceptance/2026-10-11/`。
> 那一轮量出两条真缺陷 —— **上传方向在不区分大小写的设备卷上会静默覆盖**（会丢用户数据）、
> **远端缩略图成品率只有 3/8**（视频全失败）—— 并**已连同同族的另外两处一起修掉**（报告 §9），
> 各带一份可重跑的回归（`scripts/check-transfer-semantics.swift`）。

| 项 | 实测结果 |
|---|---|
| 项目内嵌 adb 与 SDK 的 adb | **逐字节相同**（`sha256 1811e253…`，版本 `37.0.1-15733141`）⇒ 不存在「两套 adb 版本不一致静默改变行为」的风险；`doctor` 的 `adb.port_5037` 那项在这台机器上是无害的 |
| 端到端 `V4` | **pass**（`push` → `ls -l` 复核 → `rm` 全通） |
| 镜像 | Android **17 / API 37.2**，`google_apis_playstore_ps16k`，**16 KB 页大小**（`PAGE_SIZE=16384`，product `sdk_gphone16k_arm64`）。`ro.build.type=user` / `ro.debuggable=0` ⇒ **没有 `adb root`** |
| **媒体入库（PRD §19）** | `push` 一张 JPEG 到 `/sdcard/DCIM/` 后**立刻**就能在 `content://media/external/images/media` 查到该行 ⇒ **API 37 上是自动入库的**，印证了 PRD §19.2「Android 11+ 起 MediaProvider 走 FUSE，可能自动入库」的推断 |
| `cmd -l` 的扫描服务 | **没有** `media_scanner` / `media.scan` ⇒ app 会回退到广播 `MEDIA_SCANNER_SCAN_FILE`（广播返回 `result=0`）。文件本来就已经入库，所以兜底在这台设备上是**多余但无害**的 |
| 剩余空间（§20） | `df -h /sdcard` 可用 |
| 设备自述（app 的解析器看到的） | `emulator-5554 device product:sdk_gphone16k_arm64 model:sdk_gphone16k_arm64 device:emu64a16k` |

**已修：「System UI isn't responding」的 ANR**

根因是 AVD 的 **`hw.cpu.ncore=1`（单核）**，不是内存。判据与结果：

| 判据 | 改之前 | 改之后（`ncore=4`） |
|---|---|---|
| `top` 的 idle | **7%**（唯一那个核 93% 在忙） | **95%**（`381%idle`） |
| 90 秒观察窗 ANR | `ANR in` ≈ 10 条 + `Application Not Responding` 3 条 + 手势超时 1 条 | **0** |
| `dumpsys window lastanr` | 有 ANR 窗口挂着 | `<no ANR has occurred since boot>` |

原文很说明问题：**一大批不同进程同时中招**（`systemui` / `vending` / `googlequicksearchbox` /
`com.android.phone` / `printspooler` / 输入法），其中 `com.android.systemui spent 20023ms processing
MotionEvent` —— 这不是某个 app 的 bug，是**系统整体跑不动**。

**三条必须记住的模拟器特性**

1. **`sys.boot_completed=1` ≠ 存储就绪。** 实测：boot 完成后**立刻**访问 `/sdcard` 会 `Permission denied`
   （`push`、`ls`，连 `df` 都被拒），再等几秒到几十秒才正常。**判据必须是「实际写一次」**
   （`mkdir -p /sdcard/<probe>` 轮询），不能信 `boot_completed`。第一次跑就栽在这里。
2. **模拟器 ≠ 真机，已实测到一条差异**：`/sdcard/Android/data/` 在模拟器上**可写**（`touch` 返回 0），
   而 PRD §12.2 的假设是「Android 11+ 不可写入，所以不在 UI 里暴露」。原因大概是模拟器的 `shell`
   用户被授予了 `ext_data_rw` / `ext_obb_rw` 组。
   ⇒ **涉及设备端权限的结论不能只靠模拟器**，§12.2 仍须真机复核。
3. **GPU 仍是软件渲染（可再优化，但已不必要）**：`dumpsys SurfaceFlinger` 显示
   `ANGLE (... **SwiftShader** Device ... SwiftShader driver-5.0.0)`，即 `hw.gpu.mode=auto` 在这台机器上
   落到纯软件光栅化。4 核下已经扛得住（95% idle），所以没动。要再压一层就把 `hw.gpu.mode` 改成
   `host` —— **本机已证明它有效**（改后启动日志从 `gles_mode_selected:swangle` 变成 `gles_mode_selected:host`），
   但改完必须重启模拟器。

**范围边界**：SDK 里只有 **Android 17** 一张镜像（37.0 与 37.2 两档，都是 API 37），而 PRD §5 声明支持
**Android 10–16** —— API 37 在声明范围**之外**。所以它能回答「新版还能不能用」，但**替代不了** PRD §19 要求的
「至少 3 个真实 Android 版本（建议 10 / 13 / 15）」。补镜像要在 Android Studio 的 SDK Manager 里下载
（本机没有 `cmdline-tools`，因此没有 `avdmanager` / `sdkmanager` 命令行）。

> **当前测试基线（2026-10-11 起）**：**先在 API 37 上测，以当前可用环境为准** ——
> 不为了凑够「3 个版本」而先卡在下载镜像上。

### 未验证

| 项 | 原因 |
|---|---|
| 视觉与交互验收（双击、拖拽、布局、Quick Look、跨栏粘贴、排序、搜索、网格选择、分栏铺列、菜单、重命名、移动、预览窗格、**空态与设备引导卡片、系统彩色文件图标、数据列文字**） | 开发环境无法截图 / 无法模拟点击，**需要人工操作**。双击 / 右键打开已人工确认可用；**Phase 1–4、预览窗格与 2026-10-11 的视觉层改动仍未验收** |
| **图标观感**（App 图标是否与 Finder 并排无异物感、系统彩色文件图标在深色模式下的表现、16pt 档在 Finder 列表里的可辨识度） | 本机不能截图。几何与投影已用数值核对过（与系统图标的实测剖面均方误差约 0.77/255），**人眼结论需实测** |
| **设备厂商文案的准确性** | 小米 / OPPO / vivo / 三星 / 华为的额外授权步骤来自各家公开文档，**未逐机型真机核对**（本机只有一台华为 Android 10） |
| **~~网格缩略图的远端成品率~~** → **已实测 3/8，并按结论收敛** | 2026-10-11 在 API 37 模拟器上复刻真实路径测得（`docs/1011_01_device-acceptance-report.md` §1）：**jpg / png / heic 通过，gif / tiff / mp4 / mov 回退类型图标**；完整文件对照组 8/8 全通过，所以失败与截断有关。**原推断「HEIC 很可能解不出来」被推翻**（HEIC 的 `meta` 在文件头，64 KB 够）；**视频失败的头号原因是 `mdat` 字节数不足而非 `moov` 位置**（faststart mp4 512 KB 仍失败、1 MB 才成功）。**已决策并实施**：远端**只做图片**，`gif` / `tif` / `tiff` 连请求都不发；**本地仍保留视频缩略图**（文件就在本机，QL 实测 8/8 全通过）——这是「只在能保证成功的那一侧做」，不是砍功能。判据在 `Support/ThumbnailPolicy.swift` |
| 分栏视图的运行时行为 | `NSBrowser` 的铺列、异步补行、单选、双击预览、底部路径栏均未运行过；**行内类型图标**还多一层不确定 —— `willDisplayCell` 在 item-based 浏览器里是否被调用，Apple 文档没有明确承诺（不调用则退化为纯文本行，功能不受影响） |
| Quick Look 面板本身 | 改用 `QLPreviewPanel` 后，**面板能否真的被带出（响应者链那一步）在本机无法实测**；面板内方向键切换、跟随选择同样未验。见 PRD §23 |
| 网格「点空白处取消选择」与「单击选中」的延迟手感 | 单击与双击手势共存时 SwiftUI 会让单击等一个双击间隔；是否能接受需运行时确认 |
| 照片图库作为素材来源 | 需要人工在授权弹窗点「允许」 |
| App Translocation | 需要先有一个**已公证**的产物才能构造该场景 |
| 设备窗格 → Finder 拖出 | **未实现**（需 `NSFilePromiseProvider`），见 `docs/1009_01_uiux-revamp-plan.md` §2.6 |
| 设备端重命名 / 移动 | **已实现**（Phase 4），且**同名判据已修**（原先也是精确比较，与上传同一条缺陷，现走 `NameConflict`）。但**运行时行为仍未验证**：`mv` 的成功 / 失败提示、冲突整批拒绝的提示文案、⌘X→⌘V 的移动链路都没跑过 |
| **~~设备端文件名的合法字符集 / 长度~~** → **已实测并已修** | 2026-10-11：设备端**自己就拒绝** FAT32 那一组（`:` `*` `?` `"` `<` `>` `\|` `\` 与制表符，`EPERM`），`touch`/`mv` 与 `adb push` 两条通道被拒集合一致 ⇒ 不挡它**不会损坏数据**，但校验前移能把 errno 换成人话。**长度**：设备端限 **255 UTF-8 字节**，旧代码数的是 Swift 字素簇 ⇒ 100 个汉字 / 200 个 emoji 通过校验却在设备上 `File name too long`。两条都已修（`Support/DeviceNameRules.swift`） |
| **~~上传方向的「同名」判定会静默覆盖~~** → **已修** | 2026-10-11 实测：设备端 `/sdcard` **不区分大小写**，且折叠规则与 macOS 默认卷**完全是同一张表**（**Unicode 完整大小写折叠**：`ß`↔`ss`、连字 `ﬁ`↔`fi`、`K`(KELVIN)↔`k`、`σ`↔`ς` 都折叠；全角 `Ａ`↔`A`、`é`↔`e`、尾随空格**都不**折叠）。而旧代码是**精确字符串比较**、默认策略又是 **`.keepBoth`（保留两者）** ⇒ 上传 `photo.jpg` 时设备上已有的 `Photo.JPG` 被判为不冲突，`adb push` **静默替换**它的内容（**文件名不变**，事后很难察觉）。**同族还有三处**：重命名、移动的冲突预检（也是精确比较）、新建文件夹（完全没有检查）。现已全部走 `NameComparison` / `NameConflict`（纯函数），回归见 `scripts/check-transfer-semantics.swift` + 设备端集成证明 `docs/device-acceptance/2026-10-11/09-conflict-e2e.txt` |
| **名称校验与设备端实际语义不一致** → **已修** | 长度按 **255 UTF-8 字节**（旧代码数 Swift 字素簇 ⇒ 100 个汉字 / 200 个 emoji 通过校验却在设备上 `File name too long`）；`: * ? " < > \| \` 制表符前移（设备端自己就拒，`EPERM`），把 errno 换成人话并在提交前禁用「确定」。规则在 `Support/DeviceNameRules.swift`。**反向也要注意**：实测设备端**接受** `'` `` ` `` `$` `;` `&` 空格、中文、emoji、点前缀、前导 `-`，挡多了同样是错 |
| 无障碍 | **VoiceOver 未做**（用户 2026-10-10 要求跳过，每行仍无 accessibility label）；Reduce Motion 已实现但未验证；**对比度未用工具测量**，动态字体只做到「不给文字定宽」，都没在放大字号下逐屏核对 |
| 预览窗格的运行时行为 | 布局（右缘栏 + 窗口最小宽切换）、缩略图、多选合计、按来源的传输按钮都没跑过；缩略图同样带着「截断数据能否解码」的边界 |
| 「点选即聚焦」 | 新确立的交互规则（在哪个窗格改选择，焦点就落在哪个窗格）。它同时修掉了「点完设备栏再按 ⌘⌫ 什么都不发生」的静默错，但**行为变化本身未在运行时确认** |
| 菜单栏的「排序方式」「连接设备…」 | **未实现**：前者需要把列头排序接进菜单，后者需要输入 IP / 配对的向导。**刻意不摆灰项** |
| 照片图库网格的缩略图 | **未实现**：图库条目的 `path` 是 `localIdentifier`，缩略图要走 PhotoKit 的 `PHImageManager`；当前照片网格退类型图标，分栏回退成列表 |
| 工具栏搜索框的 `⌘F` 焦点行为 | `@FocusState` 在 `ToolbarItem` 里的行为**需运行时确认**；失败时降级为「点一下即可输入」，功能不受影响 |
| 性能基线（相对裸 `adb push` 的开销） | 未测量 |
| 干净 VM 上的安装验证 | 需要另一台机器 |
| **设备端存储卷（SD 卡 / 外置存储）** | 卷枚举（`ls /storage/`）、卷间跳转、面包屑替换、落点分流跟随当前卷、以及「记住的目标目录在被拔掉的卡上时回落到内部存储」都只做到编译通过。**本机没有真机**，所以连「`ls /storage/` 在真机上到底列出什么」都还没见到 |
| **媒体扫描命令的真机生效性** | 改成「探测 `cmd -l` 的名单」之后，`cmd media_scanner scan-file` / `cmd media.scan` 哪个真的存在、真的生效，仍要在 Android 10 / 13 / 15 上逐版本实测（PRD 附录 B #1）。结构上保证的只是：命令不对时不会静默假装成功 |
| 隐藏文件对称性 | 修法已落地，但「设备窗格里的 `.nomedia` 是否真按开关显隐」未在运行时确认 |

### 交互层面的已知偏离（2026-10-10 审查）

刻意保留或**尚未做**的非原生交互，逐条列出以便日后取舍：

| 项 | 现状 | 取舍 |
|---|---|---|
| **网格视图没有键盘导航** | `Table` / `NSBrowser` 都有原生方向键与 type-select（敲字母跳转），**只有 `LazyVGrid` 没有** | **当前最明显的一处脱节**。Finder 图标视图方向键是基本操作，值得补 |
| **回车重命名** | Finder 里选中按 Enter 进重命名；本产品只能从右键菜单进 | 重命名本身已实现，只差一个键位，成本低 |
| **Tab 循环窗格** | 全局吃掉 Tab 用于切换窗格（PRD §22 明文要求） | macOS 上 Tab 的原生语义是**在控件间移动焦点**，因此键盘用户走不到工具栏。这是**产品决策**，改法是换 `⌥Tab` 或加设置项 |
| Quick Look 缩放动画 | 未实现 `previewPanel:sourceFrameOnScreenForPreviewItem:` | 面板是淡入而不是从图标放大。要各视图给出源矩形，成本较高 |
| 空格接管 | 全局空格 = Quick Look，聚焦在按钮上时空格不再触发按钮 | 本产品窗格内可聚焦按钮极少，且 §23 明确要求空格 = Quick Look，接受 |

### 已修缺陷（2026-10-10 同类 app 坑点核对）

这一轮是拿同类型产品（Android File Transfer / OpenMTP / MacDroid）的公开坑点逐条核对本项目，
查出三条此前文档里没有的缺陷，都已修：

| 缺陷 | 判据 | 修法 |
|---|---|---|
| **隐藏文件过滤不对称** | `showHiddenFiles` 只进 `LocalFileSystem.list`；`loadRemote()` 把 `shell.list` 的结果原样赋值，远端从不过滤 ⇒ 设备窗格里 `.nomedia` / `.thumbnails` 永远可见，⇧⌘. 那一侧不生效 | 过滤收敛到 `AppModel.filterHidden`，列表 / 网格 / 分栏三个入口共用；开关变化时两侧都刷新，分栏视图靠 `.id()` 重建（它的子项是缓存的） |
| **下载重名检测大小写敏感，而 macOS 卷不敏感** | `TransferPlanner.download` 用 `Set(contentsOfDirectory)` 做 `contains`。本机实测卷不敏感（`touch ABC.txt` 后 `-f abc.txt` 为真）⇒ 设备上同时有 `IMG.JPG` 与 `img.jpg` 时，第二个不被判为冲突，**静默覆盖**第一个 | 按目标卷的 `volumeSupportsCaseSensitiveNames` 折叠大小写与 Unicode 组合形式后再比较；取不到卷信息时按**不区分**处理 —— 多一个 ` (1)` 只是碍眼，静默覆盖是丢数据 |
| **媒体入库的触发命令用的是已废弃广播** | `MediaScanner` 在发 `am broadcast MEDIA_SCANNER_SCAN_FILE`（API 29 已废弃），而 PRD §19.3 的策略写的是「以新 API 为基准」 | 改为**运行时探测** `cmd -l` 的服务名单，在 `cmd media_scanner scan-file` / `cmd media.scan` 之间选，都没有才退回广播 |

同轮还修掉了 `MediaScanner.isIndexed` 那条**已知未修缺陷**（它查 `content://media/external/file`
这张涵盖所有类型的表，导致上传 `.txt` 也报「已进入相册索引」）：判定改为三态
（`已入库` / `未查到` / **`非媒体文件` → 保持沉默**），查询按扩展名分流到
`images` / `video` / `audio` 三张表，再按 basename 精确核一遍。详见 PRD §19 的「实现现状」。

**当前没有已知未修缺陷。** 上面三类之外的问题都在「未验证」里 —— 那是**没跑过**，不是已知坏了。

---

## 文档索引

| 文档 | 内容 |
|---|---|
| `docs/0926_01_PRD.md` | 产品需求与产品设计（产品定位、功能需求、信息架构、设计原则）。**当前 v2.1** |
| `docs/0926_02_swift-native-spike-plan.md` | 换栈 Go/No-Go 验证方案与执行记录（V1–V4） |
| `docs/0926_03_swift-native-mvp-implementation.md` | **MVP 实现文档**：架构、三个已修缺陷、验证边界、未验证项 |
| `docs/1009_01_uiux-revamp-plan.md` | **UI/UX 分阶段改造方案**：交互层差距矩阵、Phase 0–4 任务分解与验收点 |
| `docs/1010_01_ui-icon-design-report.md` | **视觉层与图标层**：三条 P0 缺口、设计方案、S1–S5 实施计划与执行记录 |
| `docs/1011_01_device-acceptance-report.md` | **设备端验收报告（API 37 模拟器）**：远端缩略图成品率 3/8、设备卷大小写 / NFC 语义、文件名合法字符集与长度判据、媒体入库、测不到的项 |
| `docs/device-acceptance/2026-10-11/` | 上述报告的**原始日志与可重跑脚本**（5 份日志 + 5 个脚本） |
| `docs/design/DESIGN.md` | 设计常量唯一来源（色 / 尺寸 / 图标判据 / 图标几何契约 / 投影参数 / 已否决清单） |
| `.scratch/ui-simplification-tickets.md` | UI 精简（方案 A）+ P0 第一批 ticket 队列 |

---

## 依赖与许可

### adb 的来源

本仓库**不自建 adb**。`vendor/adb-build/` 是空目录，`vendor/platform_system_core/adb/` 不存在，
全树 `CMakeLists.txt` 为 0 个、`Android.bp` 为 15 个 —— 上游只有 Soong 构建路径。
`scripts/build-adb.sh` 自己的结论是：

> A self-built adb is a **build-glue project, not a script**.

当前使用 **SDK 的 `adb`**。其依赖全部是系统库（`otool -L` 非系统路径依赖 0 个），不构成公证障碍。

### 许可 —— 公开发布前必须确认

- 必须随包附 `NOTICE.txt`（当前位于 `vendor/platform-tools/NOTICE.txt`，
  注意 `vendor/` 已被 `.gitignore` 排除，**不随仓库分发**）。
- `NOTICE.txt` 声明整包 Apache-2.0；SDK 条款的**再分发禁令是 §3.4**，而 **§3.5 对开源许可组件有豁免**。
- 所以「必须自建才能公开分发」这个前提不成立。
- **但这仍不是法律意见。** 公开发布前必须让法务确认 §3.5 的适用性。**不要把它当成「无风险」。**
- 自建 adb 列为「若法务否决则切换」的备选，且必须按 **build-glue 项目** 立项，不是脚本。

### 其它约束

- sidecar 定位用**相对自身可执行文件**的路径，不用安装路径拼接。
- 子进程封装必须**同时抽干 stdout 和 stderr**，并带超时。
- 禁止手写 `hdiutil create`，统一走 `scripts/env.sh` 的 `make_signed_dmg()`。
- adb 只暂存到 `macos/Sidecar/`（该目录已被 `.gitignore` 排除），**不提交、不随仓库分发**。

---

## 参与开发

1. 改 `macos/Sources/` 后重新构建即可（纯 SwiftUI，无前端构建链）。
2. 改 `sidecar/droidberth-adb/` 后需要重跑 `./macos/Scripts/build-sidecar.sh`。
3. **改完必须重新构建 app** —— 验证探针跑的是源码，运行中的二进制不会自己更新。
4. 提交前建议核对签名三项判据：

```bash
for f in DroidBerth droidberth-adb adb; do
  codesign -dvvv "macos/build/dd/Build/Products/Release/DroidBerth.app/Contents/MacOS/$f" 2>&1 \
    | grep -E '^(Identifier|TeamIdentifier|Timestamp|CodeDirectory)'
done
```

---

## 许可

待定。见上方「依赖与许可」—— 公开分发前需要法务确认 `NOTICE.txt` 的适用性。
