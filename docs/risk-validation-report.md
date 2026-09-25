# DroidBerth — Tauri + ADB Sidecar macOS 技术风险验证报告

| 项目 | 值 |
|---|---|
| 验证日期 | 2026-09-26 |
| 验证机器 | macOS 27.0 (26A428) arm64 |
| 签名身份 | `Developer ID Application: zhenzhi Tang (UKXWZ3FS84)` |
| Tauri CLI | 2.11.5 |
| 测试设备 | HUAWEI DVC-AN20 / Android 10 (SDK 29) / `192.168.2.183` |
| 判据 | `droidock-adb doctor` 的 14 项检查 |
| 最终判定 | **9 pass / 1 fail / 3 manual / 1 skip** |

> **命名说明**：项目原名 `DroidDock`，与 GitHub 上若干同领域项目（如 `rajivm1991/DroidDock`，同样是 macOS + ADB 浏览 Android 设备）重名，故统一改称 **DroidBerth**。本报告记录的实际构建、签名与公证发生在改名之前，文中所有路径与产物名均为**按新名 1:1 映射后的写法**；代码层面的改名尚未执行，因此仓库中的实际路径仍是旧名。

> **阅读约定**：本报告只记录实测结果。凡属推断，标注「推断」；凡未验证，标注「未验证」。文中所有命令与输出均为本机真实执行结果，可用 `scripts/` 下的脚本复现。

---

## 一、结论摘要

### 1.1 对文档核心假设的判定

文档 `testfile.md` 的第 2.1 节给出了一个明确的技术判断，并据此设计了整个模块一。**该判断在本机实测中不成立。**

| 文档 §2.1 的主张 | 判定 | 实测依据 |
|---|---|---|
| Tauri 不会给 `externalBin` 附加 `--options=runtime` | **不成立** | sidecar 的 CodeDirectory 为 `flags=0x10000(runtime)` |
| Tauri 不会把外层 app 的 entitlements 合并进 sidecar 签名 | **不成立** | 三个二进制的 entitlements 逐字节相同（见 §2.3） |
| 不传 `--timestamp` 导致安全时间戳缺失 | **前提不成立** | Developer ID 证书下 `codesign` 默认即加时间戳（见 §2.4） |
| 只要 `externalBin` 非空，公证必然失败（Issue #11992） | **未复现** | 带 sidecar 的构建公证两轮 `Accepted` |

**结论：文档模块一所要验证的风险（sidecar 破坏公证）在本机不存在。** 不是因为绕过了它，而是因为它描述的根因在当前 Tauri 版本下已经不成立。

### 1.2 文档没有预见到的真实缺陷

验证过程中发现两个文档未提及的缺陷，均已在代码中修复：

1. **`notarize.sh` 构建 DMG 时不签名**（§2.5）。产出一个"有 stapled ticket 但无签名"的 DMG，`spctl` 报 `rejected source=no usable signature`。这个形状在仓库内出现过 **2 次**。
2. **Developer ID 向导会把失败记录成成功**（§2.6）。`store-credentials` 失败时仍写入 `NOTARY_PROFILE`，并打印 `✓ Setup complete`。

### 1.3 风险检查清单逐条判定

文档第八章的 9 项清单：

| # | 文档的验证项 | 通过标准 | 实测判定 |
|---|---|---|---|
| 1 | Sidecar 公证（干净环境） | 公证通过 + `spctl` accepted | **通过**（本机；干净 VM 未验证） |
| 2 | Sidecar 签名含 hardened runtime | `flags=0x10000(runtime)` | **通过** |
| 3 | Sidecar 签名含 secure timestamp | `Timestamp=` 存在 | **通过** |
| 4 | ADB 无外部动态库依赖 | `otool -L` 仅系统路径 | **通过** |
| 5 | `adb tcpip 5555` 息屏后重连 | 3 次重试内成功 | **通过**（纯无线下息屏 40 秒未断；断开→重连 3/3 成功） |
| 6 | 手机重启后端口状态 | 端口失效，需 USB 重激活 | **未验证**（未重启设备） |
| 7 | Universal Binary（arm64 + x86_64） | 两架构均通过公证 | **未通过**（仅构建 arm64） |
| 8 | ADB 二进制体积 | DMG ≤ 40MB | **通过**（DMG 2.1MB） |
| 9 | 5037 端口冲突处理 | App 能检测并提示 | **通过**（`doctor` 第 9 项已能识别并区分四种状态） |

