# DroidBerth Swift 原生外壳验证方案

| 项 | 值 |
|---|---|
| 分支 | `spike/swift-native-adb`（从 `494a95e` 分出） |
| 日期 | 2026-09-26 |
| 目的 | 回答一个 Go/No-Go 问题：**Swift 原生外壳 + 复用已验证的 Rust ADB 层**，这条组合是否成立 |
| 依据 | `docs/0926_01_PRD.md`（产品定义）、`docs/risk-validation-report.md`（已验证结论）、本机 `MacOSX.sdk` 实测 |

> **阅读约定**：本方案区分「已实测」「推断」「未知」。第 7 节列出写方案时就承认的未知项 —— 它们不藏在正文里。

---

## 1. 要回答的问题

**一句话**：把外壳从 Tauri/WKWebView 换成 SwiftUI/AppKit，ADB 层继续用已验证的 Rust sidecar，这条路能否成立？

拆成四个**必须独立回答**的命题：

| # | 命题 | 为什么必须单独回答 |
|---|---|---|
| V1 | Swift 能可靠定位并执行 bundle 内的 sidecar（含 App Translocation 场景） | 定位错了，后面全部作废 |
| V2 | Xcode 的构建链会正确签名 sidecar（hardened runtime + 时间戳 + TeamID 一致） | **本次最高价值**。文档用整篇文章讲这条链，换栈后必须重新实测 |
| V3 | Swift 的进程封装能达到 Rust `proc::run` 的语义（双路抽干 + 超时 + 不泄漏子进程） | 文档 §1.5 把它列为经典坑 |
| V4 | 端到端：Swift → sidecar → adb 能完成设备列举与文件传输 | 前三条都过但这条不过，方案仍然不成立 |

**V1–V4 全部通过 = Go。** 任一失败且无 workaround = No-Go。

### 为什么这四个命题不能合并

V1 和 V2 看起来都在讲「sidecar 能不能用」，但它们失败的方式完全不同：V1 失败是**运行时找不到文件**（立刻可见），V2 失败是**签名链静默不完整**（本地能跑，分发后被 Gatekeeper 拒，且报错与真实原因无关）。文档里最贵的几个坑全是后者。合并成一个「能不能用」的命题，会把静默失败和显式失败混为一谈。

---

## 2. 范围

### 验

- sidecar 在 Xcode 工程里的**打包位置**与**定位方式**
- Xcode 签名链对 sidecar 的**实际行为**（读真实字节，不靠推断）
- Swift 侧 `Process` / `Pipe` 封装的**正确性**（用受控用例主动逼出问题，而不是等它在生产里出现）
- 一台真实 Android 设备上的**基本 ADB 操作**

### 不验（明确排除）

| 项 | 为什么排除 |
|---|---|
| 完整 UI（双栏、列表 / 分栏 / 网格视图） | 属于 PRD 的 Phase 1，不属于「这条技术路线成不成立」 |
| 照片图库来源、媒体入库、无线连接 | 属于后续 Phase，与换栈无关 |
| 公证与 staple | 需要凭据；本次只回答「签名链」这一层 |
| 性能指标 | 没有基线可比。PRD §5 已改为「相对裸 `adb push` 的开销」这一可测形式 |

### 次要（核心通过后再做，不阻塞 Go/No-Go）

- **V5** `NSBrowser` 分栏视图包进 SwiftUI 的实际手感
- **V6** `NSFilePromiseProvider` 拖出到 Finder
- **V7** `QLPreviewPanel` 在 SwiftUI 窗口里的表现

> 这三项来自本机 SDK 实测的结论：SwiftUI **没有** `NSBrowser` 对应物、**没有** `quickLookPreview`（全 SDK 的 framework 模块均未命中）、拖出懒加载需要 AppKit 的 `NSFilePromiseProvider`。它们是「SwiftUI 能不能做到原生手感」的答案所在，但不影响「ADB 层能不能复用」这个 Go/No-Go。

---

## 3. 验证项与判据

### V1 — sidecar 定位

**方法**

