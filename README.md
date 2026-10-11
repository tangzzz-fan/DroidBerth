# DroidBerth

**插上线，把 Mac 上的视频和照片推到手机，像用 Finder 一样浏览两端。**

DroidBerth 是一款 macOS 应用，在 Mac 与 Android 手机之间双向传输文件，**以「Mac → Android」为主场景优化**。
ADB 二进制内嵌在 app 内 —— 用户不需要装 Android SDK、不需要碰终端、不需要理解 ADB。

主用户是**摄影师 / 视频创作者**：手上有大量已在 Mac 上整理好的素材，需要推到 Android 手机上用于看片、
给客户看、装到平板或备用机上播放。这决定了默认交互是「推」而不是「拉」，且单次传输量大。

> **它不是**设备管理器，不是开发者工具，不是备份工具。范围刻意收窄。

**技术路线：Swift 原生（SwiftUI + AppKit），复用 Rust sidecar。** 全仓库单一实现路线，
`macos/` 是唯一的应用工程，`sidecar/` 是唯一的 ADB 定位 / 诊断组件。

> **关键词 / Keywords**：macOS ↔ Android 文件传输 · Mac 传视频 / 照片到手机 · ADB 图形界面（GUI）·
> Android File Transfer 替代 — macOS ⇄ Android file transfer · adb GUI · Android File Transfer alternative

---

## 与相邻方案的差别

| 方案 | 差别 |
|---|---|
| **Android File Transfer**（Google 官方） | 走 **MTP** 栈；本项目走 **ADB**。技术栈与适用场景不同，**未做逐项横向实测**，因此不比较快慢 |
| 命令行 `adb push` / `adb pull` | 能力等价。差别在于本项目把这一层包成双栏界面，并把 `adb` **内嵌进 app** |
| 通用 MTP 客户端 / 设备管理器 | 与 ADB 是两条不同的栈，**本项目未评估**；「设备管理」明确不在范围内 |

> 本项目**不**处理 MTP，**不**做备份，**不**做设备管理。范围与理由见 `docs/0926_01_PRD.md` §1–§3。

---

## 当前状态

**MVP 阶段，尚未正式发版。** 功能层面已完整（三种视图、四向拖拽、跨栏传输、Quick Look、预览窗格、
设备端写操作、可观测性），**缺的是验收与发布工程** —— 完整清单见
[`docs/1011_03_1.0-roadmap.md`](docs/1011_03_1.0-roadmap.md)。

| 层 | 状态 |
|---|---|
| 产品定义 | 完成（`docs/0926_01_PRD.md`，**v2.1**） |
| 技术路线验证 | **完成，判 Go**（`docs/0926_02_swift-native-spike-plan.md`） |
| Swift 原生外壳 | **已实现，核心链路真机验证通过**（上传 / 下载 / 进度 / 相册入库）。交互层与视觉层 2026-10-11 补齐 |
| 公证与分发 | **链已跑通**：`build.sh` → `notarize.sh`（app 与 DMG 双双 `Accepted`）→ `checklist.sh`；发版走**本机一条命令**，签名凭据不离开本机。架构范围 **arm64-only**（PRD §5.1） |

---

## 下载与安装

发布页：**<https://github.com/tangzzz-fan/DroidBerth/releases>**

| 文件 | 说明 |
|---|---|
| **`DroidBerth-<版本>.dmg`** | **推荐**。已签名 + 已公证 + 已 staple，内含 `/Applications` 软链 |
| `DroidBerth-<版本>.zip` | 同一份 app 的压缩包；习惯直接拖 app 的人用这个 |
| `NOTICE.txt` | `adb`（Android platform-tools）的 Apache-2.0 声明。它也在 app 包内 |
| `SHA256SUMS.txt` | 上面各文件的 SHA-256（裸文件名，可直接 `-c`） |
| Source code (zip / tar.gz) | GitHub 为每个 Release 自动附带的**源码快照** |

**需要 Apple Silicon（M 系列）与 macOS 14 或更高。** 本项目不发 Intel 版本（PRD §5.1）。
安装：打开 DMG，把 **DroidBerth** 拖到旁边的 **Applications**。包已公证，**不需要**绕过 Gatekeeper。

```bash
shasum -a 256 -c SHA256SUMS.txt    # 校验下载
```

