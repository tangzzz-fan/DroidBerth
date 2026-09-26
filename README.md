# DroidBerth

**插上线，把 Mac 上的视频和照片推到手机，像用 Finder 一样浏览两端。**

DroidBerth 是一款 macOS 应用，在 Mac 与 Android 手机之间双向传输文件，**以「Mac → Android」为主场景优化**。
ADB 二进制内嵌在 app 内 —— 用户不需要装 Android SDK、不需要碰终端、不需要理解 ADB。

主用户是**摄影师 / 视频创作者**：手上有大量已在 Mac 上整理好的素材，需要推到 Android 手机上用于看片、给客户看、装到平板或备用机上播放。这决定了默认交互是「推」而不是「拉」，且单次传输量大（几十到几百个文件，单个可能上 GB）。

> **它不是**设备管理器，不是开发者工具，不是备份工具。范围刻意收窄。

---

## 当前状态

**这是一个处于风险验证 + MVP 阶段的仓库，不是可发布的产品。** 请按下面的「验证状态」理解它的成熟度。

| 层 | 状态 |
|---|---|
| 产品定义 | 完成（`docs/0926_01_PRD.md`） |
| 技术路线验证 | **完成，判 Go**（`docs/0926_02_swift-native-spike-plan.md`） |
| Swift 原生外壳 MVP | **已实现，核心链路真机验证通过**（`docs/0926_03_swift-native-mvp-implementation.md`） |
| 视觉与交互验收 | **未做** |
| 公证与分发 | **未做** |

仓库里存在**两条技术路线**的代码，这是历史原因，不是并列关系：

- **`macos/`（Swift 原生，当前路线）** —— SwiftUI + 复用已验证的 Rust sidecar。已判 Go，MVP 在此推进。
- **`src-tauri/` + `src/`（Tauri v2，前序路线）** —— 用于回答「Tauri + ADB sidecar 的 macOS 分发风险」这一批问题。验证结论已沉淀进 `docs/`，代码保留作对照，**不再是开发主线**。

---

## 仓库结构

```
macos/                    Swift 原生外壳（当前路线）
  project.yml               xcodegen 工程定义
  Sources/DroidBerth/       37 个 Swift 文件 / 4787 行
  Resources/                Info.plist（含 NSServices 声明）+ entitlements
  Scripts/build-sidecar.sh  编译 Rust sidecar 并暂存
sidecar/droidberth-adb/   Rust sidecar（1787 行 / 5 文件）
                          version / doctor / resolve / exec / raw 五个子命令
src-tauri/ + src/         Tauri 路线（前序，保留作对照）
scripts/                  两条路线共用的构建、签名、公证脚本
vendor/                   adb 源码与 platform-tools（见「依赖与许可」）
docs/                     产品文档、验证方案、实现文档、风险报告
reports/                  doctor 报告输出
```

### sidecar 在架构里的位置

sidecar **不是所有 adb 调用的代理**，它承担的是**定位器 + 诊断器**：

```
SidecarLocator.locate()          相对 Bundle.main.executableURL 的同级目录找 droidberth-adb
  └─ SidecarClient.resolve()     让 Rust 侧决定 adb 在哪（沿用已验证的 adb::resolve）
       └─ 得到真实 adb 路径 → 之后所有设备操作直接调 adb
```

`doctor` 的 14 项检查是上一轮验证过的判据设计，复用它们等于免费继承一套诊断能力；
而每次 `shell` 都绕一层 sidecar 只会多一次进程启动开销，没有收益。

---

## 构建与运行

### 前置条件

- macOS 14+，Apple Silicon
- Xcode（含命令行工具）
- [xcodegen](https://github.com/yonaskolb/XcodeGen) 2.46.0
- Rust 工具链（由 `scripts/env.sh` 注入 `RUSTUP_HOME` / `CARGO_HOME`）
- Developer ID 证书（仅签名相关步骤需要）

### 步骤

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

### 快捷键

| 快捷键 | 动作 |
|---|---|
| `⇧⌘U` | 上传选中项到设备 |
| `⇧⌘S` | 下载选中项到 Mac |
| `⇧⌘N` | 在设备端新建文件夹 |

### Finder 集成（服务菜单）

在 Finder 中选中文件或文件夹 → 右键 → **服务** → **发送到 DroidBerth**，即可直接推送到设备。
App 未运行时会由系统自动拉起，并等待设备就绪后再开始传输（最长 20 秒）。

落点规则与 App 内一致：优先「上次使用的目录」，否则按文件类型分流
（图片 → `/sdcard/DCIM`，视频 → `/sdcard/Movies`，其它 → `/sdcard/Download`）。

> **必须把 App 放在 `/Applications`**（或其子目录）。Apple 对服务的要求是：
> *"To build an application that offers a service, use the extension `.app` and install it in the
> `Applications` folder (or a subfolder)."* 放在构建目录里不会被系统登记。
>
> 安装后若服务没出现，执行一次 `/System/Library/CoreServices/pbs -update` 触发重扫
> （`pbs` 在 macOS 27 上的参数已变，**不是**老文档里的 `-dump_pboard`）。
> 仍不出现时可注销重新登录 —— 服务列表在登录时构建。

自检服务是否被系统登记：

```bash
/System/Library/CoreServices/pbs -dump | grep -A8 -i droidberth
```

应能看到 `NSBundlePath = "/Applications/DroidBerth.app"`、`NSMessage = sendToDevice` 等条目。

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
- **Finder 服务**（`NSServices`）：`/System/Library/CoreServices/pbs -dump` 确认已登记；程序化调用 `NSPerformService`
  验证两条路径均通过 —— App 已在运行、以及 **App 未运行时由服务拉起**（含等待设备就绪），
  设备端落点与 SHA-256 均一致

### 未验证

| 项 | 原因 |
|---|---|
| 视觉与交互验收（双击、拖拽、布局） | 开发环境无法截图 / 无法模拟点击，**需要人工操作** |
| 照片图库作为素材来源 | 需要人工在授权弹窗点「允许」 |
| App Translocation | 需要先有一个**已公证**的产物才能构造该场景 |
| 分栏视图 / 拖出到 Finder / Quick Look | 未做 |
| Finder 服务「无设备」分支的提示文案 | 需断开设备才能构造，且提示只能肉眼确认 |
| Finder 服务在**真实 Finder 菜单**里的出现 | 只能人工右键确认（登记与派发已程序化验证） |
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
| `docs/0926_01_PRD.md` | 产品需求与产品设计（产品定位、功能需求、信息架构、设计原则） |
| `docs/0926_02_swift-native-spike-plan.md` | 换栈 Go/No-Go 验证方案与执行记录（V1–V4） |
| `docs/0926_03_swift-native-mvp-implementation.md` | **MVP 实现文档**：架构、三个已修缺陷、验证边界、未验证项 |
| `docs/risk-validation-report.md` | Tauri 路线的 macOS 分发风险验证 |
| `docs/reusable-solutions-and-pitfalls.md` | 可复用方案与避坑清单 |
| `docs/article-embedding-adb-in-macos-app.md` | 在 macOS app 内嵌 ADB 的实践记录 |

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
- 不要把 `src-tauri/binaries/adb-*` 打进产品包（体积与许可双重理由）。

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