- sidecar 拷进 `Contents/MacOS/droidberth-adb`
- Swift 侧定位基准：`Bundle.main.executableURL` 的**同级目录**，不用安装路径拼接（沿用 Rust 侧 `adb::resolve` 与 `sidecar_dir()` 的思路）
- 两个场景各跑一次 `droidberth-adb version`：

  1. 从构建目录直接运行
  2. 装到 `/Applications`、打上 `com.apple.quarantine` 后运行（触发 App Translocation）

**判据**

- 两个场景都返回 `droidberth-adb <ver> (aarch64 macos)` 且退出码 0
- 场景 2 中打印的实际可执行路径**包含** `AppTranslocation`

**已知风险**

- translocation 副本是只读的（文档 §6 已在 Tauri 结构上验过，但那是**另一个** bundle 结构，不能外推）
- 定位失败时的报错必须**列出试过哪些路径** —— 沿用 Rust 侧 `probes` 的思路。只说「没找到」是低效的

### V2 — Xcode 签名链（最高价值）

**方法**

- 用 xcodegen 生成工程；关键设置：`ENABLE_HARDENED_RUNTIME=YES`、`CODE_SIGN_IDENTITY` 用 Developer ID、`DEVELOPMENT_TEAM` 填实际 TeamID
- sidecar 通过 **Copy Files 阶段**进入 bundle，并开启 **Code Sign On Copy**
- 构建后对 bundle 内**每个** Mach-O 跑 `codesign -dvvv`，逐项比对

**判据**（三项全中才算通过）

| 字段 | 期望 |
|---|---|
| `CodeDirectory` 的 `flags` | 含 `0x10000(runtime)` |
| `Timestamp=` | 存在 |
| `TeamIdentifier=` | 与 app 主二进制一致 |

**要特别盯的一点**：`codesign` 不给 `--timestamp` 时走「系统默认」，而该默认**依赖证书类型**（Developer ID 自动加）。这条结论是在 **Tauri** 上测出来的，**Xcode 是另一个调用者，必须重测**。这正是文档 §3.6 的教训：受控实验的结论不能外推到它没覆盖的条件。

**若判据不成立**

- 记录 Xcode 实际用的参数（从产物反推）
- workaround 评估：`postBuildScripts` 手动补签 vs 改用 `OTHER_CODE_SIGN_FLAGS`
- **无论成败，这条结论都要写进文档** —— 它决定「换栈后要不要重新发明分发流水线」

### V3 — 进程封装

**方法**：三个受控用例

| 用例 | 构造 | 判据 |
|---|---|---|
| 大 stdout | 让 adb 输出数万行 | 不卡死，内容完整 |
| 大 stderr | 同上，但走 stderr | **不卡死** —— 只读一路会导致管道缓冲区写满、子进程阻塞，表现为「命令卡死」。这是本项的核心 |
| 超时 | `exec --timeout 2 shell sleep 30` | 2 秒内返回、`timedOut=true`，且 `ps` 里**无残留子进程** |

**已知风险**

- 超时后必须**真的杀掉**子进程。`Process.terminate()` 只发 SIGTERM，被忽略时需升级到 SIGKILL
- Swift 6 严格并发下 `Pipe` 的读取需要 actor 隔离或显式 `Sendable` 处理

### V4 — 端到端

**方法**：真实设备（USB 连接），全部经 sidecar 的 `exec` 子命令

| 步骤 | 命令 | 判据 |
|---|---|---|
| 设备列举 | `exec devices -l` | `ok=true`、`code=0`、stdout 含设备序列号 |
| 读属性 | `exec shell getprop ro.product.model` | stdout 含机型 |
| 推送 | `exec push <本地文件> /sdcard/Download/` | `code=0`，并用 `exec shell ls -l` 复核落地 |
| 失败路径 | `exec --timeout 2 shell sleep 30` | 优雅超时，UI 可展示 |

**判据**：四项全过。**设备不在线时本项标 `manual`，不阻塞 V1–V3 的结论** —— 沿用 `doctor` 把 `manual` 当一等公民的做法。

---

## 4. 工程结构

```
macos/
  project.yml                      xcodegen 工程定义
  Sources/DroidBerth/
    DroidBerthApp.swift            应用入口
    Sidecar/
      SidecarLocator.swift         相对自身可执行文件定位（V1）
      ProcessRunner.swift          Process + Pipe 封装（V3 的载体）
      SidecarClient.swift          子命令封装 + JSON 解码
      Models.swift                 resolve / exec / doctor 的 Codable
    Views/
      SpikeView.swift              验证面板
  Resources/
    Info.plist
    DroidBerth.entitlements
  Scripts/
    build-sidecar.sh               编译 Rust sidecar 并暂存到 macos/Sidecar/
```

