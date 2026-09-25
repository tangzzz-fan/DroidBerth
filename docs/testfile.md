# Tauri + ADB Sidecar macOS App 技术风险验证文档

**用途**：在正式投入开发前，用一个最小化 Tauri demo 集中验证方案中风险最高的几个技术点。验证通过后再决定是否进入完整开发。

**核心验证目标**：确认 ADB 二进制嵌入 Tauri App 后能否通过 macOS 15 公证，以及 ADB WiFi 连接在真实场景下的可靠性。


## 一、验证环境准备

| 项目 | 要求 |
|---|---|
| macOS 版本 | macOS 15 (Sequoia)，必须是干净环境或全新虚拟机 |
| Xcode | Xcode Command Line Tools 已安装 |
| Rust | stable 工具链 |
| Tauri CLI | v2.x |
| Apple Developer 账号 | 有效的 Developer ID Application 证书 |
| 测试 Android 设备 | 至少覆盖小米/OPPO/三星各一台，Android 版本覆盖 11+ |
| ADB 版本 | 自行编译的静态链接版本（见模块四） |

**关键前提**：所有公证验证必须在**干净环境**中进行。本地开发机的第一方开发者上下文和缓存的公证票据会掩盖签名问题——Voicebox 项目的诊断报告明确指出，干净 Sequoia 虚拟机上的失败在本地开发机上是看不到的。


## 二、模块一：Tauri Sidecar 公证验证（最高优先级）

### 2.1 已知问题

Tauri 的 GitHub Issue #11992 记录了一个明确现象：**只要在 `externalBin` 中添加 1 个或多个 sidecar，macOS 公证就会失败；移除 `externalBin` 后公证立即通过**。该问题已在一个仅打印 “hello world” 的干净二进制上复现，排除了二进制本身逻辑的干扰。

根因在于：Tauri bundler 会用配置的签名身份对每个 `externalBin` 签名，但**不会自动附加 `--options=runtime`（hardened runtime）和 `--timestamp`（安全时间戳），也不会把外层 app 的 entitlements 合并进 sidecar 的签名**。

### 2.2 验证步骤

**Step 1：创建最小 demo**

```bash
yarn create tauri-app
# 选择：SolidJS/React + TypeScript，其他默认
```

**Step 2：创建一个最简单的 sidecar 二进制**

```bash
cargo new test_sidecar --bin
cd test_sidecar
cargo build --release
# 找到 target/release/test_sidecar
# 复制到 src-tauri/binaries/ 并重命名为：
# test_sidecar-aarch64-apple-darwin （Apple Silicon）
# test_sidecar-x86_64-apple-darwin  （Intel）
```

**Step 3：配置 tauri.conf.json**

```json
{
  "bundle": {
    "externalBin": ["binaries/test_sidecar"],
    "macOS": {
      "signingIdentity": "Developer ID Application: Your Name (TEAMID)",
      "hardenedRuntime": true,
      "minimumSystemVersion": "13.0",
      "entitlements": "entitlements.plist"
    }
  }
}
```

创建 `src-tauri/entitlements.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

**Step 4：设置公证环境变量**

```bash
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="your@email.com"
export APPLE_PASSWORD="app-specific-password"
export APPLE_TEAM_ID="TEAMID"
```

**Step 5：构建并观察公证结果**

```bash
yarn tauri build -- --verbose 2>&1 | tee build.log
```

**Step 6：检查 sidecar 签名状态**

```bash
# 查看构建产物中的 sidecar
codesign -dvvv path/to/YourApp.app/Contents/MacOS/test_sidecar