---

## 快捷键

| 快捷键 | 动作 |
|---|---|
| `⇧⌘U` / `⇧⌘S` | 上传选中项到设备 / 下载选中项到 Mac |
| `⇧⌘N` | 在设备端新建文件夹 |
| `⌘C` / `⌘V` | **跨栏传输**：Mac 栏选中 → 设备栏粘贴 = 上传；反向 = 下载（焦点在输入框时恢复文本语义） |
| `⌘X` | **设备端剪切**：切到目标目录后 `⌘V` = 移动（Mac 端的移动交给 Finder） |
| `Space` | Quick Look 就地预览，**再按一次收起**（面板内方向键切换条目） |
| `⏎` | **重命名**设备端选中项（恰好单选；列表 / 网格视图） |
| `←` `→` `↑` `↓` | **网格视图**移动选择（左右线性：列首再按 `←` 回到上一行末尾） |
| `⇧` + 方向键 | 网格视图扩展选择 |
| 字母 / 数字键 | 网格视图跳转到以它开头的项目（连敲同一字母轮转；停手 0.8 秒重新开始） |
| `⌘F` | 聚焦搜索框（筛选作用于聚焦窗格，作用域在编辑查询时锁定） |
| `⇧⌘X` / `⇧⌘P` | 交换左右窗格 / 显示预览窗格 |
| `⌘1` / `⌘2` / `⌘3` | 聚焦窗格切到列表 / 分栏 / 网格视图 |
| `⌘+` / `⌘-` | 放大 / 缩小网格图标（72–240 pt） |
| `⇧⌘.` | 显示 / 隐藏隐藏文件（**两侧同时生效**） |
| `Tab` / `⇧Tab` | 在左右窗格之间循环聚焦 |
| `⌘⌥←` / `⌘⌥→` | 聚焦**屏幕上的**左 / 右窗格（⇄ 交换后仍按视觉位置走） |
| `⌘[` / `⌘]` / `⌘↑` / `⌘R` | 后退 / 前进 / 上一层文件夹 / 刷新 |
| `⌘⌫` | 删除设备端选中项（不可撤销） |
| `⌘,` | 打开设置 |

> `Space`、`Tab`、`⏎` 与网格视图的方向键 / 字母键由**本地事件监听**（`Support/PaneKeyMonitor.swift`）接管，
> 带「正在编辑文本」守卫；**只在聚焦窗格确实是网格、或确实有可重命名的单选时才拦**，否则交还系统 ——
> 列表与分栏的原生方向键与 type-select 因此没有被抢走。
> **菜单里刻意不给它们挂快捷键**：无修饰键的菜单快捷键会先于文本框拿到事件。

---

## 仓库结构