### 1.4 Go/No-Go 建议

**建议：Go。** 核心风险（模块一 + 模块二）在 arm64 单架构下已全部走通，包括最关键的"下载后安装、带 quarantine 属性启动、Gatekeeper 不拦截"这一条端到端证据。

进入开发前仍需补的三项，按优先级：

1. **在干净的 macOS 15+ 虚拟机上复验**（文档反复强调，本机做不到，见 §6.1）。
2. **补 universal 构建**（第 7 项）。
3. **扩大设备覆盖**：文档要求小米/OPPO/三星各一台、Android 11+；目前只有一台华为 Android 10。

---

## 二、模块一：Sidecar 打包、签名与公证

### 2.1 验证方法

不采用文档建议的"新建一个最小 demo"路线，而是直接构建完整 demo，并把**每个签名参数**都做成可观测的。为此：

- sidecar 二进制（`src-tauri/binaries/droidock-adb-*`）**故意不预签名**，让 Tauri 的签名步骤成为唯一变量。
- `droidock-adb doctor` 命令自检它所在的 bundle，把 14 项检查以机器可读形式输出。

### 2.2 Tauri 的实际 codesign 调用

从 `tauri-macos-sign` 2.3.4 的实际行为反推，argv 形状为：

```
codesign --force -s <identity> [--options runtime] [--keychain <p>] [--entitlements <p>] <path>
```

构建日志显示 Tauri 对三个目标依次签名（顺序：sidecar → 主二进制 → 外层 app）：

```
Signing .../DroidBerth.app/Contents/MacOS/droidock-adb
Signing .../DroidBerth.app/Contents/MacOS/droidock
Signing .../DroidBerth.app
```

### 2.3 entitlements 传播实测

对构建产物中三个二进制分别执行 `codesign -d --entitlements :-`，结果**完全相同**：

```
com.apple.security.cs.allow-jit                        true
com.apple.security.cs.allow-unsigned-executable-memory true
com.apple.security.cs.disable-library-validation       true
```

这直接否定了文档 §2.1 的"entitlements 不会合并进 sidecar 的签名"。Tauri 把外层 app 的 `entitlements` 配置项传给了**每一个** SignTarget。

### 2.4 时间戳：文档关注的焦点，实测不是问题

文档 §2.1 与 §3.1 都把"缺 secure timestamp"列为高风险项。实测推翻了它。

**干净构建**（清空 bundle，只跑 `tauri build`，中间不插任何手动重签名）后，三个二进制**全部带时间戳**：

| 二进制 | flags | Timestamp |
|---|---|---|
| `Contents/MacOS/droidock-adb` | `0x10000(runtime)` | `Sep 26, 2026 at 05:49:40` |
| `Contents/MacOS/droidock` | `0x10000(runtime)` | `Sep 26, 2026 at 05:49:41` |
| `DroidBerth.app` | `0x10000(runtime)` | `Sep 26, 2026 at 05:49:41` |

**受控 A/B/C 实验**（同一份二进制、同一张证书，只改参数）：

| 调用形状 | Timestamp |
|---|---|
| `codesign --force -s <id> --options runtime`（**Tauri 的实际形状**） | **有** |
| `codesign --force -s <id> --options runtime --timestamp` | 有 |
| `codesign --force -s <id> --options runtime --timestamp=none` | **无** |

**正确模型**：`codesign` 在既不给 `--timestamp` 也不给 `--timestamp=none` 时，走"系统默认行为"，而**该默认行为依赖证书类型**：

- Apple Development 证书 → 不加时间戳
- Developer ID 证书 → **自动加**

这正是 `man codesign` 中那句 "It may result in **some but not all** code signatures being timestamped" 的确切含义。

> **教训**：早先用 Apple Development 证书做的 A/B 实验得出"时间戳与证书类型无关"，是因为那个实验只覆盖了"默认不加"的那一支。**用开发证书做的签名实验，结论不能外推到发布证书。**

### 2.5 发现的缺陷：`notarize.sh` 构建 DMG 时不签名

第一轮公证跑完后，`spctl` 结果出现分裂：

