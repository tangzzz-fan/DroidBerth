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
| 视觉与交互 | **已补齐（2026-10-11）**：交互层早于 2026-10-10 全绿；随后一轮视觉与图标审计补上三条 P0 —— **应用图标**（原来完全缺失，`scripts/make-icon.py` 是个从未被调用的孤儿脚本）、**文件类型图标单一来源**（原来两栏各写一遍 switch 且已分叉）、**PRD §17.1 的连接引导卡片**（原来只是一行字符串）。另补品牌色定义、空态结构（四类各有图标与动作）与 WCAG AA 的数据列文字。**运行时行为与图标观感待人工验收**；VoiceOver 按要求跳过；动态字体与对比度只做到部分。审计与设计稿见 `docs/1010_01_ui-icon-design-report.md`，**设计令牌唯一来源**是 `docs/design/DESIGN.md`。2026-10-11 还把 P1 的 **Finder 服务菜单**从一条 09-26 的老分支移植进来（**按当前代码重写**，不是 merge），并补上交互层最后两处脱节 —— **网格视图的键盘导航**（方向键 / ⇧ 扩展 / 字母跳转）与 **`⏎` 重命名**，判据见 `Support/GridNavigation.swift` 与 `scripts/check-grid-navigation.swift` |
| 公证与分发 | **链已跑通，发版方式已定型（2026-10-11）**：`build.sh` → `notarize.sh`（app zip 与 DMG 双双 `Accepted`、staple 通过）→ `checklist.sh`；发版收成**本机一条命令**（`./scripts/release-local.sh <版本> --publish`，实测干跑 2 分 11 秒），GitHub Actions 的 `ci.yml` 只负责验证（**实跑全绿**），签名凭据**不离开本机**（见「发行与发布」）。**尚未正式发版** —— 技术上只差一个版本号，但离「敢承诺 1.0.0」还差验收与发布工程两块，清单见 `docs/1011_03_1.0-roadmap.md`。架构范围已决策 **arm64-only**（放弃 Intel，PRD §5.1） |

---

## 下载与安装

发布页：**<https://github.com/tangzzz-fan/DroidBerth/releases>**

| 文件 | 说明 |
|---|---|
| **`DroidBerth-<版本>.dmg`** | **推荐**。已签名 + 已公证 + 已 staple |
| `DroidBerth-<版本>.zip` | 同一份 app 的压缩包；习惯直接拖 app 的人用这个 |
| `NOTICE.txt` | `adb`（Android platform-tools）的 Apache-2.0 声明。它也在 app 包内（`Contents/Resources/NOTICE.txt`） |
| `SHA256SUMS.txt` | 上面各文件的 SHA-256 |
| Source code (zip / tar.gz) | GitHub 为每个 Release 自动附带的**源码快照** |

**需要 Apple Silicon（M 系列）与 macOS 14 或更高。** 本项目不发 Intel 版本（PRD §5.1）。

安装：打开 DMG，把 **DroidBerth** 拖到旁边的 **Applications**。
（DMG 里带了一条 `/Applications` 的符号链接，正是为了这一步。）
包已公证，**不需要**「右键 → 打开」绕过 Gatekeeper。

校验下载：

```bash
shasum -a 256 -c SHA256SUMS.txt
```

> 想自己从源码构建：见下面的「构建与运行」。

---

## 仓库结构

