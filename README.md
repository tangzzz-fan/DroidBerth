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
| 视觉与交互 | **部分**：视觉基调已定（系统控件 + 原生材质）；**Phase 1–4 已完成**（聚焦态描边 / Tab 循环 / 四向拖拽 / ⌘C⌘V 跨栏 / ⌘X 剪切 / 空格 Quick Look / 列头排序 / 搜索 / 失败重试 / 位置弹窗 + 最近使用 / 三种视图齐全 / 缩略图 / ⌘± 图标尺寸 / View + Device 菜单 / 设备端重命名与移动 / Reduce Motion），**运行时行为待人工验收**。仍缺无障碍（VoiceOver 按要求跳过，动态字体与对比度只做到部分）、预览窗格、照片图库缩略图，方案见 `docs/1009_01_uiux-revamp-plan.md` |
| 公证与分发 | **未做**（架构范围已决策：**arm64-only**，放弃 Intel，见 PRD §5.1） |

---

## 仓库结构

```
macos/                    Swift 原生外壳（唯一应用工程）
  project.yml               xcodegen 工程定义
  Sources/DroidBerth/       42 个 Swift 文件 / 7598 行
  Resources/                Info.plist + entitlements
  Scripts/build-sidecar.sh  编译 Rust sidecar 并暂存到 macos/Sidecar/
sidecar/droidberth-adb/   Rust sidecar（1788 行 / 5 文件，零第三方依赖）
                          version / doctor / resolve / exec / raw 五个子命令
scripts/                  构建、签名、公证脚本（Swift 路线）
vendor/                   adb 源码与 platform-tools（见「依赖与许可」）
docs/                     产品文档、验证方案、实现文档、UI/UX 改造方案
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

它会依次：暂存 sidecar → `xcodegen generate` → `xcodebuild`。
产物：`macos/build/dd/Build/Products/Release/DroidBerth.app`。

### 分步（等价，便于调试）

```bash
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
| `Space` | Quick Look 就地预览（远端文件先拉到 `$TMPDIR/DroidBerth/preview/`） |
| `⌘F` | 聚焦搜索框（筛选作用于聚焦窗格，作用域在编辑查询时锁定） |
| `⇧⌘X` | 交换左右窗格 |
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
> **未实现**：`⇧⌘P`（预览窗格）。

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

### 验证面板

把技术验证的判据逐条重跑（不依赖 UI）：

```bash
build/dd/Build/Products/Release/DroidBerth.app/Contents/MacOS/DroidBerth --spike-report
# 结果写入 ~/DroidBerth-reports/spike-<timestamp>.json
```

### 产物路径注意

仓库会同时存在 `macos/build/Release/` 与 `macos/build/dd/Build/Products/Release/` 两个产物目录。
**验证 UI 改动前先核对进程启动时间是否晚于源码 mtime**，否则会看着旧二进制下结论 —— 这个坑真实踩到过。

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

### 未验证

| 项 | 原因 |
|---|---|
| 视觉与交互验收（双击、拖拽、布局、Quick Look、跨栏粘贴、排序、搜索、网格选择、分栏铺列、菜单、重命名、移动） | 开发环境无法截图 / 无法模拟点击，**需要人工操作**。双击 / 右键打开已人工确认可用；**Phase 1–4 新增的交互仍未验收** |
| **网格缩略图的远端成品率** | 只拉 64 KB 文件头再交给 `QLThumbnailGenerator`。**截断数据能否解码没有真机验证**：JPEG 通常可解出部分图像，HEIC / `moov` 在文件尾的 MP4 很可能解不出 ⇒ 回退类型图标。「一律拉完整文件」已被 PRD §23 明确拒绝 |
| 分栏视图的运行时行为 | `NSBrowser` 的铺列、异步补行、单选、双击预览、底部路径栏均未运行过；**行内类型图标**还多一层不确定 —— `willDisplayCell` 在 item-based 浏览器里是否被调用，Apple 文档没有明确承诺（不调用则退化为纯文本行，功能不受影响） |
| 网格「点空白处取消选择」与「单击选中」的延迟手感 | 单击与双击手势共存时 SwiftUI 会让单击等一个双击间隔；是否能接受需运行时确认 |
| 照片图库作为素材来源 | 需要人工在授权弹窗点「允许」 |
| App Translocation | 需要先有一个**已公证**的产物才能构造该场景 |
| 设备窗格 → Finder 拖出 | **未实现**（需 `NSFilePromiseProvider`），见 `docs/1009_01_uiux-revamp-plan.md` §2.6 |
| 设备端重命名 / 移动 | **已实现**（Phase 4），但运行时未验证：`mv` 的成功/失败提示、冲突整批拒绝的判定、⌘X→⌘V 的移动链路都没在真机上跑过 |
| **设备端文件名的合法字符集** | 未实测。当前校验只挡住必然非法的（空 / `.` / `..` / 含 `/` / 超 255 字符）。FAT32 的 `: * ? " < > \|` 与 MediaStore 的索引限制都要等真机才能定规则（PRD §16） |
| 无障碍 | **VoiceOver 未做**（用户 2026-10-10 要求跳过，每行仍无 accessibility label）；Reduce Motion 已实现但未验证；**对比度未用工具测量**，动态字体只做到「不给文字定宽」，都没在放大字号下逐屏核对 |
| 菜单栏的「显示预览窗格」「排序方式」「连接设备…」 | **未实现**：前两者分别依赖预览窗格与菜单化排序，后者需要输入 IP / 配对的向导。**刻意不摆灰项** |
| 照片图库网格的缩略图 | **未实现**：图库条目的 `path` 是 `localIdentifier`，缩略图要走 PhotoKit 的 `PHImageManager`；当前照片网格退类型图标，分栏回退成列表 |
| 工具栏搜索框的 `⌘F` 焦点行为 | `@FocusState` 在 `ToolbarItem` 里的行为**需运行时确认**；失败时降级为「点一下即可输入」，功能不受影响 |
| 性能基线（相对裸 `adb push` 的开销） | 未测量 |
| 干净 VM 上的安装验证 | 需要另一台机器 |

### 已知未修缺陷

**`MediaScanner.isIndexed` 的判据偏宽。** 它查的是 `content://media/external/file` ——
MediaStore 的 **file 表，涵盖所有文件类型**。结果是上传 `.txt` 也会显示「已进入相册索引」，
但相册 app 里看不到它。修法方向：按扩展名分流到 `images/media` / `video/media` / `audio/media`，
非媒体文件不报这句。详见实现文档 §6。

---

## 文档索引

| 文档 | 内容 |
|---|---|
| `docs/0926_01_PRD.md` | 产品需求与产品设计（产品定位、功能需求、信息架构、设计原则）。**当前 v2.1** |
| `docs/0926_02_swift-native-spike-plan.md` | 换栈 Go/No-Go 验证方案与执行记录（V1–V4） |
| `docs/0926_03_swift-native-mvp-implementation.md` | **MVP 实现文档**：架构、三个已修缺陷、验证边界、未验证项 |
| `docs/1009_01_uiux-revamp-plan.md` | **UI/UX 分阶段改造方案**：交互层差距矩阵、Phase 0–4 任务分解与验收点 |
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