| 产物 | spctl 判定 |
|---|---|
| `DroidBerth.app` | `accepted`（退出码 0） |
| `DroidBerth.dmg` | **`rejected source=no usable signature`**（退出码 3） |

查证：`codesign -dv DroidBerth.dmg` → `code object is not signed at all`。而 Tauri 自己产出的 `DroidBerth_0.1.0_aarch64.dmg` 是**有**签名的。

**根因**：`notarize.sh` 用裸 `hdiutil create` 重建 DMG，从头到尾没有一次 `codesign`。于是得到"有 stapled ticket 但无签名"的产物 ——

- 公证服务器收下（它检查的是内容）
- `stapler` 通过（它只校验 ticket 是否存在）
- 但 Gatekeeper 发现没有可用签名 → 拒绝

正确顺序是 **create → sign → notarize → staple**，脚本漏掉了 sign。

**这个形状在本仓出现过 2 次**（`notarize.sh` 与 `resign.sh`）。已抽成 `scripts/env.sh` 的 `make_signed_dmg()`，两处统一调用，避免以后再次分叉。

修复后重跑：

| 产物 | spctl 判定 |
|---|---|
| `DroidBerth.app` | `accepted source=Notarized Developer ID` |
| `DroidBerth.dmg` | `accepted source=Notarized Developer ID` |

### 2.6 发现的缺陷：向导把失败记录成成功

`scripts/wizard-developer-id.sh` 的 stage 6 原逻辑：

```bash
if xcrun notarytool store-credentials "$PROFILE" ... ; then
  printf '  ✓ stored ...'
else
  warn "store-credentials failed"          # 只警告
fi
write_env NOTARY_PROFILE "$PROFILE"        # 但无论成败都写入
```

`store-credentials` 失败时，`.env` 里仍会留下 `NOTARY_PROFILE=droidock`，指向一个不存在的 keychain profile。`notarize.sh` 看到该变量非空即走 keychain 分支，最终在提交时报一个与真实原因无关的错误。`finish` 也**无条件**打印 `✓ Setup complete`。

**形状：把"记录一个意图"当成"记录一个结果"。**

已修：仅在 `store-credentials` 成功**且** `notarytool history` 验证通过时才写入；失败则用新增的 `drop_env` 摘掉陈旧值，并计入 `SKIPPED`，使收尾摘要列出待办。

### 2.7 公证流水线与实测结果

```
scripts/build.sh      → 签名（不公证）
scripts/notarize.sh   → 公证 + staple（app 与 DMG 各一轮）
scripts/verify-clean.sh → 挂载 DMG、签名清单、spctl、可选安装
```

`build.sh` 在调用 `tauri build` 前会 `unset` 公证相关的环境变量。原因是实测发现：**只要 `APPLE_ID`/`APPLE_PASSWORD`/`APPLE_TEAM_ID` 出现在环境里，Tauri 就会自动触发公证，并在凭据无效时让整个构建失败**。

关于这个行为的实测结论：

- `tauri.conf.json` 中**没有** `notarize` 字段（已在 `config.schema.json` 中全文检索确认）。
- `tauri build` **没有** `--no-notarize` 选项（只有 `--no-sign`、`--skip-stapling`）。
- 触发条件纯粹是环境变量。缺凭据时 Tauri 打印 `skipping app notarization` 并继续。
- Tauri 的自动公证**只处理 `.app`，不处理 DMG**，且不 staple。

因此把公证从构建中剥离，理由是三条：签名与公证应当解耦；Tauri 的自动路径不完整（不覆盖 DMG）；本 demo 的目的正是逐步观测每一环。

**公证结果**（`notarytool` 提交 ID 可查）：

| 提交物 | Submission ID | 状态 |
|---|---|---|
| `DroidBerth.zip`（app） | `cefd6134-99e6-46ad-9735-5a4ff99e0cf4` | Accepted |
| `DroidBerth.dmg`（修复前，未签名） | `dcbea7bf-f99d-4c6a-b4d3-99a29b43ff40` | Accepted |
| `DroidBerth.dmg`（修复后，已签名） | `765a63c2-b39e-45db-bfdc-2c9a620eb187` | Accepted |

---

## 三、模块二：macOS 15 深度校验