```
macos/                    Swift 原生外壳（唯一应用工程）
  project.yml               xcodegen 工程定义
  Sources/DroidBerth/       60 个 Swift 文件
  Resources/                Info.plist + entitlements + icon.{icns,png}（**图标入库**，见「图标不生效」）
                            + NOTICE.txt（**构建期从 vendor/ 暂存**，不入库；PRD §28 要求随包分发）
  Scripts/build-sidecar.sh  编译 Rust sidecar 并暂存到 macos/Sidecar/
sidecar/droidberth-adb/   Rust sidecar（1788 行 / 5 文件，零第三方依赖）
                          version / doctor / resolve / exec / raw 五个子命令
scripts/                  构建、签名、公证、发布脚本（Swift 路线）
  make-icon.py              App 图标生成器（零依赖；几何与投影参数见 docs/design/DESIGN.md §6）
  build.sh                  唯一构建入口（图标 → NOTICE → sidecar → xcodegen → xcodebuild）
  notarize.sh               公证链五步（zip → staple → DMG → 公证 DMG → staple）
  release-local.sh          **本机发版**：构建 → 守卫 → 公证 → 验证 → 打包 → 建 Release
  package-release.sh        打 dist/（本机与 CI 共用；含 Release 说明）
  setup-release-secrets.sh  把 6 个 Repository secret 一次写进 GitHub（只在你要走 CI 签名时用）
  wizard-developer-id.sh    向导：Developer ID 证书 → notarytool 凭据 → 锁 .env → 手机 USB 调试；**人机步骤，不是自动化脚本**
  check-all.sh              四个回归守卫的统一入口
  fetch-adb.sh              新克隆后取 platform-tools（钉版本 + 双 sha256）
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

### 新克隆的仓库：先取一次 adb

```bash
./scripts/fetch-adb.sh
```

`vendor/` 被 `.gitignore` **刻意**排除（体积大 + 许可状态待确认，PRD §28 —— 见「依赖与许可」），
所以新克隆的仓库里**没有 adb**，而构建需要它。这个脚本从 Google 官方源取
**platform-tools r37.0.1**，校验 zip 与解出来的 `adb` 两道 sha256，然后落到 `vendor/platform-tools/`。

> 为什么钉死版本而不是用 `-latest`：adb 版本不一致会**静默改变行为**（`doctor` 的 `adb.port_5037`
> 就是为这个存在的），而项目里所有验收结论都是对着 `37.0.1-15733141` 那一份做的。
> 实测脚本取到的 `adb` 与本机已测的那份**逐字节相同**。Google 若重新打包同一版本，校验会**明确报错**
> 而不是静默换掉 —— 那是故意的，更新 pin 前请先重跑设备端验收。

### 一键构建

```bash
./scripts/build.sh
```

它会依次：**生成 App 图标 + 暂存 NOTICE** → 暂存 sidecar → `xcodegen generate` → `xcodebuild`。
产物：`macos/build/dd/Build/Products/Release/DroidBerth.app`。

> 图标与 NOTICE 这两步必须在 `xcodegen generate` **之前** —— xcodegen 要求 `project.yml` 里
> 列出的路径**存在**，缺了 `macos/Resources/icon.icns` 或 `Resources/NOTICE.txt` 它会直接报错。
> 图标那步纯 Python 渲染一张 1024 母版约 50 秒，所以只在 `scripts/make-icon.py` 比产物新时才重跑；
> NOTICE 来自 `vendor/`，缺了会给出「先跑 `./scripts/fetch-adb.sh`」的报错。

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
| `←` `→` `↑` `↓` | **网格视图**移动选择（左右是线性的：列首再按 `←` 回到上一行的最后一项） |
| `⇧` + 方向键 | 网格视图扩展选择（从锚点开始） |
| 字母 / 数字键 | 网格视图跳转到以它开头的项目。连敲同一字母在命中项之间轮转；停手 0.8 秒后重新开始 |
| `⏎` | **重命名**设备端选中项（恰好单选；列表 / 网格视图） |
| `Tab` / `⇧Tab` | 在左右窗格之间循环聚焦 |
| `⌘⌥←` / `⌘⌥→` | 聚焦**屏幕上的**左 / 右窗格（⇄ 交换后仍按视觉位置走） |
| `⌘[` / `⌘]` | 后退 / 前进 |
| `⌘↑` | 上一层文件夹 |
| `⌘R` | 刷新聚焦窗格 |
| `⌘⌫` | 删除设备端选中项（不可撤销） |
| `⌘,` | 打开设置 |

> `Space` 与 `Tab` 由本地事件监听（`Support/PaneKeyMonitor.swift`）接管，并带「正在编辑文本」守卫，
> 因此输入框里的空格与 Tab 保持系统默认语义。`⏎` 与网格视图的方向键 / 字母键同在这一个监听里，
> **只在聚焦窗格确实是网格、或确实有可重命名的单选时才拦**，否则原样交还系统 —— 列表与分栏的
> 原生方向键与 type-select 因此一行都没改，也不会被抢走。**菜单里刻意不给它们挂快捷键**——
> 无修饰键的菜单快捷键会先于文本框拿到事件（「显示 → 重命名…」只负责可发现性与启用态）。
>
> 全部计划内的快捷键都已接通。开着预览窗格时，**窗口最小宽从 900 提到 1180**（预览栏 260pt，没有弹性）。

### Finder 集成（服务菜单）

在 Finder 里选中文件或文件夹 → 右键 → **服务** → **发送到 DroidBerth**，直接推送到设备。

落点规则与窗格内上传**用的是同一份判据**（`AppModel.uploadDestination(for:candidateNames:)`）：
优先「上次使用的目录」，否则按文件类型分流（视频 → `Movies`、图片 → `DCIM`、其它 → `Download`）。
传输本身也复用 `AppModel.uploadFiles(_:toRemotePath:reason:)`，所以不可写目录的守卫（PRD §12.2）、
冲突策略、入队都只有一份实现。

> ⚠️ **App 必须装在 `/Applications`（或其子目录）。** Apple 对 services 的要求原文是
> *"install it in the Applications folder (or a subfolder)"*。实测中确实能观察到“登记路径跟着
> LaunchServices 里当前那份走”——第一次登记到的是构建目录里的副本，注销后才是 `/Applications`。
> 装完若菜单里没出现：`/System/Library/CoreServices/pbs -update` 触发重扫
> （`pbs` 在 macOS 27 上参数已变，**不是**老文档里的 `-dump_pboard`）；
> 仍不出现就注销重新登录 —— 服务列表是在**登录时**构建的。
>
> ⚠️ **别留同 bundle id 的第二份副本。** 服务按 bundle id / LaunchServices 记录路由，
> 多份副本会让它路由到错的那一份（这与「图标不生效」是同一类问题）。
> 自检登记到的是哪一份：
>
> ```bash
> /System/Library/CoreServices/pbs -dump | grep -A9 -i droidberth   # 看 NSBundlePath
> ```

**已验证 / 未验证**（2026-10-11 实测）：

| 项 | 结果 |
|---|---|
| `NSServices` 声明被系统登记 | ✅ `pbs -dump` 里有 `NSMessage = sendToDevice`、`NSSendFileTypes = public.item`、菜单项「发送到 DroidBerth」 |
| `NSPerformService("发送到 DroidBerth", …)` | ✅ 返回 `true`（服务可按名字解析到） |
| 消息送达 provider 并解析出文件 | ✅ App 在运行时实测：`sendToDevice 解析出 1 个项目` → `收到 1 个项目` |
| 交给 `AppModel` 之后的链路 | ✅ 走到 `正在等待设备` →（无设备时）20 秒后 `没有可用的设备`，两条 banner 与日志都对 |
| 真实上传到设备 | ❌ 未验证（测试时没有设备连着；设备端落点规则复用既有路径，风险低） |
| **App 未运行时由系统按 `NSPortName` 拉起** | ❓ **未定论**。三次尝试里有一次确实把 App 拉起来了（日志有「会话开始」），另两次 `NSPerformService` 返回 `true` 但 App 根本没启动。**别在文档里断言它可用**，需要时请手动在 Finder 里点一次确认 |

> 排查时最有用的一条：`sendToDevice` 里**没有错误可以外传**（services 的失败只表现为「点了没反应」），
> 所以它落了一行日志，把「没送达」与「送达了但解析出 0 个文件」分开 ——
> 日志在 `~/Library/Logs/DroidBerth/`。

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

**网格导航的回归核对**（约 5 秒；顺序 / 列数 / 方向键落点 / 字母跳转）：

```bash
mkdir -p /tmp/gridcheck && cp scripts/check-grid-navigation.swift /tmp/gridcheck/main.swift
swiftc -O -o /tmp/gridcheck/run -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 6 -strict-concurrency=complete -Xfrontend -disable-sandbox \
  macos/Sources/DroidBerth/Support/GridNavigation.swift \
  macos/Sources/DroidBerth/Support/NameComparison.swift \
  macos/Sources/DroidBerth/Support/BrowserEntry.swift \
  macos/Sources/DroidBerth/ADB/RemoteEntry.swift \
  macos/Sources/DroidBerth/Local/LocalFileSystem.swift \
  macos/Sources/DroidBerth/Support/FileTypeIcon.swift \
  macos/Sources/DroidBerth/Support/ByteFormat.swift /tmp/gridcheck/main.swift