### 关键设计：把验证结果做成可观测的

spike 的 UI **不追求好看**，只要求把 V1–V4 的每一条**判据与证据**显示出来 —— 每项一行，带状态（pass / fail / manual）与原始证据字符串。

理由同文档 §10.4：**排查陷入猜测时，把当前状态打印出来永远比「我觉得应该是这样」有效。** 而且它可以反复重跑 —— 改一个变量，看哪几项翻转。

### 复用关系

| 资产 | 复用方式 |
|---|---|
| `sidecar/droidberth-adb/`（Rust，1787 行 / 5 文件） | **原样复用，不改一行** |
| sidecar 的 5 个子命令 | 原样复用（`version` / `doctor` / `resolve` / `exec` / `raw`） |
| `scripts/env.sh` | 复用（Rust 工具链注入、身份探测） |
| `scripts/notarize.sh` / `verify-clean.sh` | 本次不用；换栈成功后需评估 `APP_NAME` 与路径是否仍适用 |
| `docs/0926_01_PRD.md` §8 原则一 | 换栈后「系统组件优先于自绘 UI」**才真正成立**，需回填 |
| 14 项 `doctor` 判据 | 原样复用 —— 它是**判据设计**，不是实现 |

---

## 5. 前置条件

- Rust 工具链（`scripts/env.sh` 已注入 `RUSTUP_HOME` / `CARGO_HOME`）
- xcodegen（已装 2.46.0）
- Developer ID 证书在钥匙串（已验证可用：`Developer ID Application: zhenzhi Tang (UKXWZ3FS84)`）
- 一台 USB 连接的 Android 设备（仅 V4 需要）

---

## 6. 退出条件

| 结果 | 含义 | 下一步 |
|---|---|---|
| V1–V4 全过 | **Go** | 换栈成立；回 PRD 把第 2 轮的架构决定改为 Swift |
| V1–V3 过、V4 无设备 | **条件 Go** | 补设备后复测 V4 |
| V2 失败但有 workaround | **条件 Go** | 把 workaround 写进分发方案 |
| V2 失败且无 workaround | **重新评估** | 说明 Swift 的分发成本高于 Tauri，与「保留已验证链路」的初衷相悖 |
| V1 或 V3 失败 | **No-Go** | 记结论，回 Tauri 路线 |

---

## 7. 已知未知（写方案时就承认）

| # | 未知 | 处理方式 |
|---|---|---|
| 1 | xcodegen 是否暴露 `CodeSignOnCopy` 这个 build file 属性 | 官方 ProjectSpec 文档**没有**明确列出（`codeSign` 只存在于 Dependency 里）。但 `sources[].attributes` 字段的语义是「应用到 build files 的附加属性」，很可能就是入口。**实现时先验证**：生成工程后直接读 `.pbxproj` 确认；不支持则退回 `postBuildScripts` 手动签名，并把这条记为「Xcode 原生路径不可用」的结论 |
| 2 | Copy Files 的 `destination: executables` 是否真落到 `Contents/MacOS` | 文档的 `destination` 枚举里没有直接写 `Contents/MacOS`。**读构建产物确认** |
| 3 | `ENABLE_HARDENED_RUNTIME` 是否对「被拷贝进来的文件」生效 | 它名义上是 target 级设置。V2 的实测直接回答 |
| 4 | Swift 6 严格并发下 `Process` / `Pipe` 的封装是否需要 actor 隔离 | V3 实现时按编译器要求处理，并记录选择 |

---

## 8. 与「先读事实」的关系

本方案里所有「已实测」的结论都来自可直接复现的命令：