文档 §3.1 列出 macOS 15 相对 14 新增的三项深度校验。逐条实测：

| # | 文档描述 | 实测结果 |
|---|---|---|
| 1 | hardened-runtime 签名必须有 secure timestamp | **满足**（见 §2.4） |
| 2 | 对嵌套 Mach-O 做深度校验，ad-hoc 或异 TeamID 会导致整个 bundle 被拒 | **满足**：bundle 内 1 个嵌套 Mach-O，TeamID 与外层一致（`UKXWZ3FS84`） |
| 3 | hardened runtime 必须设在每个嵌套可执行文件上；外层 entitlements 不向下传播 | **满足**：三个二进制均为 `flags=0x10000(runtime)`；entitlements 实测**会**传播（见 §2.3） |

### 3.1 doctor 14 项的演进

| 阶段 | 结果 |
|---|---|
| 初版构建（Apple Development 证书） | 6 pass / 5 fail / 3 manual / 0 skip |
| 换 Developer ID 证书重新构建 | 7 pass / 3 fail / 3 manual / 1 skip |
| 完成公证 + staple | 8 pass / 2 fail / 3 manual / 1 skip |
| 安装到 `/Applications` | **9 pass / 1 fail / 3 manual / 1 skip** |

关键翻转：

| # | 检查 | 初版 | 最终 |
|---|---|---|---|
| 1 | Gatekeeper 接受签名 bundle（blocker） | FAIL `rejected`（证书类型） | **PASS** `accepted source=Notarized Developer ID` |
| 3 | 签名含安全时间戳 | FAIL | **PASS** |
| 12 | 身份可用于公证 | FAIL `cert=apple-development` | **PASS** `cert=developer-id` |
| 14 | 安装到 `/Applications` | FAIL | **PASS** |

第 1 项的 FAIL 理由变化值得单独指出：初版是证书类型导致的 `rejected`；换证书后变成 `rejected source=Unnotarized Developer ID`（**公证前的正确状态**）；公证 + staple 后翻成 `accepted`。三个阶段理由各不相同，读结论时不能只看 pass/fail。

### 3.2 端到端证据（最强的一条）

在安装副本上人为打上 `com.apple.quarantine` 属性模拟浏览器下载：

```
xattr: 0081;6ab6ef4c;DroidBerth;

$ spctl -vvv --assess -t open --context context:primary-signature /Applications/DroidBerth.app
/Applications/DroidBerth.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: zhenzhi Tang (UKXWZ3FS84)
退出码=0
```

`open` 启动后进程正常拉起，`log show --predicate 'subsystem == "com.apple.syspolicy"'` 无任何拒绝记录，**未出现"无法验证开发者"对话框**。

---

## 四、模块三：ADB 依赖与许可

### 4.1 依赖实测 —— 文档的前提不成立

文档 §4.1 称预编译 ADB "不是静态链接的，它依赖若干系统 dylib"，并据此推出两个问题。实测：

```
$ vendor/platform-tools/adb version
Android Debug Bridge version 1.0.41
Version 37.0.1-15733141

$ lipo -archs vendor/platform-tools/adb
x86_64 arm64

$ otool -L vendor/platform-tools/adb    # 过滤掉架构头部行
  /usr/lib/libSystem.B.dylib
  /usr/lib/libobjc.A.dylib
  /System/Library/Frameworks/CoreFoundation.framework/.../CoreFoundation
  /System/Library/Frameworks/IOKit.framework/.../IOKit
  /System/Library/Frameworks/Security.framework/.../Security
```

**非系统路径依赖：0 个。** 这恰好满足文档自己在风险清单第 4 项写下的通过标准（"`otool -L` 仅显示系统路径"）。

文档把"不是静态链接"与"有需要处理的依赖"混为一谈。**动态链接到系统库不构成公证障碍** —— 系统库由 OS 提供，不需要打包也不需要签名。

> **一个踩过两次的坑**：`otool -L` 对 universal 二进制会**按架构各打印一次头部行**。解析时若只跳过第一行，第二个架构的头部会被当成依赖。本项目在 Rust 的 `otool_dependencies` 与本次 shell 提取中各踩了一次。正确做法是只接受以 tab/空格开头的行，并去重。

### 4.2 文档 §4.2 方案 B 的命令是错的

文档给出的 AOSP 构建路径：