/tmp/gridcheck/run
```

它守的是**第三种**形态的静默错 —— 前两种是「同一份事实写两遍分叉」与「同一概念两端语义不同」，
这一种是「**同一个列表在视图里排一次、在键盘逻辑里再排一次**」。方向键按屏幕上的次序走，
两处排序（或两处列数）有偏差不会报错也不会崩，只会让 `↓` 跳到肉眼看不见的地方。

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

> 这些脚本全都挂在 `scripts/check-all.sh` 里，而 **CI 每次 push 都会强制跑它**
> （`.github/workflows/ci.yml` → `check-all.sh`）。**本地不是自动的** —— 改完先 `build.sh`
> 再跑一次 `./scripts/check-all.sh`（第四个守卫要驱动 app 自己的导出命令，所以顺序不能反）。

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

## 发行与发布

### 怎么发一个版本（本机，推荐）

```bash
./scripts/release-local.sh 0.1.0             # 干跑：构建 → 守卫 → 公证 → 打包，不碰 GitHub
./scripts/release-local.sh 0.1.0 --publish   # 真发版：打 tag、推 tag、建 Release（会二次确认）
```

一条命令跑完 **构建 → `check-all` → 公证（app + DMG）→ 验证票据与 Gatekeeper → 打包 → 建 Release**。
版本号通过 `XCODEBUILD_ARGS` 注入（`Info.plist` 用的是 `$(MARKETING_VERSION)`），
所以 app 里显示的版本与 Release 上的 tag 一定一致。

Release 附件由 `scripts/package-release.sh` 产出 —— 本机与 CI **共用同一份规则**：

| 附件 | 来源 |
|---|---|
| `DroidBerth-<版本>.dmg` | 已签名 + 已公证 + 已 staple，含 `/Applications` 软链 |
| `DroidBerth-<版本>.zip` | 同一份 app（`zip -X -y`，无 `._` 垃圾项） |
| `NOTICE.txt` | `adb` 的 Apache-2.0 声明（也在 app 包内，PRD §28） |
| `SHA256SUMS.txt` | 上面各文件的校验和（**裸文件名**，下载后可直接 `-c`） |
| Source code (zip / tar.gz) | **GitHub 自动附带**，不需要我们做任何事 |

Release 说明取自 `dist/RELEASE-NOTES.md`（「下载 / 安装 / 校验」那一段），
`gh --generate-notes` 自动生成的变更清单接在其后（REST API 的 `body` + `generate_release_notes` 就是这个语义）。

> **为什么签名不走 CI。** Developer ID 私钥一旦放进 GitHub，就是一份**你无法收回的副本** ——
> 而它能做的不是「读你的数据」，而是**以你的名义签发任何 macOS 都信任的软件**。
> 这个仓库是 public 的：能推 workflow 的人就能把它打出来，而 **Actions 日志是公开的**
> （secret 掩码只在原样出现时生效，`base64` 一下就绕过）。本机本来就有全套凭据，这条链 4 分钟跑完。
> **所以签名与公证的凭据一步都不离开这台机器。**

### CI 做什么

两个流水线，分工是**「能不能编出来」与「能不能发出去」分开**。

| 文件 | 触发 | 干什么 |
|---|---|---|
| `.github/workflows/ci.yml` | push 到 `main`、每个 PR、手动 | 装工具链 → **取 adb** → 构建（ad-hoc 签名）→ `scripts/check-all.sh` → 断言自检 V1/V3 |
| `.github/workflows/release.yml` | **仅手动**（`workflow_dispatch`） | 装证书 → 构建 → 守卫 → 公证 → 校验 → 建 Release。只在你有意走 CI 签名时才用，见下面「如果你确实想用 CI 签名」 |

CI 的判据是「能不能编出可运行的产物 + 四个回归守卫过不过」。**它已经抓到过 4 处「本地编译过、
CI 编译器（Xcode 16.4）编译不过」的问题** —— 那是它最值钱的地方，与签名无关。

### CI 构建为什么也要走签名流程

CI 没有 Developer ID 证书，所以把签名身份覆盖成 ad-hoc：

```bash
XCODEBUILD_ARGS="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual" ./scripts/build.sh
```

**但嵌套签名的流程一步不少** —— app + sidecar + adb 三个 Mach-O 照样各签一遍。
这样「子二进制签不动 / 没带 hardened runtime」这类缺陷在 CI 就会暴露，不必等到发布那一刻。
`release.yml` 只是换成真证书（把 `XCODEBUILD_ARGS` 换成版本号，身份由钥匙串自动识别），脚本一行不用改。

> ⚠️ **不能用环境变量代替这个口子**。实测 xcodebuild **不会**把环境变量当成 build setting：
> `CODE_SIGN_IDENTITY=- xcodebuild …` 仍然用钥匙串里的真证书签，
> `MARKETING_VERSION=9.9.9 xcodebuild …` 产出的 `Info.plist` 仍是 `0.1.0`。
> 只有**命令行参数**这条路径可靠（实测命令行覆盖后得到 `Signature=adhoc flags=0x10002`、
> 版本号 9.9.9）。`scripts/build.sh` 的 `XCODEBUILD_ARGS` 就是为此留的透传口子。

### 闸门是什么

- `scripts/check-all.sh` —— 四个回归守卫（图标映射 / 网格导航 / 传输语义 / 诊断包）。本项目**没有测试 target**，
  这是那类「静默错」唯一的自动化防线，所以 CI 必须跑。
- 自检只断言 **V1**（sidecar 定位）与 **V3**（进程封装）。**V2 在 CI 里必然 fail**（它含
  「签名身份可用于公证」，ad-hoc 下不成立）、**V4 需要真机**恒为 manual —— 这两项是预期，不是缺陷。

### 如果你确实想用 CI 签名

**别裸传。** 先把这几件事做掉，再考虑把凭据放上去：

1. **secret 放进 Environment 并设 required reviewers**（比如叫 `release`）—— 这样任何 workflow
   引用它之前都必须人工批准，「偷推一个 workflow」就不能静默取用。
   本仓库当前 **environment 数 = 0**，等于完全没有闸门。
2. **action 钉 commit SHA** 而不是 tag（tag 可以被移动）。
3. 优先用 **App Store Connect API key**（`notarytool --key/--issuer/--key-id`）而不是 Apple ID 的
   app-specific password：作用域更窄、可单独吊销、不影响 Apple ID 本身。
   ⚠️ `scripts/env.sh` 与 `build.sh` 已经预留了 `APPLE_API_KEY` / `APPLE_API_ISSUER`，
   但 `scripts/notarize.sh` 目前只实现了 profile 与 Apple ID 两条路，要用得先补。
4. **恢复 `release.yml` 的 tag 触发器**（当前刻意只有 `workflow_dispatch`，免得每次打 tag 都跑出一个
   注定失败（缺 secret）的 job）：

   ```yaml
   on:
     push:
       tags: ["v*"]
     workflow_dispatch:
   ```

**6 个 secret**（`release.yml` 的第一步会逐个检查并报出缺哪个，所以漏了不会让你猜）。
其中三件本来就在 `.env` 里，所以最快是一条命令：

```bash
# 先导出只含 Developer ID 的 .p12（见下面的警告），然后：
./scripts/setup-release-secrets.sh --p12 ~/Desktop/证书.p12
```

脚本只做「把本机已有的凭据搬进仓库设置」这一步：不生成新凭据、不打印任何凭据值。
手工也行（**Settings → Secrets and variables → Actions → New repository secret**，一次一个）：

| Secret | 是什么 | 从哪来 |
|---|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID 证书的 `.p12`，base64 后的**单行** | `base64 -i cert.p12 \| pbcopy` |
| `P12_PASSWORD` | 导出 `.p12` 时设的密码 | 导出时你自己设的 |
| `KEYCHAIN_PASSWORD` | 任意随机串；CI 上临时钥匙串的密码 | 随便编一个 |
| `APPLE_ID` | Apple ID 邮箱 | `.env` 里已有 |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password | `.env` 里已有；否则 [appleid.apple.com](https://appleid.apple.com) → 登录与安全 → App 专用密码 |
| `APPLE_TEAM_ID` | 10 位 Team ID | `UKXWZ3FS84` |

> ⚠️ **导出 `.p12` 时只选 Developer ID 那一张，不要「导出所有项目」。**
> 本项目实测过 `security export -t identities` 也能无 GUI 导出，但它带出来的是**三个身份**
> （Apple Development / Apple Distribution / Developer ID）。CI 只需要 Developer ID 那一把 ——
> 多搬两把私钥是没必要的暴露面。
>
> 变量名对不上是刻意的：secret 叫 `APPLE_APP_SPECIFIC_PASSWORD`，流水线里映射成环境变量
> `APPLE_PASSWORD` —— 因为 `scripts/notarize.sh` 读的是 `APPLE_ID` / `APPLE_PASSWORD` / `APPLE_TEAM_ID`。

**干跑**（不建 Release，只出 artifact）：Actions → Release → Run workflow → 填一个版本号。
用于在真正打 tag 之前验证签名与公证这条链 —— 值得在第一次发版前跑一次。

### 一条注意

runner 用的是 `macos-15`。选它是因为在公开仓库上这个 label 就是 **Apple Silicon**，
而本项目只发 arm64（`ARCHS: arm64` 写死在 `project.yml`）—— 换成 `macos-15-large` 会拿到 Intel。
若某天编译在新版 Xcode 上失败，改这两处 `runs-on:` 即可（`ci.yml` 与 `release.yml` 各一处）。

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
| **网格键盘导航的运行时行为** | 方向键跳跃（尤其 `↑` / `↓` 是否与屏幕上的一整行对齐）、字母跳转的轮转与 0.8 秒超时、`⇧` 扩展、滚进视野都没跑过。**列数由视图经 `GeometryReader` 回报，量到的宽度与 `.adaptive` 的实际铺列是否一致只能在运行时看** —— 不一致的表现是上下键跳错一行，不报任何错 |
| **回车重命名的运行时行为** | 键位与菜单项是否都进来、预填与 Esc 取消、以及冲突被拒时的提示文案，都没跑过 |
| 照片图库作为素材来源 | 需要人工在授权弹窗点「允许」 |
| **Finder 服务在 App 未运行时的拉起路径** | **未定论**：三次尝试里只有一次真的把 App 拉起来了（日志有「会话开始」），另两次 `NSPerformService` 返回 `true` 但 App 根本没启动。**App 已在运行时的送达与解析已实测通过**。详见上面「Finder 集成（服务菜单）」一节 |
| Finder 服务完成一次真实上传 | 测试时没有设备连着，只走到「没有可用的设备」；设备端落点规则与窗格内上传共用，风险低但未端到端跑过 |
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

### 交互层面的已知偏离（2026-10-10 审查，2026-10-11 补两项）

刻意保留或**尚未做**的非原生交互，逐条列出以便日后取舍：

| 项 | 现状 | 取舍 |
|---|---|---|
| ~~网格视图没有键盘导航~~ → **已补（2026-10-11）** | `Table` / `NSBrowser` 都有原生方向键与 type-select（敲字母跳转），**只有 `LazyVGrid` 没有** | 已补：方向键 / ⇧+方向键 / 字母跳转 / 滚进视野。判据是 `Support/GridNavigation.swift`（**顺序**与**列数**各一个纯函数，视图与键盘逻辑共用），回归见 `scripts/check-grid-navigation.swift`。**运行时手感未验证** |
| ~~回车重命名~~ → **已补（2026-10-11）** | Finder 里选中按 Enter 进重命名；此前只能从右键菜单进 | `⏎` 已接（列表 / 网格）。**分栏刻意不给** —— 它的冲突预检比的是**当前目录**，而分栏选中的条目可能在子目录，预检会漏判成 `mv` 静默覆盖。菜单项「重命名…」不挂快捷键 |
| **Tab 循环窗格** | 全局吃掉 Tab 用于切换窗格（PRD §22 明文要求） | macOS 上 Tab 的原生语义是**在控件间移动焦点**，因此键盘用户走不到工具栏。这是**产品决策**，改法是换 `⌥Tab` 或加设置项 |
| Quick Look 缩放动画 | 未实现 `previewPanel:sourceFrameOnScreenForPreviewItem:` | 面板是淡入而不是从图标放大。要各视图给出源矩形，成本较高 |
| 空格接管 | 全局空格 = Quick Look，聚焦在按钮上时空格不再触发按钮 | 本产品窗格内可聚焦按钮极少，且 §23 明确要求空格 = Quick Look，接受 |
| 网格视图的选中延迟 | 单击与双击手势共存时 SwiftUI 会让单击等一个双击间隔 | 键盘移动因此比鼠标更快「跟手」；是否可接受需运行时确认 |

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
| `docs/design/1011_01-design-compliance.md` | **设计稿符合性审计（78 条：一致 53 / 偏离 16 / 未实现 9）**：逐条比对 `DESIGN.md` 与实现，给出偏离与未实现清单 |
| `docs/1011_01_device-acceptance-report.md` | **设备端验收报告（API 37 模拟器）**：远端缩略图成品率 3/8、设备卷大小写 / NFC 语义、文件名合法字符集与长度判据、媒体入库、测不到的项 |
| `docs/1011_02_observability-report.md` | **可观测性方案**：日志 / 崩溃取证 / 一键诊断包的取舍，四类故障如何分开收，脱敏判据 |
| `docs/1011_03_1.0-roadmap.md` | **到 1.0.0 的路线图**：把全仓的「未实现 / 未验证 / 未定论」归类成验收 / 发布工程 / 功能缺口 / 已决策不做四类，含**人工验收清单**（§8）与 ticket 队列（§6） |
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

- **必须随包附 `NOTICE.txt`** —— **已经做到**（2026-10-11）：`build.sh` 在 `xcodegen generate`
  之前把它从 `vendor/platform-tools/NOTICE.txt` 暂存到 `macos/Resources/`，`project.yml` 把它列为
  bundle 资源 ⇒ 落在 `DroidBerth.app/Contents/Resources/NOTICE.txt`；`release.yml` 还会**再挂一份**
  到 Release 页（免得要先下 40 MB 的 DMG 才看得到许可）。
  源文件在 `vendor/`（`.gitignore` 排除，不随仓库分发），新克隆的机器由 `./scripts/fetch-adb.sh` 取回。
- `NOTICE.txt` 声明整包 Apache-2.0；SDK 条款的**再分发禁令是 §3.4**，而 **§3.5 对开源许可组件有豁免**。
- 所以「必须自建才能公开分发」这个前提不成立。
- **但这仍不是法律意见。** 公开发布前必须让法务确认 §3.5 的适用性。**不要把它当成「无风险」。**
- 自建 adb 列为「若法务否决则切换」的备选，且必须按 **build-glue 项目** 立项，不是脚本。

### 其它约束

- sidecar 定位用**相对自身可执行文件**的路径，不用安装路径拼接。
- 子进程封装必须**同时抽干 stdout 和 stderr**，并带超时。
- 禁止手写 `hdiutil create`，统一走 `scripts/env.sh` 的 `make_signed_dmg()`。
  它用 `ditto`（不是 `cp -R` —— 后者不保留扩展属性，实测那样拷出来的副本 `spctl` 会判
  `rejected / Insufficient Context`），并往 DMG 里放一条 `/Applications` 符号链接。
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