# 预期应看到：
# CodeDirectory ... flags=0x10000(runtime)
# Timestamp=...
# Authority=Developer ID Application: ...
```

**Step 7：在干净环境中验证 Gatekeeper**

```bash
spctl --assess -t open --context context:primary-signature path/to/YourApp.app
```

### 2.3 判断标准

| 结果 | 含义 | 下一步 |
|---|---|---|
| 公证通过 + `spctl` 通过 | sidecar 打包路径可行 | 进入模块二 |
| 公证失败，错误提示 “not signed” 或 “hardened runtime missing” | 确认 Issue #11992 命中 | 执行 2.4 手动重签名 |
| 公证通过但干净环境 `spctl` 失败 | macOS 15 深度校验问题 | 执行 2.4 并检查嵌套签名 |

### 2.4 如果公证失败的 Workaround

**手动重签名 sidecar**（在 `tauri build` 之后，公证之前执行）：

```bash
APP_PATH="path/to/YourApp.app"
TEAM_ID="YOUR_TEAM_ID"

# 对 sidecar 重新签名，附加 hardened runtime 和时间戳
codesign --force --options=runtime --timestamp \
  --entitlements src-tauri/entitlements.plist \
  --sign "Developer ID Application: Your Name ($TEAM_ID)" \
  "$APP_PATH/Contents/MacOS/test_sidecar"

# 对嵌套的 .dylib 逐个签名（如果 ADB 依赖动态库）
find "$APP_PATH" -name "*.dylib" -o -name "*.so" | while read f; do
  codesign --force --options=runtime --timestamp \
    --sign "Developer ID Application: Your Name ($TEAM_ID)" "$f"
done

# 对最外层 App 签名
codesign --force --options=runtime --timestamp \
  --entitlements src-tauri/entitlements.plist \
  --sign "Developer ID Application: Your Name ($TEAM_ID)" "$APP_PATH"

# 验证
codesign --verify --deep --strict "$APP_PATH"

# 重新提交公证
xcrun notarytool submit YourApp.dmg \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait
```

Tauri 的讨论区 #12001 指出，对于动态库，可以使用 Tauri 的 **macOS Frameworks 机制**替代 `externalBin`——通过 `tauri.conf.json` 中的 `frameworks` 字段声明 dylib，Tauri 会在构建时对它们签名，公证即可通过。如果 ADB 的依赖库较多，这是一个更干净的替代方案。


## 三、模块二：macOS 15 Sequoia 深度校验验证

### 3.1 背景

Voicebox 项目的诊断文档记录了一个关键发现：**macOS 15 对嵌套 Mach-O 二进制执行了三项 macOS 14 不会执行的深度校验**：

1. **hardened-runtime 签名必须有 secure timestamp**。无时间戳的签名在 macOS 14 上通过，在 15 上失败。
2. **对嵌套 Mach-O 做深度校验**。任何内嵌 `.dylib` 或 helper 二进制带着 ad-hoc 签名（或不同 Team ID 的签名）都会让整个 bundle 被 macOS 15 拒绝。
3. **hardened runtime 必须设在每一个嵌套可执行文件上**，而不只是顶层 app 二进制。声明在外层 app 上的 entitlements 不会向下传播。

这意味着即使模块一的公证在 macOS 14 上通过，仍然需要在**干净的 macOS 15 环境**中验证 `spctl --assess -t open`。

### 3.2 验证步骤

在模块一构建成功后，在一台**从未安装过该 App** 的 macOS 15 机器或全新虚拟机中：

```bash
# 1. 挂载 DMG
hdiutil attach YourApp.dmg

# 2. 复制到 /Applications
cp -R /Volumes/YourApp/YourApp.app /Applications/

# 3. 卸载 DMG
hdiutil detach /Volumes/YourApp

# 4. 执行 Gatekeeper 首次启动策略
spctl --assess -t open --context context:primary-signature /Applications/YourApp.app