```bash
git clone https://github.com/aosp-mirror/platform_system_core.git
cd platform_system_core/adb
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release     # ← 失败
```

实测 `cmake ..` 报 `does not appear to contain CMakeLists.txt`。用 `find` 全仓检索确认：**AOSP 的 `platform_system_core` 使用 Soong（`Android.bp`），上游不存在任何 `CMakeLists.txt`**。

因此 `scripts/build-adb.sh` 已从"构建脚本"改写为**可行性探针**：它检查前置条件并给出判定，而不是盲目执行一条未经验证的构建命令。

### 4.3 许可分析

文档 §4.1 引用的是 "SDK Terms & Conditions **第 3.3 条**"。核对后：

- 相关条款实际是 **§3.4**（禁止再分发 SDK 的组成部分）。
- **§3.5 对开源组件有豁免**。
- `platform-tools/NOTICE.txt` 声明该 zip 整体为 **Apache-2.0**；其中 16 段 GPL/LGPL 声明仅覆盖 `mke2fs` / `make_f2fs` 等单独工具，不覆盖 `adb`。

**这不是法律意见。** 结论仅限：文档给出的"§3.3 禁止再分发"这一论据不准确，实际的许可图景比文档描述的宽松，但仍有解释空间，正式分发前应让法务确认。

`scripts/use-sdk-adb.sh` 在脚本开头明确标注"仅用于本地验证，不要把它当作分发决策"。

---

## 五、模块四：ADB WiFi 连接可靠性

### 5.1 实测数据

设备：HUAWEI DVC-AN20，Android 10（SDK 29），`wlan0 = 192.168.2.183`。
Mac：`en1 = 192.168.2.181`，与设备同 /24 网段，ping 2/2 通。

| 步骤 | 命令 | 结果 |
|---|---|---|
| USB 基线 | `adb devices -l` | `Q2NNW20730017388  device` |
| 切 TCP | `adb tcpip 5555` | `restarting in TCP mode port: 5555` |
| WiFi 连接 | `adb connect 192.168.2.183:5555` | `connected to 192.168.2.183:5555` |
| 双 transport 并存 | `adb devices -l` | USB 与 `192.168.2.183:5555` 同时为 `device` |
| TCP 可用性 | `adb -s 192.168.2.183:5555 shell getprop ro.product.model` | `DVC-AN20` |
| 息屏存活（USB 仍在） | 熄屏后等待 25 秒再查 | TCP 仍为 `device`，命令仍返回 `DVC-AN20`（退出码 0） |
| **拔掉 USB 后** | `adb devices -l` | 列表中**只剩** `192.168.2.183:5555`；USB 序列号报 `device not found` |
| **纯无线执行命令** | `shell getprop ro.product.model` / `ro.build.version.release` | `DVC-AN20` / `10` |
| **断开 → 重连（3 次）** | `adb disconnect` + `adb connect` 循环 | **3/3 全部成功** |
| **纯无线下息屏 40 秒** | 熄屏 → 等待 40 秒 → 查状态 → 执行命令 | 仍为 `device`，命令返回 `DVC-AN20`（退出码 0） |
| 恢复屏幕 | `input keyevent 26` | `mWakefulness=Awake` |

**这一项（清单第 5 项）判定为通过。** 关键证据是最后两行：USB 物理拔除后，仅靠 WiFi 通道仍能建立连接、下发指令，且息屏 40 秒不中断；反复断开重连 3 次全部成功，满足文档"3 次重试内成功"的判据。

**延迟特征**（各 10 次 `shell true`，含 adb 客户端启动开销，不是纯网络 RTT）：

| 通道 | 10 次总耗时 | 平均 |
|---|---|---|
| TCP | 413 ms | 41 ms/次 |
| USB | 343 ms | 34 ms/次 |

TCP 约慢 20%，完全可用。

### 5.2 未完成的场景

以下两项**未验证**，需要人工介入：

| 场景 | 为何未做 |
|---|---|
| 切换 WiFi 网络后重连 | 需要人工切换网络。文档预期"需使用新 IP，端口保持 5555" |
| 手机重启后端口状态（清单第 6 项） | `adb reboot` 后设备可能进入 `unauthorized` 状态，需人工解锁并重新授权。未在未获确认的情况下执行 |