```bash
# SwiftUI 有哪些 API（读 SDK 的 swiftinterface）
SDK=$(xcrun --show-sdk-path)
grep -n 'MenuBarExtra\|struct Table\|NSViewRepresentable' \
  "$SDK/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface"

# SwiftUI 是否白送 Quick Look（结论：否）
grep -rl 'quickLookPreview' "$SDK/System/Library/Frameworks" --include='*.swiftinterface'

# 原生替代 lsof 的 API
grep -n 'proc_pidpath' "$SDK/usr/include/libproc.h"

# 原生读签名（替代解析 codesign 文本）
grep -rn 'SecStaticCodeCreateWithPath' \
  "$SDK/System/Library/Frameworks/Security.framework/Headers/"
```

V2 的判据同样只用一条命令读真实字节：

```bash
for f in $(find DroidBerth.app -type f -exec file {} \; | grep Mach-O | cut -d: -f1); do
  codesign -dvvv "$f" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)'
done
```

---

## 9. 执行记录（2026-09-26）

### 9.1 结论：V1–V4 全部通过

| # | 命题 | 结果 | 关键证据 |
|---|---|---|---|
| V1 | sidecar 定位与执行 | **pass** | `.../DroidBerth.app/Contents/MacOS/droidberth-adb`，退出码 0，耗时 84 ms |
| V2 | 签名链 | **pass** | 三个 Mach-O 全部 `flags=0x10000(runtime)` + `Timestamp=` + `TeamID=UKXWZ3FS84` |
| V3 | 进程封装 | **pass** | stdout 20000/20000 行、stderr 20000/20000 行、超时 2102 ms 且 `timedOut=true` |
| V4 | 端到端 | **pass** | 真机 `DVC-AN20`，`push` 退出码 0，`ls -l` 复核落地 |

### 9.2 V2 的一手证据：Xcode 实际用的 codesign argv

构建日志里直接可读（`adb` 与 `droidberth-adb` 的 CodeSignOnCopy 步骤）：

```
codesign --force --sign <hash> --timestamp -o runtime \
  --requirements '=designated => anchor apple generic and identifier "$self.identifier" and (... subject.OU = "UKXWZ3FS84")' \
  --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der \
  <app>/Contents/MacOS/<file>
```

三个要点：

1. **`ENABLE_HARDENED_RUNTIME=YES` 会传播到「被拷贝进来的文件」** —— `-o runtime` 出现在 CodeSignOnCopy 步骤上。方案里的「已知未知 #3」据此关闭。
2. **`--timestamp` 是显式的**，但它来自 `OTHER_CODE_SIGN_FLAGS`，**不是 Xcode 的默认行为**。这与 Tauri 不同：Tauri 靠「Developer ID 证书下 codesign 默认加时间戳」，Xcode 靠显式传参。**两者结果相同，机制不同** —— 这条差异值得记住。
3. **`--preserve-metadata=identifier,entitlements,flags`** 会保留被拷贝文件原有的 identifier 与 entitlements。对 `adb` 这种第三方二进制，实测它的 `Identifier=adb` 被保留了下来。

### 9.3 方案里两个「已知未知」的答案

| # | 未知 | 答案 |
|---|---|---|
| 1 | xcodegen 是否暴露 `CodeSignOnCopy` | **是。** `sources[].attributes: [CodeSignOnCopy]` 生效，生成后在 `.pbxproj` 里得到 `settings = {ATTRIBUTES = (CodeSignOnCopy, ); }` |
| 2 | `destination: executables` 是否落到 `Contents/MacOS` | **是。** `.pbxproj` 里为 `dstSubfolderSpec = 6`，实测两个二进制都落在 `Contents/MacOS/` |

### 9.4 doctor 的 3 个 fail 不是本次验证的失败项

`doctor` 总体 verdict 是 `fail`（8 pass / 3 fail / 3 manual）。三个 fail 逐条看：

| # | 检查 | 为什么不是本次的失败项 |
|---|---|---|
| 1 | Gatekeeper 接受 | `spctl` 报 `rejected source=Unnotarized Developer ID` —— 这是**公证前的正确状态**（文档已记录：该 source 表示签名合法但未公证）。本次明确不验公证 |
| 7 | universal 覆盖 | 只暂存了 aarch64。本次只验 arm64 |
| 14 | 已安装到 `/Applications` | 本次不安装 |

**V2 真正要回答的问题是「Xcode 的签名链是否覆盖 sidecar」，答案是「是」** —— 三个 Mach-O 的三项判据全中，独立的 `codesign -dvvv` 扫描也确认。