# 5. 直接双击打开，观察是否被拦截
open /Applications/YourApp.app
```

### 3.3 判断标准

- `spctl` 输出 `accepted` → 通过
- 输出 `rejected` 或 `source=no usable signature` → 未通过，需要检查每一个嵌套二进制的签名
- 双击打开时出现“无法验证开发者”对话框 → 未通过

**诊断命令**：

```bash
# 列出 bundle 内所有 Mach-O 文件及其签名状态
find /Applications/YourApp.app -type f -exec file {} \; | grep "Mach-O"
find /Applications/YourApp.app -type f -exec codesign -dvvv {} \; 2>&1 | grep -E "(flags|Timestamp|Authority|Identifier)"
```


## 四、模块三：ADB 静态链接编译与依赖验证

### 4.1 问题

ADB 在 macOS 上的预编译版本（来自 Android SDK Platform Tools）不是静态链接的，它依赖若干系统 dylib。这些依赖在公证场景下会带来两个问题：

1. 如果使用 SDK 中的预编译 ADB，**分发许可存在法律风险**（SDK Terms & Conditions 第 3.3 条禁止再分发 SDK 的任何部分）。
2. 动态链接的 ADB 二进制在公证时，其依赖的 dylib 也需要被正确签名。

### 4.2 验证步骤

**方案 A：使用现成的静态构建工具链**

社区有若干 ADB 独立构建项目，例如 `karfield/adb`（使用 autotools）和 `stevenrao/adb-proj`（支持 x86_64 和 arm64）。但这些项目年代较久，需要验证其对当前 ADB 版本的支持。

**方案 B：从 AOSP 源码构建**

```bash
# 克隆 ADB 源码（AOSP mirror 中的 adb 目录）
git clone https://github.com/aosp-mirror/platform_system_core.git
cd platform_system_core/adb

# 使用 CMake 独立构建
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.ncpu)
```

社区已有基于 CMake 的独立构建方案，支持 Linux、Windows 和 macOS。

**Step 3：验证链接类型**

```bash
otool -L path/to/adb
```

如果输出中除 `/usr/lib/libSystem.B.dylib` 和 `/usr/lib/libc++.1.dylib` 外还有其他非系统路径的依赖，则需要将这些库一并打包或改为静态链接。

**Step 4：验证功能**

```bash
path/to/adb --version
path/to/adb start-server
path/to/adb devices
```


## 五、模块四：ADB WiFi 连接可靠性验证

### 5.1 已知问题

**Android 11+ 的无线调试端口是随机的**。每次切换无线调试开关，Android 都会分配一个新的随机端口（范围 30000–49999），配对信息中不包含连接端口。设备断开后，旧的 `ip:port` 可能永久失效。

**`adb tcpip 5555` 是更可靠的替代方案**。该命令将手机上的 adbd 重启为监听固定端口 5555 的模式，端口在手机重启前保持不变。但注意：执行 `adb tcpip 5555` 后，Android 11+ 的“无线调试”开关会被关闭，设备将不再出现在无线调试配对列表中。

**Android 17 引入了 ADB Wi-Fi 2.0**，用约 4000 行 Rust 重写了无线连接层，自动记忆并重连可信网络，稳定性显著提升。但这依赖于 App 内置的 ADB 版本足够新，且对 Android 10–12 的支持情况尚不明确。

### 5.2 验证步骤

**Step 1：`tcpip 5555` 模式验证**

```bash
# 通过 USB 连接手机
adb devices  # 确认 USB 连接

# 切换到固定端口模式
adb tcpip 5555

# 拔掉 USB 线，通过 WiFi 连接
adb connect <phone-ip>:5555

# 验证
adb devices
```

**Step 2：断开后重连验证**

执行以下操作，每次操作后尝试 `adb connect <phone-ip>:5555`，记录是否成功：

| 操作 | 预期结果 |
|---|---|
| 手机息屏 5 分钟 | 端口保持 5555，重连成功 |
| 手机切换 WiFi 网络 | 需使用新 IP，端口保持 5555 |
| 手机开启省电模式 | 可能断连，重连需检查是否成功 |
| 手机重启 | **端口失效**，需要重新 USB 连接并执行 `adb tcpip 5555` |
| 路由器开启 AP 隔离 | 无法连接 |

**Step 3：随机端口模式验证（Android 11+ 无线调试）**

```bash
# 在手机上开启无线调试，记录显示的 IP 和端口
adb pair <ip>:<pairing-port> <pairing-code>
adb connect <ip>:<connect-port>