### 5.3 与文档描述的差异

- 文档 §5.1 强调"Android 11+ 无线调试端口随机（30000–49999）"。本设备为 **Android 10**，不涉及该行为，**未验证**。
- 文档提到的 "Android 17 ADB Wi-Fi 2.0" 在本设备上**无法验证**。

---

## 六、附加发现：App Translocation

这一项不在文档的风险清单内，但在验证 Gatekeeper 时观察到，值得记录。

### 6.1 现象

已公证、已 staple 的 app，在带 `com.apple.quarantine` 属性时启动，运行路径变成：

```
/private/var/folders/.../AppTranslocation/32DC09D4-.../d/DroidBerth.app/Contents/MacOS/droidock
```

### 6.2 受控实验

同一份二进制、同一张证书、同样已公证，唯一变量是 quarantine 属性：

| 条件 | 运行路径 |
|---|---|
| **无** quarantine | `/private/tmp/t2/DroidBerth.app/...`（**原地运行**） |
| **有** quarantine | `.../AppTranslocation/.../DroidBerth.app/...`（被随机化） |

**推断**：触发 translocation 的是 quarantine 标志，而非公证状态。也就是说，**已公证的 app 只要带 quarantine 仍会被 translocation**。

**未验证**：真实浏览器下载（quarantine 由下载器写入，agent 名与 flag 位不同）是否产生同样行为；用户经 Finder 拖入后首次启动是否停止 translocation。本机无法构造这两个条件 —— 尝试删除 `/Applications` 副本的 quarantine 时返回 `Operation not permitted`（该 bundle 在首次启动后携带受保护的 `com.apple.provenance`，导致 xattr 不可修改）。

### 6.3 对本 app 的实际影响：无

translocation 的副本是**只读**的，会破坏"往 bundle 内写文件"或"依赖 bundle 绝对路径"的应用。逐项核对：

| 潜在风险点 | 实测 |
|---|---|
| sidecar 能否定位 | 能。translocated 副本中两个 Mach-O 齐全，`droidock-adb version` 正常返回 |
| bundle 自检能否工作 | 能。从 translocated 路径跑 `doctor --table` 正常，且报 `spctl accepted` |
| 报告写入是否受只读限制 | 不受。`save_report` 写入 `$HOME/DroidBerth-reports/`，在 bundle 之外 |
| 是否弹 Gatekeeper 对话框 | 不弹。`syspolicy` 日志无拒绝记录 |

**结论：translocation 在本 app 上不产生功能影响。**

---

## 七、未决项

| # | 未决项 | 阻塞原因 | 建议动作 |
|---|---|---|---|
| 1 | 干净 macOS 15+ VM 上复验 | 本机是 macOS 27.0，且已运行过该 app；文档明确要求"从未安装过该 App"的环境 | 建一台全新 VM 跑 `scripts/verify-clean.sh --apply --quarantine` |
| 2 | Universal 构建（清单第 7 项） | 本机仅构建 arm64（按用户要求先验 arm64） | `scripts/build.sh --universal` |
| 3 | 设备覆盖不足 | 文档要求小米/OPPO/三星各一台、Android 11+；现仅一台华为 Android 10 | 补充设备 |
| 4 | 切换 WiFi 网络、手机重启两个场景 | 需人工操作 | 按 `doctor` 第 5、6 项的指引执行 |
| 5 | 5037 端口当前被占用 | `vendor/platform-tools/adb`（pid 27302）持有该端口 | 属正常状态（`doctor` 第 9 项已识别为"我们自己的 adb"）；若要与 SDK adb 混用需注意版本一致性 |

---

## 八、脚本清单

| 脚本 | 职责 |
|---|---|
| `scripts/env.sh` | 共享库：`.env` 解析（不用 `source`，值含空格与括号）、身份探测、bundle 路径解析、`make_signed_dmg()` |
| `scripts/build-sidecars.sh` | 编译 sidecar 到 `src-tauri/binaries/`，**故意不预签名** |
| `scripts/build.sh` | 构建 + 签名；调用 tauri 前剥离公证凭据 |
| `scripts/notarize.sh` | 公证 app、staple、构建并签名 DMG、公证 DMG、staple |
| `scripts/resign.sh` | 手动重签名（**已基本过时**，见下） |
| `scripts/verify-clean.sh` | 挂载 DMG、签名清单、spctl；`--apply` 安装到 `/Applications`，`--quarantine` 模拟下载 |
| `scripts/checklist.sh` | 对 bundle 运行 `doctor --table` |
| `scripts/build-adb.sh` | AOSP 构建可行性探针（不是构建脚本） |
| `scripts/use-sdk-adb.sh` | 把 SDK adb 拷入 `binaries/`，附许可警示 |
| `scripts/wizard-developer-id.sh` | Developer ID + 公证凭据的 8 阶段向导 |