```
macos/                    Swift 原生外壳（唯一应用工程）
  Sources/DroidBerth/       60 个 Swift 文件
  Resources/                Info.plist + entitlements + icon.icns（入库的源文件）
                            + NOTICE.txt（构建期从 vendor/ 暂存，不入库）
sidecar/droidberth-adb/   Rust sidecar（1788 行 / 5 文件，零第三方依赖）
scripts/                  构建、签名、公证、发布脚本（逐脚本说明见工程笔记）
  build.sh                  唯一构建入口    release-local.sh  本机发版
  check-all.sh              回归守卫        check-release.sh  发布前闸门
  fetch-adb.sh              取 platform-tools
vendor/                   adb 源码与 platform-tools（**刻意不入库**）
docs/                     产品文档、验收报告、路线图、工程笔记
  design/                   设计令牌（DESIGN.md，唯一来源）+ open-design 稿快照
reports/                  doctor / spike 的运行期输出（不入库）
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

macOS 14+ / Apple Silicon · Xcode（含命令行工具）· [xcodegen](https://github.com/yonaskolb/XcodeGen) 2.46.0 ·
Rust 工具链（`scripts/env.sh` 会注入 `RUSTUP_HOME` / `CARGO_HOME`）· Developer ID 证书（仅签名 / 公证需要）。

### 新克隆的仓库：先取一次 adb

```bash
./scripts/fetch-adb.sh
```

`vendor/` 被 `.gitignore` **刻意**排除，所以新克隆里没有 adb，而构建需要它。脚本从 Google 官方源取
**platform-tools r37.0.1** 并校验两道 sha256（钉死版本的理由见工程笔记 §1.2）。

### 一键构建

```bash
./scripts/build.sh
```

依次：**生成 App 图标 + 暂存 NOTICE** → 暂存 sidecar → `xcodegen generate` → `xcodebuild`。
产物：`macos/build/dd/Build/Products/Release/DroidBerth.app`。

### 更多

分步构建、在 Xcode 里调试（attach 被拒的两个开关）、Dock 图标不换、编译验证与四个回归守卫的跑法、
签名与公证的三条坑 —— 全部在 **[`docs/1011_05_engineering-notes.md`](docs/1011_05_engineering-notes.md)**。

---

## 发行与发布

### 怎么发一个版本（本机，唯一正路）

```bash
./scripts/release-local.sh 0.1.0             # 干跑：构建 → 守卫 → 公证 → 打包，不碰 GitHub
./scripts/release-local.sh 1.0.0 --publish   # 真发版：打 tag、推 tag、建 Release（会二次确认）
```

一条命令跑完 **构建 → `check-all` → 公证（app + DMG）→ 验证票据与 Gatekeeper → 打包 → 建 Release**。
版本号通过 `XCODEBUILD_ARGS` 注入（`Info.plist` 用 `$(MARKETING_VERSION)`），
所以 app 里显示的版本与 Release 上的 tag 一定一致。

**第 6 步是发布前闸门** `scripts/check-release.sh` —— PRD §28 那份「发布前检查清单」的可执行版本：
签名 / 公证 / 票据 / 架构 / 图标十档 / `NOTICE.txt` / 版权字段 / 版本号 / dist 里的校验和与 zip 垃圾项 /
`LICENSE` / `CHANGELOG`，机器能判的全部判一遍。**FAIL 就打住**（退出码 1），
而法务、真机验收这类只能人判的单独列成「人工项」，不混在 PASS 里。也可以单独跑：

```bash
./scripts/check-release.sh 1.0.0
```

| Release 附件 | 来源 |
|---|---|
| `DroidBerth-<版本>.dmg` | 已签名 + 已公证 + 已 staple，含 `/Applications` 软链 |
| `DroidBerth-<版本>.zip` | 同一份 app（`zip -X -y`，无 `._` 垃圾项） |
| `NOTICE.txt` | `adb` 的 Apache-2.0 声明（也在 app 包内，PRD §28） |
| `SHA256SUMS.txt` | 校验和（**裸文件名**，下载后可直接 `-c`） |
| Source code (zip / tar.gz) | **GitHub 自动附带** |

> **为什么签名不走 CI。** Developer ID 私钥一旦放进 GitHub，就是一份**你无法收回的副本** ——
> 而它能做的不是「读你的数据」，而是**以你的名义签发任何 macOS 都信任的软件**。
> 这个仓库是 public 的：能推 workflow 的人就能把它打出来，而 **Actions 日志是公开的**
> （secret 掩码只在原样出现时生效，`base64` 一下就绕过）。本机本来就有全套凭据。
> **所以签名与公证的凭据一步都不离开这台机器。**

### CI 做什么

| 文件 | 触发 | 干什么 |
|---|---|---|
| `.github/workflows/ci.yml` | push 到 `main`、每个 PR、手动 | 装工具链 → **取 adb** → 构建（ad-hoc 签名）→ `scripts/check-all.sh` → 断言自检 V1/V3 |
| `.github/workflows/release.yml` | **仅手动**（`workflow_dispatch`） | 装证书 → 构建 → 守卫 → 公证 → 校验 → 建 Release。**默认不用**，见工程笔记 §6 |

CI 的判据是「能不能编出可运行的产物 + 四道回归守卫过不过」。**它已经抓到过 4 处
「本地编译过、CI 编译器（Xcode 16.4）编译不过」的问题** —— 那是它最值钱的地方，与签名无关。

**闸门**：`scripts/check-all.sh` —— 四道回归守卫（图标映射 / 网格导航 / 传输语义 / 诊断包）
+ 一道 shell 静态检查（`$VAR` 后面跟全角标点这个 bash 3.2 陷阱）。
本项目**没有测试 target**，这是那类「静默错」唯一的自动化防线，所以 CI 必须跑。
自检只断言 **V1** 与 **V3**（V2 在 ad-hoc 下必然 fail、V4 需要真机 —— 两项都是预期，不是缺陷）。

---

## 验证状态

沿用文档的约定，「已实测」与「未验证」严格分开。**完整清单见
[`docs/1011_03_1.0-roadmap.md`](docs/1011_03_1.0-roadmap.md) §2。**

### 已实测

- **真机（HUAWEI DVC-AN20，Android 10）**：sidecar 定位与执行、`doctor` 14 项、签名链（三个 Mach-O
  全部 `flags=0x10000(runtime)`）、进程封装（stdout/stderr 各 20000 行不卡死、超时精确）、
  上传（多文件 + 递归 + 重名 ` (1)` + SHA-256 回验）、下载、进度上报、图片上传 + MediaStore 入库
- **Android 模拟器（`Pixel_10`，API 37.2 / 16 KB 页）**：端到端 `V4` pass、内嵌 adb 与 SDK 的 adb
  **逐字节相同**、媒体自动入库；另跑一轮量出两条真缺陷（上传静默覆盖、远端缩略图 3/8 成品率）并已修
- **GitHub Actions**：`ci.yml` 实跑全绿

### 已知限制（不是缺陷，是没做或做不到）

| 项 | 说明 |
|---|---|
| **交互层未人工验收** | 本机无法截图、无法模拟点击 ⇒ 三种视图、拖拽、Quick Look、预览窗格、网格键盘导航、`⏎` 重命名等的**运行时手感全部未验**。清单见路线图 §8 |
| **支持范围 Android 10–16，实测只覆盖 10** | 「10–16」是**目标**范围。已验的只有 Android 10；11–16 未验证但未发现不兼容；API 37 模拟器**落在目标范围之外**。**1.0.0 按现状发布，范围在 README / PRD §5 / 发行说明三处如实写明** |
| VoiceOver | **用户明确要求跳过**，每行仍无 accessibility label |
| 对比度 / 动态字体 | 只做到「部分」：承载数据的几处已达标 AA，其余未逐屏核对 |
| 设备端存储卷（SD 卡） | 卷枚举 / 跳转 / 面包屑 / 拔卡回落**只做到编译通过**（本机没有可移除卷） |
| Finder 服务「App 未运行时被拉起」 | **未定论**（3 次只 1 次真拉起）；App 运行时的送达与解析已实测通过 |
| 干净 VM 安装 / App Translocation / 性能基线 | 均未做 |
| 明确不做 | 本地文件的删除 / 移动（交给 Finder）、设备端回收站、常驻侧边栏、分片续传。理由见路线图 §5 |

---

## 排障与诊断

用户报「传不动 / 打不开 / 刚才闪退了」时，**手上必须要有现场**。

**用户侧：一次点击。** 帮助 → **导出诊断报告…** → 桌面生成 `DroidBerth-diagnostics-<时间>.zip`
（自动在访达里选中），把它发回来即可。包里 9 类内容：环境 / 会话哨兵 / 崩溃报告 / 未捕获异常 /
日志 / 自检报告 / sidecar-doctor / adb 现场 / 设备列表。
**没有自动上传**，包只生成在用户机器上；所有文本**写入前就脱敏**。

**开发者侧：一条命令。**

```bash
APP=build/dd/Build/Products/Release/DroidBerth.app/Contents/MacOS/DroidBerth
$APP --diagnose                      # 摘要：环境 / 上次是否异常结束 / 崩溃报告 / adb / 日志尾部
$APP --export-diagnostics[=<目录>]   # 生成 zip，打印路径
```

方案与取舍见 [`docs/1011_02_observability-report.md`](docs/1011_02_observability-report.md)；
四类故障（app 崩溃 / ObjC 异常 / 异常退出无信号 / 子进程）各自怎么收、日志在哪 —— 工程笔记 §9。

---

## 文档索引

| 文档 | 内容 |
|---|---|
| `docs/0926_01_PRD.md` | 产品需求与产品设计。**当前 v2.1** |
| `docs/0926_02_swift-native-spike-plan.md` | 换栈 Go/No-Go 验证方案与执行记录（V1–V4） |
| `docs/0926_03_swift-native-mvp-implementation.md` | MVP 实现文档：架构、三个已修缺陷、验证边界 |
| `docs/1009_01_uiux-revamp-plan.md` | UI/UX 分阶段改造方案：差距矩阵、Phase 0–4 与验收点 |
| `docs/1010_01_ui-icon-design-report.md` | 视觉层与图标层：三条 P0 缺口、设计方案与执行记录 |
| `docs/design/1011_01-design-compliance.md` | 设计稿符合性审计（78 条：一致 53 / 偏离 16 / 未实现 9） |
| `docs/1011_01_device-acceptance-report.md` | 设备端验收报告（API 37 模拟器）：缩略图成品率、卷大小写语义、文件名字符集 |
| `docs/1011_02_observability-report.md` | 可观测性方案：日志 / 崩溃取证 / 诊断包，四类故障怎么分开收 |
| **`docs/1011_03_1.0-roadmap.md`** | **到 1.0.0 的路线图**：验收 / 发布工程 / 功能缺口 / 已决策不做 + 人工验收清单 |
| **`docs/1011_04_appstore-plan.md`** | **上架 Mac App Store 需要准备什么**：官方硬约束、沙盒化改造清单、材料分工、可行性 spike |
| **`docs/1011_05_engineering-notes.md`** | **工程笔记**：构建 / 调试 / 图标缓存 / 回归守卫 / 签名公证 / CI 凭据 / 「别做」清单 |
| `docs/device-acceptance/2026-10-11/` | 设备端验收的原始日志与可重跑脚本 |
| `docs/design/DESIGN.md` | 设计常量唯一来源（色 / 尺寸 / 图标判据 / 几何契约 / 已否决清单） |

---

## 依赖与许可

### adb 的来源

本仓库**不自建 adb**。上游只有 Soong 构建路径（全树 `Android.bp` 15 个），
`scripts/build-adb.sh` 自己的结论是：*"A self-built adb is a **build-glue project, not a script**."*
当前使用 **SDK 的 `adb`**，其依赖全部是系统库（`otool -L` 非系统路径依赖 0 个），不构成公证障碍。

### 许可 —— 公开发布前必须确认

- **必须随包附 `NOTICE.txt`** —— **已经做到**（`build.sh` 在 `xcodegen` 之前从 `vendor/` 暂存到
  `macos/Resources/`，Release 页还会再挂一份）。
- `NOTICE.txt` 声明整包 Apache-2.0；SDK 条款的**再分发禁令是 §3.4**，而 **§3.5 对开源许可组件有豁免**
  ⇒ 「必须自建才能公开分发」这个前提不成立。
- **但这仍不是法律意见。** 公开发布前必须让法务确认 §3.5 的适用性。**不要把它当成「无风险」。**
- 自建 adb 列为「若法务否决则切换」的备选，且必须按 **build-glue 项目** 立项，不是脚本。

### 其它约束

sidecar 定位用**相对自身可执行文件**的路径；子进程封装必须**同时抽干 stdout 和 stderr** 并带超时；
adb 只暂存到 `macos/Sidecar/`（已 gitignore），**不提交、不随仓库分发**。

---

## 参与开发

改 `macos/Sources/` 后重新构建即可（纯 SwiftUI，无前端构建链）；改 sidecar 后要重跑
`./macos/Scripts/build-sidecar.sh`。**改完必须重新构建 app** —— 验证探针跑的是源码，
运行中的二进制不会自己更新。**改完跑一次 `./scripts/check-all.sh`**（CI 会跑，本地不会）。

提交前建议核对签名三项判据：

```bash
for f in DroidBerth droidberth-adb adb; do
  codesign -dvvv "macos/build/dd/Build/Products/Release/DroidBerth.app/Contents/MacOS/$f" 2>&1 \
    | grep -E '^(Identifier|TeamIdentifier|Timestamp|CodeDirectory)'
done
```

---

## 许可

本仓库自己的代码与资源用 **MIT**（见 [`LICENSE`](LICENSE)）。
随包分发的 `adb`（Android platform-tools）是 Google 的独立作品、按 **Apache-2.0** 授权，
声明随包附在 `NOTICE.txt` —— **两者互不影响**。

> ⚠️ 公开分发前仍需法务确认 `NOTICE.txt` §3.5 的适用性（见上方「依赖与许可」）。**这不是法律意见。**