# 然后：关闭无线调试，再重新打开
# 观察端口是否变化，旧端口是否还能连接
```

### 5.3 判断标准

- `tcpip 5555` 模式下，**除手机重启外**的所有场景应能在 3 次重试内恢复连接 → 通过
- 手机重启后需要 USB 重新激活 → 这是已知限制，需要在 App 中提供引导
- 随机端口模式下，端口在切换后变化 → 这是 Android 11+ 的设计行为，App 应避免依赖此模式


## 六、模块五：ADB 动态库打包验证

如果 ADB 不是完全静态链接的，需要验证其依赖的 dylib 能否被正确打包和签名。

### 6.1 验证步骤

```bash
# 查看 ADB 的动态库依赖
otool -L path/to/adb

# 模拟 Tauri 打包后，检查 App bundle 中的 ADB 及其依赖
find /Applications/YourApp.app -name "adb*" -exec otool -L {} \;

# 检查每个依赖是否存在于 bundle 中，或是否指向系统路径
```

### 6.2 如果存在非系统依赖

如果 ADB 依赖了非系统路径的 dylib（例如 `libcrypto.dylib`、`libssl.dylib`），有两种处理方式：

**方式 A：静态链接**。在编译 ADB 时，将依赖库静态链接进 ADB 二进制。这是最干净的方案。

**方式 B：使用 Tauri Frameworks**。将依赖的 dylib 放入 Tauri 的 `frameworks` 目录，Tauri 会在构建时对它们签名。但这种方式在跨平台打包时需要额外处理。


## 七、完整测试 Demo 的配置参考

### 7.1 推荐的 `tauri.conf.json` 关键配置

```json
{
  "bundle": {
    "externalBin": ["binaries/adb"],
    "macOS": {
      "signingIdentity": "Developer ID Application: Your Name (TEAMID)",
      "hardenedRuntime": true,
      "minimumSystemVersion": "13.0",
      "entitlements": "entitlements.plist"
    }
  }
}
```

### 7.2 `entitlements.sidecar.plist`（sidecar 专用）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.cs.debugger</key>
    <true/>
</dict>
</plist>
```

### 7.3 构建脚本中的签名顺序

关键的签名顺序：**sidecar → 嵌套 dylib → 最外层 App → DMG → 公证 → staple**。顺序错误会导致签名链断裂。


## 八、风险检查清单

| # | 验证项 | 通过标准 | 风险等级 |
|---|---|---|---|
| 1 | Sidecar 公证（macOS 15 干净环境） | 公证通过 + `spctl` accepted | 极高 |
| 2 | Sidecar 签名包含 hardened runtime | `codesign -dvvv` 显示 `flags=0x10000(runtime)` | 极高 |
| 3 | Sidecar 签名包含 secure timestamp | `codesign -dvvv` 显示 `Timestamp=` | 高 |
| 4 | ADB 无外部动态库依赖 | `otool -L` 仅显示系统路径 | 高 |
| 5 | `adb tcpip 5555` 息屏后重连 | 3 次重试内成功 | 中 |
| 6 | `adb tcpip 5555` 手机重启后状态 | 端口失效，需 USB 重新激活 | 中（已知限制） |
| 7 | Universal Binary 构建（arm64 + x86_64） | 两份架构的 sidecar 均通过公证 | 中 |
| 8 | ADB 二进制体积 | DMG 总大小 ≤ 40MB | 低 |
| 9 | 5037 端口冲突处理 | App 启动时能检测并提示 | 低 |

### 建议的执行顺序

1. **第 1 天**：模块一（sidecar 公证）+ 模块二（macOS 15 深度校验）——这是 Go/No-Go 决策点
2. **第 2 天**：模块三（ADB 静态编译）+ 模块五（动态库打包）
3. **第 3 天**：模块四（WiFi 可靠性）——需要真实 Android 设备

**如果模块一和二无法通过**，整个 sidecar 方案需要重新评估。备选方案包括：（1）引导用户自行安装 ADB（放弃“零配置”卖点）；（2）使用 Tauri 的 Frameworks 机制替代 `externalBin`（见讨论 #12001 的 workaround）；（3）改用其他传输协议（如基于 `libmtp` 的自行实现，但需要自行处理 macOS 的 `ptpcamerad` 抢占问题）。