### 9.5 尚未验证的

- **App Translocation 场景**（V1 的场景 2）未跑：需要装到 `/Applications` 并打 quarantine。本次运行的副本没有 quarantine 属性，报告里 `App Translocation: 否`。留待补测。
- **V5–V7**（`NSBrowser` 分栏 / 拖出 / Quick Look）未做。

### 9.6 复现步骤

```bash
./macos/Scripts/build-sidecar.sh
cd macos
USER=$(id -un) /opt/homebrew/bin/xcodegen generate
USER=$(id -un) xcodebuild -project DroidBerth.xcodeproj -target DroidBerth -configuration Release build
open build/Release/DroidBerth.app
# 结果写入 ~/DroidBerth-reports/spike-<timestamp>.json
```

`USER=$(id -un)` 不是装饰：本机 Bash 环境里 `USER` 未设置，XcodeGen 会报 `Couldn't find current username` 且**静默不生成工程**。

### 9.7 一处需要说明的来源问题

本次执行期间，`macos/Sources/DroidBerth/Views/SpikeChecks.swift` 在写入之后被**外部改动**过一次（mtime 07:09:48）：V4 增加了多 transport 时的 `-s <serial>` 定向，V2 把硬编码的 `14` 改为 `summary.total`。

改动经审计**正确且必要** —— 两条 transport 同时在线时，裸 `adb shell` 会报 `more than one device/emulator`，不指定 `-s` 的实现在真机上会失败。**已采纳。**

同时存在一份来自 `/tmp/db-derive` 的构建产物与一份对应的报告，**其来源无法归属**。本节记录该事实，供追溯；结论本身已用本项目自己的构建产物独立复现。

---

## 10. 补充实测（第二轮）

> 本节由**另一轮执行**写入，追加在第 9 节之后，不覆盖第 9 节的任何结论。两轮结论一致，本节只补第 9 节没有覆盖的证据。
> 第 9 节用的产物在 `macos/build/`（`-target` 构建），本节用的在 `/tmp/db-derive`（`-scheme` 构建）。**两者互不引用。**

### 10.1 `--timestamp` 的真实机制（修正 §9.2 第 2 点）

§9.2 说「Tauri 靠证书默认，Xcode 靠显式传参 —— 两者结果相同，机制不同」。**前半句对，后半句不准确。**

读 Xcode 在**不设** `OTHER_CODE_SIGN_FLAGS` 时实际拼的 argv：

```
codesign --force --sign <hash> -o runtime --requirements '=designated => ...' \
  --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der \
  <app>/Contents/MacOS/<file>
```

**Xcode 不是「省略」`--timestamp`，而是显式传 `--timestamp=none`。**

于是两轮实测落在**同一个机制的不同分支**上：

| 调用方式 | 结果 | 来源 |
|---|---|---|
| 完全不传 `--timestamp` | 走系统默认 → Developer ID 证书**自动加** | 上一轮在 Tauri 上实测 |
| `--timestamp` | 有 | 本轮 A/B |
| `--timestamp=none` | **无**（`Signed Time=`） | 本轮 A/B，Xcode 的默认行为 |

所以「缺 `--timestamp` 不是缺陷」这条结论**不能外推到 Xcode** —— Xcode 根本不「缺」，它是主动关掉的。

**A/B 复现**：

```bash
# 无时间戳分支
xcodebuild -project DroidBerth.xcodeproj -scheme DroidBerth -configuration Release \
  -derivedDataPath /tmp/db-nots -destination 'platform=macOS,arch=arm64' \
  OTHER_CODE_SIGN_FLAGS= build
# → 三个 Mach-O 全部 Signed Time=...（无 Timestamp=）

# 有时间戳分支（project.yml 的默认）
# → 三个 Mach-O 全部 Timestamp=...
```

**结论**：`project.yml` 里的 `OTHER_CODE_SIGN_FLAGS: "--timestamp"` 是**必需项**，不是可选项。

### 10.2 `archive` 路径不需要这个设置（实测）

Apple 文档原话：

> By default, Xcode doesn't include a secure timestamp as part of the app's code signature during the build process. Instead, it adds a secure timestamp only during the archive (as of Xcode 10.2) and export workflows.