**关于 `resign.sh`**：它的存在理由是"给签名补 `--timestamp`"。本轮已证明在 Developer ID 证书下 Tauri 自己就会加时间戳，**该理由不再成立**。目前保留的唯一用途是配合 `DROIDDOCK_SIDECAR_ENTITLEMENTS` 环境变量做 entitlements 替换实验。

---

## 九、构建产物

| 产物 | 路径 | 大小 |
|---|---|---|
| App bundle | `src-tauri/target/aarch64-apple-darwin/release/bundle/macos/DroidBerth.app` | 7.8 MB |
| 公证版 DMG | `src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/DroidBerth.dmg` | 2.1 MB |
| Tauri 版 DMG | `.../dmg/DroidBerth_0.1.0_aarch64.dmg` | 2.0 MB |
| 安装副本 | `/Applications/DroidBerth.app` | — |
| 检查报告 | `reports/doctor-report*.txt` / `.json` | — |

> **注意**：目录下同时存在两个 DMG。`DroidBerth.dmg` 是 `notarize.sh` 产出的**已公证 + 已签名**版本；`DroidBerth_0.1.0_aarch64.dmg` 是 `tauri build` 直接产出的、**仅签名未公证**版本。分发时务必使用前者。

---

## 十、复现步骤

```bash
cd /Users/tango/Developments/DroidBerth

# 前置：.env 中需有 APPLE_SIGNING_IDENTITY / APPLE_TEAM_ID / APPLE_ID / APPLE_PASSWORD
#      并已建立 keychain profile：
xcrun notarytool store-credentials droidock \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD"

# 1. 构建 + 签名
./scripts/build.sh

# 2. 公证 + staple（app 与 DMG 各一轮，约 1 分钟）
./scripts/notarize.sh

# 3. 验证
./scripts/checklist.sh
./scripts/verify-clean.sh \
  src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/DroidBerth.dmg \
  --apply --replace --quarantine
```

**判据**：

- `spctl --assess -t open --context context:primary-signature <app|dmg>` 退出码 0 且 `source=Notarized Developer ID`
- `xcrun stapler validate <app|dmg>` 输出 `The validate action worked!`
- `doctor` 达到 9 pass / 1 fail / 3 manual / 1 skip（剩余 fail 为 universal 构建）

---

## 附录 A：原始输出存档

- `reports/doctor-report.txt` / `.json` —— 公证后、安装前的检查结果
- `reports/doctor-report-installed.txt` / `.json` —— 安装到 `/Applications` 后的检查结果

## 附录 B：本报告推翻或修正的文档条目

| 文档位置 | 原文主张 | 修正 |
|---|---|---|
| §2.1 | Tauri 不给 externalBin 加 `--options=runtime` | 加了 |
| §2.1 | Tauri 不把外层 entitlements 合并进 sidecar | 合并了 |
| §2.1 | 缺 `--timestamp` 导致时间戳缺失 | Developer ID 证书下默认即有时间戳 |
| §2.1 | 只要 externalBin 非空公证必失败 | 未复现，公证通过 |
| §3.1 | 外层 entitlements 不向下传播 | 实测传播到每个 SignTarget |
| §4.1 | SDK adb 依赖若干系统 dylib，构成公证问题 | 依赖仅系统库，不构成问题 |
| §4.1 | 许可限制在 SDK Terms §3.3 | 实为 §3.4，且有 §3.5 开源豁免 |
| §4.2 | AOSP 可用 `cmake ..` 构建 | 上游无 CMakeLists.txt，使用 Soong |
| §7.3 | 签名顺序 sidecar → dylib → app → DMG | 正确，但文档未指出 DMG 本身也必须签名 |