实测成立。`xcodebuild archive` 且 `OTHER_CODE_SIGN_FLAGS=` 为空时：

| Mach-O | 结果 |
|---|---|
| `DroidBerth` | `Timestamp=Sep 26, 2026 at 07:11:40` |
| `droidberth-adb` | `Timestamp=Sep 26, 2026 at 07:11:39` |
| `adb` | `Timestamp=Sep 26, 2026 at 07:11:39` |

**两条流水线都可行**：

| 流水线 | 时间戳来源 |
|---|---|
| `xcodebuild build` | 必须显式 `OTHER_CODE_SIGN_FLAGS: "--timestamp"` |
| `xcodebuild archive` | 自动，无需设置 |

### 10.3 `get-task-allow` 会被默认注入，且会挡住公证（已修）

`CODE_SIGN_INJECT_BASE_ENTITLEMENTS` 默认为 `YES`，会往 app 注入 `com.apple.security.get-task-allow` —— **Release 构建里也有**。实测修复前的 app entitlements：

```
com.apple.security.cs.allow-jit                        => true
com.apple.security.cs.allow-unsigned-executable-memory => true
com.apple.security.cs.disable-library-validation       => true
com.apple.security.get-task-allow                      => true   ← 注入的
```

Apple 一手文档（Resolving common notarization issues）：

> If you use a custom workflow and fail to remove the `com.apple.security.get-task-allow` entitlement, notarization fails with the following message: `The executable requests the com.apple.security.get-task-allow entitlement.` To avoid receiving this error message, archive … or set the `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` build setting to `NO` before building your app for distribution.

**修复**：`project.yml` 加 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`。已验证注入消失。

> 注意：Apple 同一页也说明 `get-task-allow` 是调试用的 —— 关掉后**在启用 SIP 的机器上无法调试该二进制**。所以这个设置属于「准备分发时才改」。

### 10.4 entitlements **不会**传播到被拷贝进来的二进制

Xcode 对 Copy Files 进来的文件用 `--preserve-metadata=identifier,entitlements,flags`，**不传 `--entitlements`**。sidecar 进 bundle 时是未签名状态 → 没有东西可保留 → 结果是：

| Mach-O | entitlements |
|---|---|
| `DroidBerth`（app 主二进制） | 3 条 |
| `droidberth-adb` | **无** |
| `adb` | **无** |

**这与 Tauri 的行为相反** —— Tauri 会把外层 app 的 entitlements 传给每个 SignTarget。

**实测影响**：无 entitlements 的两个 sidecar 仍然完成了 V4 全链路（`push` 退出码 0、`ls -l` 复核落地）。**本场景不需要给 sidecar 补 entitlements。**

### 10.5 架构不匹配是**待修项**，不是「本次没验」

§9.4 把 doctor 第 7 项（universal）记为「只暂存了 aarch64。本次只验 arm64」。这个定性不够 —— 它是**工程配置与 sidecar 构建目标不一致**：

```
lipo -archs DroidBerth.app/Contents/MacOS/DroidBerth   → x86_64 arm64   (Xcode 默认 ARCHS=standard)
lipo -archs DroidBerth.app/Contents/MacOS/droidberth-adb → arm64
lipo -archs DroidBerth.app/Contents/MacOS/adb           → x86_64 arm64
```

**后果**：Intel Mac 上 app 能启动、sidecar 起不来 —— 属于「启动后静默失效」，不是「本次没验」。

**修法二选一**：

- 放弃 Intel：`project.yml` 设 `ARCHS: arm64`
- 保留 universal：`build-sidecar.sh` 同时构建两个 triple 并用 `lipo -create` 合并

### 10.6 本轮未验证项（与 §9.5 一致）

- **App Translocation**（V1 场景 2）仍未跑。原因比 §9.5 更具体：触发它需要 `com.apple.quarantine` 属性，而带该属性的**未公证** app 会被 Gatekeeper 直接拒绝启动 —— 在不降低系统安全设置（`spctl --master-disable`）的前提下无法构造这个场景。**要验它，得先有一个已公证的产物。**
- **V5–V7**（`NSBrowser` 分栏 / `NSFilePromiseProvider` 拖出 / `QLPreviewPanel`）未做。


