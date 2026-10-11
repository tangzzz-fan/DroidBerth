# DroidBerth 工程笔记（从 README 下沉）

| 项        | 值                                                                          |
| -------- | -------------------------------------------------------------------------- |
| 日期       | 2026-10-11                                                                 |
| 为什么有这份文件 | README 原本 800+ 行，把「第一次看到这个仓库要做什么」和「踩过的坑」混在一起。**README 只留入口与契约，工程细节全部收到这里** |
| 读者       | 改这个仓库的人（含未来的我）                                                             |

---

## 1. 构建

### 1.1 前置条件

- macOS 14+，Apple Silicon（v1 不发 Intel，PRD §5.1）
- Xcode（含命令行工具）
- [xcodegen](https://github.com/yonaskolb/XcodeGen) 2.46.0
- Rust 工具链（`scripts/env.sh` 会注入 `RUSTUP_HOME` / `CARGO_HOME`）
- Developer ID 证书（只有签名 / 公证相关步骤需要）

### 1.2 新克隆的仓库：先取一次 adb

```bash
./scripts/fetch-adb.sh
```

`vendor/` 被 `.gitignore` **刻意**排除（体积大 + 许可状态待确认，PRD §28），所以新克隆里**没有 adb**，  
而构建需要它。脚本从 Google 官方源取 **platform-tools r37.0.1**，校验 zip 与解出来的 `adb` 两道 sha256。

> 为什么钉死版本而不用 `-latest`：adb 版本不一致会**静默改变行为**（`doctor` 的 `adb.port_5037`  
> 就是为这个存在的），而项目里所有验收结论都是对着 `37.0.1-15733141` 那一份做的。  
> Google 若重新打包同一版本，校验会**明确报错**而不是静默换掉 —— 更新 pin 前请先重跑设备端验收。

### 1.3 分步构建（等价于 `build.sh`，便于调试）

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

两条容易踩的：

- **图标与 NOTICE 这两步必须在 `xcodegen generate` 之前** —— xcodegen 要求 `project.yml` 里列出的  
  路径**存在**，缺了 `macos/Resources/icon.icns` 或 `Resources/NOTICE.txt` 它会直接报错。  
  图标那步纯 Python 渲染 1024 母版约 50 秒，所以只在 `make-icon.py` 比产物新时才重跑。
- **`USER=$(id -un)` 不是装饰**：某些 shell 环境里 `USER` 未设置，XcodeGen 会报  
  `Couldn't find current username` 且**静默不生成工程**。

### 1.4 产物路径有两处，核对启动时间再下结论

仓库会同时存在 `macos/build/Release/` 与 `macos/build/dd/Build/Products/Release/`。  
**验证 UI 改动前先核对进程启动时间是否晚于源码 mtime**，否则会看着旧二进制下结论 —— 这个坑真实踩到过。

### 1.5 逃逸参数 `-Xfrontend -disable-sandbox`（**随时可能在需要与不需要之间切换**）

**只加在命令行上，绝不写进 `build.sh` 或工程文件**：

```bash
# swiftc
-Xfrontend -disable-sandbox
# xcodebuild（经 build.sh 的口子，xcodebuild 不认环境变量为 build setting）
XCODEBUILD_ARGS="OTHER_SWIFT_FLAGS=-disable-sandbox" ./scripts/build.sh
```

> ⚠️ 这条的**状态在同一天里翻过一次**，两次都是实测：
>
> | 时刻 | 不带参数的结果 |
> | --- | --- |
> | 2026-10-12 **06:20** | `swiftc -typecheck` 与完整 `build.sh` 都**通过**，日志里 `sandbox_apply` / `malformed response` 一条都没有 |
> | 2026-10-12 **07:08** | `sandbox-exec: sandbox_apply: Operation not permitted` + `'ObservationMacros.ObservableMacro' could not be found … produced malformed response` —— **必须加** |
>
> 中间**没有任何人改过配置**，只是会话的沙盒策略翻了回去（见 §10.1）。
>
> ⇒ 结论既不是「需要」也不是「不需要」，而是「**它随时可能在两种状态之间切换**」。
> 所以**自动判断这件事本身是承重的**：常量加、常量不加，都会在某一半时间里是错的。
> `check-all.sh` 里的 `sandbox_escape_args()` 就是那个判断，实测它与真实需求**同步** ——
> 判据返回 71 的那些时刻，上面那段 `malformed response` 必然出现。

---

## 2. 在 Xcode 里调试（attach 被拒 = 两个独立开关）

打开 `macos/DroidBerth.xcodeproj`，scheme 的 Run 用 **Debug**。两个前置条件：

1. **Debug 必须带 `com.apple.security.get-task-allow`** —— 调试器 attach 的许可票。  
   `project.yml` 里它是**按配置**声明的：Debug `YES`、Release `NO`。  
   Release 绝不能带 —— 带它的包**无法公证**，会直接把公证链断掉。
   ```bash
   # 自检：Debug 应有 4 项、Release 应有 3 项（没有 get-task-allow）
   codesign -d --entitlements - macos/build/dd/Build/Products/Debug/DroidBerth.app
   codesign -d --entitlements - macos/build/dd/Build/Products/Release/DroidBerth.app
   ```
2. **系统开发者模式**。若 Xcode 报 `Not allowed to attach to process`：
   ```bash
   DevToolsSecurity -status              # 应为 "Developer mode is currently enabled."
   sudo DevToolsSecurity -enable         # 需要管理员密码
   ```

> 这两条是**两个独立的开关**，都关着时症状完全一样（`IDEDebugSessionErrorDomain Code 6` /  
> `DBGLLDBLauncher`），排查时两条都要看。  
> 另：`log show` 在应用的受限沙箱里跑不了（`Cannot run while sandboxed`），拿不到 taskgated 的拒绝日志 ——  
> 别在这上面浪费轮次，直接用上面两条判据。

---

## 3. 图标不生效 / Dock 上还是旧图标

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
`grep` 出来一眼可见；清掉幽灵记录 + `killall Dock` 之后 `NSRunningApplication.icon` 就返回了品牌橙底板。

> **别在 `/tmp` 里留 app 副本**（会进 LaunchServices，成为下一个幽灵记录）。  
> 判断「Dock 到底拿到了什么图标」**不要靠截图** —— 跑现成的诊断脚本：

```bash
mkdir -p /tmp/dockicon && cp scripts/diagnose-dock-icon.swift /tmp/dockicon/main.swift
swiftc -O -o /tmp/dockicon/run -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 6 -strict-concurrency=complete -Xfrontend -disable-sandbox \
  /tmp/dockicon/main.swift && /tmp/dockicon/run
```

> 它读的是 **`NSRunningApplication.icon`** —— Dock 用的那个值：通用应用图标是白/灰，  
> 本项目的图标在 `(w/4, h/2)` 处是 `(240,151,67)` 品牌橙（**正中反而是白的**，因为两块白面板在中间接缝）。

---

## 4. 编译验证与回归守卫

### 4.1 只验 Swift 侧（不需要 Rust 工具链 / adb，约 11 秒）

```bash
swiftc -typecheck -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 6 -strict-concurrency=complete -parse-as-library \
  $(find macos/Sources -name '*.swift')
```

去掉 `-typecheck` 换成 `-o /tmp/x` 还能顺带验证链接（能确认 `_QuickLook_SwiftUI` 这类  
Swift overlay 框架被正确自动链接）。

### 4.2 四个回归守卫（+ 一道 shell 静态检查）

统一入口 `./scripts/check-all.sh`（**先构建** —— 第四个守卫会驱动 app 自己的导出命令）。

| 守卫                         | 守什么                       | 为什么编译器不管                                    |
| -------------------------- | ------------------------- | ------------------------------------------- |
| **shell 静态检查**（第 0 道）      | `$VAR` 后面紧跟非 ASCII 字符     | bash 3.2 会把全角标点**算进变量名** ⇒ 运行时才 `unbound variable`。本项目脚本全中文，天天会撞     |
| `check-icon-mapping`       | 同一扩展名在两栏（Mac / 设备）得到同一个符号 | 「**静默分叉**」：两处 switch 各写一遍，`.apk` 在一边变通用文稿   |
| `check-grid-navigation`    | 网格的顺序 / 列数 / 方向键落点 / 字母跳转 | 视图排一次序、键盘再排一次，误差不报错也不崩，只会**让 ↓ 跳到肉眼看不见的地方** |
| `check-transfer-semantics` | 折叠规则、冲突改名、名称校验、缩略图范围      | 错的方向会让**用户手机上的文件被静默覆盖**                     |
| `check-diagnostics-bundle` | 诊断包条目数 / 中文名编码 / 无隐私泄露    | 「**产物打开来才发现**」——曾经产出过一个只有根目录的空包             |

单独跑一个（各自约 5 秒）—— 以网格导航为例：

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

> 脚本必须叫 `main.swift`（顶层代码只允许在这个文件名里），helper 要标 `@MainActor`  
> （Swift 6 下顶层代码是 MainActor 隔离的）。别的守卫的依赖文件见 `scripts/check-all.sh`。

**CI 每次 push 都会跑 `check-all.sh`；本地不会** —— 改完记得自己跑一次。

### 4.3 验证面板（`--spike-report`）

```bash
build/dd/Build/Products/Release/DroidBerth.app/Contents/MacOS/DroidBerth --spike-report
```

**它把报告打在 stdout 然后 `exit(0)`** —— 所以可以管道、可以重定向，但**不会**自己写文件。  
写 JSON 到 `~/DroidBerth-reports/spike-<timestamp>.json` 的是 app 里的**验证面板**，那条路要开 GUI。

四项判据 `V1`（sidecar 定位）/ `V2`（签名链 `doctor`）/ `V3`（进程封装）/  
`V4`（端到端：`push` → `ls -l` 复核 → `rm`）。**`V4` 在没有设备时标 `manual`**：

```
SUMMARY: V1=pass V2=fail V3=pass V4=pass      # 接上 Android 模拟器时的实测结果
```

`V2` 在 MVP 阶段**必然 fail** 两项（未公证、未装进 `/Applications`）—— 那是发布前动作，不是缺陷。

---

## 5. 签名与公证

```bash
./scripts/checklist.sh                    # sidecar 的 14 项自检
./scripts/notarize.sh                     # zip → 公证 → staple → 出 DMG → 公证 DMG
./scripts/resign.sh                       # 需要在 Xcode 之外重签时用
./scripts/verify-clean.sh <dmg> --apply --replace --quarantine
```

三条踩过的：

- **app zip 用 `zip -X -y`，不用 `ditto -c -k`**：源文件带 `com.apple.provenance` 时 ditto 会给每个成员  
  写 `._<名字>` 边车（`--norsrc --noextattr` 与先 `xattr -cr` **都拦不住**，实测 13 个）。  
  去扩展属性**不破坏签名**。
- **DMG 走 `scripts/env.sh` 的 `make_signed_dmg()`**，它用 `ditto`（不是 `cp -R` —— 后者不保留扩展属性，  
  实测那样拷出来的副本 `spctl` 会判 `rejected / Insufficient Context`），并往 DMG 里放一条  
  `/Applications` 符号链接。**禁止手写 `hdiutil create`**。
- **`resign.sh` 只给 app 签 entitlements，sidecar 不带** —— Xcode 不会把 app 的 entitlements  
  转发给 Copy Files 进来的文件（`0926_02` §10 实测）。

---

## 6. CI 签名（可选路径，默认不用）

正式发版走本机（见 README）。`.github/workflows/release.yml` 保留为可选路径，  
**刻意只有 `workflow_dispatch`** —— 否则每次打 tag 都会跑出一个缺 secret 的失败 job。

要启用，**别裸传凭据**，先做掉这几件：

1. **secret 放进 Environment 并设 required reviewers**（比如叫 `release`）——  
   这样任何 workflow 引用它之前都必须人工批准，「偷推一个 workflow」就不能静默取用。  
   本仓库当前 **environment 数 = 0**，等于完全没有闸门。
2. **action 钉 commit SHA** 而不是 tag（tag 可以被移动）。
3. 优先用 **App Store Connect API key** 而不是 Apple ID 的 app-specific password。  
   ⚠️ `scripts/env.sh` 与 `build.sh` 已经预留了 `APPLE_API_KEY` / `APPLE_API_ISSUER`，  
   但 `scripts/notarize.sh` 目前只实现了 profile 与 Apple ID 两条路，要用得先补。
4. **恢复 `release.yml` 的 tag 触发器**：
   ```yaml
   on:
     push:
       tags: ["v*"]
     workflow_dispatch:
   ```

**6 个 secret**（`release.yml` 第一步会逐个检查并报出缺哪个）：

| Secret                        | 是什么                                     | 从哪来                            |
| ----------------------------- | --------------------------------------- | ------------------------------ |
| `BUILD_CERTIFICATE_BASE64`    | Developer ID 证书的 `.p12`，base64 后的**单行** | `base64 -i cert.p12 \| pbcopy` |
| `P12_PASSWORD`                | 导出 `.p12` 时设的密码                         | 导出时你自己设的                       |
| `KEYCHAIN_PASSWORD`           | 任意随机串；CI 上临时钥匙串的密码                      | 随便编一个                          |
| `APPLE_ID`                    | Apple ID 邮箱                             | `.env` 里已有                     |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password                   | `.env` 里已有                     |
| `APPLE_TEAM_ID`               | 10 位 Team ID                            | `UKXWZ3FS84`                   |

一条命令写完：`./scripts/setup-release-secrets.sh --p12 ~/Desktop/证书.p12`  
（脚本只搬本机已有的凭据，不生成、不打印任何凭据值）。

> ⚠️ **导出 `.p12` 时只选 Developer ID 那一张**，不要「导出所有项目」。本项目实测  
> `security export -t identities` 能无 GUI 导出，但会带出**三个身份**  
> （Apple Development / Apple Distribution / Developer ID）—— CI 只需要 Developer ID 那一把。
>
> 变量名对不上是刻意的：secret 叫 `APPLE_APP_SPECIFIC_PASSWORD`，流水线里映射成环境变量  
> `APPLE_PASSWORD` —— 因为 `scripts/notarize.sh` 读的是 `APPLE_ID` / `APPLE_PASSWORD` / `APPLE_TEAM_ID`。

### runner 的选择

用 `macos-15`：在公开仓库上这个 label 就是 **Apple Silicon**，而本项目只发 arm64  
（`ARCHS: arm64` 写死在 `project.yml`）—— 换成 `macos-15-large` 会拿到 Intel。  
若某天编译在新版 Xcode 上失败，改 `ci.yml` 与 `release.yml` 各一处 `runs-on:`。

---

## 7. Finder 集成（服务菜单）的细节

在 Finder 里选中文件或文件夹 → 右键 → **服务** → **发送到 DroidBerth**，直接推送到设备。  
落点规则与窗格内上传**用的是同一份判据**（`AppModel.uploadDestination(for:candidateNames:)`）：  
优先「上次使用的目录」，否则按文件类型分流（视频 → `Movies`、图片 → `DCIM`、其它 → `Download`）。  
传输本身也复用 `AppModel.uploadFiles(_:toRemotePath:reason:)`。

> ⚠️ **App 必须装在 `/Applications`（或其子目录）。** Apple 对 services 的要求原文是  
> *"install it in the Applications folder (or a subfolder)"*。实测确实能观察到「登记路径跟着  
> LaunchServices 里当前那份走」——第一次登记到的是构建目录里的副本，注销后才是 `/Applications`。  
> 装完若菜单里没出现：`/System/Library/CoreServices/pbs -update` 触发重扫  
> （`pbs` 在 macOS 27 上参数已变，**不是**老文档里的 `-dump_pboard`）；仍不出现就注销重新登录 ——  
> 服务列表是在**登录时**构建的。


> ⚠️ **别留同 bundle id 的第二份副本**（服务按 LaunchServices 记录路由，会路由到错的那一份 ——  
> 与「图标不生效」同一类）。自检：
>
> ```bash
> /System/Library/CoreServices/pbs -dump | grep -A9 -i droidberth   # 看 NSBundlePath
> ```

**已验证 / 未验证**（2026-10-11 实测）：

| 项                                       | 结果                                                     |
| --------------------------------------- | ------------------------------------------------------ |
| `NSServices` 声明被系统登记                    | ✅ `pbs -dump` 里有 `NSMessage` / `NSSendFileTypes` / 菜单项 |
| `NSPerformService("发送到 DroidBerth", …)` | ✅ 返回 `true`                                            |
| 消息送达 provider 并解析出文件                    | ✅ App 运行时实测：`sendToDevice 解析出 1 个项目`                   |
| 交给 `AppModel` 之后的链路                     | ✅ 走到「正在等待设备」→（无设备时）20 秒后「没有可用的设备」                      |
| 真实上传到设备                                 | ❌ 未验证（测试时没有设备连着）                                       |
| **App 未运行时由系统按 `NSPortName` 拉起**        | ❓ **未定论**：三次尝试只有一次真的把 App 拉起来了。**别断言它可用**              |

> 排查时最有用的一条：`sendToDevice` 里**没有错误可以外传**（services 的失败只表现为「点了没反应」），  
> 所以它落了一行日志，把「没送达」与「送达了但解析出 0 个文件」分开 —— 日志在 `~/Library/Logs/DroidBerth/`。

---

## 8. 「别做」清单（都是踩过的）

| 别做                                  | 为什么                                                                                                           |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| 用环境变量给 `xcodebuild` 传 build setting | 实测：`CODE_SIGN_IDENTITY=- xcodebuild …` 仍用钥匙串里的真证书签；只有**命令行参数**可靠 ⇒ `build.sh` 的 `XCODEBUILD_ARGS` 口子          |
| 写 `"${ARR[@]}"`                     | bash 3.2 + `set -u` 下**空数组**会报 unbound（4.4 起才修）⇒ 写 `"${ARR[@]+"${ARR[@]}"}"`。`build.sh` 的默认路径就踩过              |
| 用 `cmd \| grep …` 的退出码判成败           | 退出码是 **grep** 的，会把失败盖住（因此误报过一次「已验证」）。输出落文件、退出码单独取                                                             |
| 新增源文件后直接构建                          | 会报 `cannot find 'X' in scope` + 同文件一个 `failed to produce diagnostic` —— 看着完全不像缺文件。**先重跑 `xcodegen generate`** |
| 在报错的文件里找 `self is immutable`        | 真错误常在**别的文件**。先跑全量 `swiftc -typecheck`，它会给真正的文件与行号                                                            |
| 用 `sips -z` 缩图标                     | 会得到糊的 16pt 档。要 2×2 面积平均，且**必须在预乘 alpha 空间**（`make-icon.py` 已实现）                                               |
| 用 `ps -o args=` 判进程                 | 它会截断，`grep "MacOS/DroidBerth$"` 永远匹配不到。用 `pgrep -fl`，杀之前先打 pid 与 args                                         |
| shell 里写 `"$VAR，"`                  | macOS 的 bash 3.2 会把全角标点的字节算进变量名 ⇒ `unbound variable`。写 `${VAR}，`。**已从「靠记得」升级成 `check-all.sh` 的第 0 道守卫**（静态扫 `scripts/*.sh`）                              |
| 在 `unzip -l` 里判中文名编码                | macOS 的 `unzip` 不认 EFS 标志，照样显示乱码，**但解压到磁盘是对的**。自研 ZIP 的中文名要显式置 EFS `0x0800`                                   |
| 拿 `sm list-volumes` 枚举设备卷           | vold 旧接口，Android 10+ 已限制。用 `ls /storage/`                                                                     |
| 拿 `/Users/` 前缀当「隐私泄露」判据        | **系统崩溃报告 `.ips` 自己就会匿名化**：实测里面的形态是 `\/Users\/USER\/*\/DroidBerth.app\/…`（用户名→字面量 `USER`、中间层→`*`）。按 `/Users/` 判，会让「用户机器上崩过一次」永远 FAIL —— **持续误报等于没有判据**。判据要落在**真实**家目录路径（含 `\/` 转义形态）与**真实**用户名上 |
| 用子串匹配判 hardened runtime            | runtime 是 CodeDirectory 的 **`0x10000` 这一位**。ad-hoc 签名的构建是 `flags=0x10002(adhoc,runtime)`，**不含子串 `10000`** ⇒ grep 会把 ad-hoc 构建误报成「没开 hardened runtime」（本项目第一次跑就中招，同一个包从全 PASS 变成 FAIL）。**位掩码判**，别 grep |
| 从**受限会话**的子进程启动沙盒 app         | 症状是 **`exit 133`（SIGTRAP）+ 一行输出都没有**，`.ips` 里栈顶是 `libsystem_secinit.dylib _libsecinit_appsandbox` —— **沙盒初始化失败**，不是 app 坏了。**用 `open`（LaunchServices）或 Finder 启动**：那样 app 由 launchd 拉起，不继承你所在进程的沙盒 |
| 把「本会话能不能施加限制性沙盒」当**稳定**事实 | **同一台机器、同一天会话内都会变**：2026-10-12 06:20 判据返回 **0**、06:41 返回 **71**。⇒ 每次验沙盒前**现测一次**，别引用上一轮结论 |

---

## 10. 沙盒进程与「受限会话」—— 一条被推翻的结论

> ⚠️ **本节 2026-10-11 的版本是错的，2026-10-12 已推翻重写。** 保留这段是因为它是个好教材：
> **判据错一个方向，会把整条路白否掉。**

2026-10-11 写过「受限会话不允许再往下施加限制性沙盒 profile ⇒ 本机 agent 会话做不了沙盒验证」，
判据是：

```bash
sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok   # 退出码 71
```

**真因不是嵌套限制，是这份 profile 自己有问题**：它**没有 `allow process-exec`**，
而 `sandbox-exec` 施加完 profile **还要 exec 目标程序**。也就是说 profile 施加成功了、
随即拒绝了 exec —— 症状与「施加不了」一模一样。补上 `allow process-exec` 后同一条命令退出码 0：

```bash
sandbox-exec -p '(version 1)(deny default)(allow file-read*)(allow process-exec)' /usr/bin/true  # 0
```

第二个坑：被施加的程序一度写成 `/bin/true` —— **macOS 没有这个路径**（那是 Linux），
是 `/usr/bin/true`。路径写错同样报 71、同样报 `execvp() … failed`。
**一条六行的探针连错两次，两次都指向同一个错结论。**

⇒ 正确结论：**本机 agent 会话完全可以验沙盒行为。** `scripts/spike-sandbox-adb.sh` 的沙盒版
当场跑出 S1-a / S1-b PASS（判据自检「沙盒生效 = 是」）。App Store 那条路没有被这个环境卡住。

它连带否掉的推论：**「本机构建需要 `-Xfrontend -disable-sandbox`」也不成立**。
2026-10-12 实测完整 `build.sh`（`xcodebuild`）不带该参数 ⇒ `BUILD SUCCEEDED`，
日志里 `sandbox_apply` / `malformed response` 一条都没有；`swiftc -typecheck` 同理。
`check-all.sh` 与探针里的逃逸探测**保留**（探测不命中时零影响，万一真在受限环境里跑还能兜一下），
但**必要性未被证实**，已在两处注释里如实标注。

**仍然成立的两条**（与上面无关，别一起丢掉）：

- 被沙盒化的进程若在**启动阶段**被杀，会**一行输出都没有**（信号直接带走 stdio 缓冲，
  而 `print` 在管道下面是块缓冲的）。所以「没有输出」**不能**推出任何关于沙盒策略的结论 ——
  探针必须自己打印「我到底有没有被沙盒化」。
- 验沙盒**必须有对照组**（同一段代码、不带沙盒的另一个 bundle）。只测沙盒版时，
  「adb 失败」既可能是沙盒挡的、也可能是探针打包错了，**分不清的两件事等于没测**。

### 10.1 那条判据**不稳定** —— 每次都要现测

补一条 2026-10-12 晚些时候才发现的：**同一台机器、同一天、同一个会话里，那条判据会变。**

```
06:20  sandbox-exec -p '(version 1)(deny default)(allow file-read*)(allow process-exec)' /usr/bin/true  → 0
06:41  同一条命令                                                                                          → 71
07:08  同一条命令                                                                                          → 71
```

而且**后果也跟着翻**：06:20 时 `swiftc` 不带逃逸参数能过；07:08 时同样的构建就在
`swift-plugin-server` 上炸出 `malformed response`（§1.5）。⇒ 「需不需要逃逸参数」不是配置问题，
**是会话状态问题**。

06:20 时沙盒版探针跑通、S1-a/S1-b PASS；06:41 之后连探针自己都跑不起来，而中间**谁也没改过任何配置**
（跨了一个回合）。⇒ 这是**会话环境的策略变化**，不是我们的代码或工程配置。

后果与对策：

- **不要引用「上次测过」的结论** —— 每次验沙盒前先跑一次判据。
- 探针脚本已内置这条预检，判据不成立时会明说「**本次沙盒版结论无效**」而不是报假 FAIL。
- 这一条也解释了那份误以为「环境做不了沙盒验证」的原始结论：它在某些时刻**确实**成立，
  但它**不是**稳定事实 —— 把一时一地的观察写成通则，就是最初那个错误的来源。

### 10.2 怎么启动一个沙盒 app 来验它（这条比上面都实用）

**别从 shell 直接跑它的可执行文件**（`"$APP/Contents/MacOS/DroidBerth" --diagnose`）。
在有沙盒限制的会话里，它会：

- **`exit 133`（SIGTRAP）且一行输出都没有**；
- `~/Library/Logs/DiagnosticReports/` 里的 `.ips` 栈顶是
  `libsystem_secinit.dylib — _libsecinit_appsandbox`（**沙盒初始化失败**）。

**这看起来就是「app 被沙盒挡住了」，而它只是被启动方式挡住了。** 正确做法是：

```bash
open "/abs/path/to/DroidBerth.app"        # app 由 launchd 拉起，不继承你所在进程的沙盒
```

本机实测：同一个包，shell 直接跑 → 133 + 无输出；`open` → **正常起来、8 秒后进程仍在、无新崩溃报告**。
两种签名（ad-hoc 与 `Apple Distribution`）都是这个结果。

> ⚠️ 顺带更正一条差点写进方案的结论：**「用 Apple Distribution 签的包本机跑不起来」是错的。**
> 依据是 `spctl -a` 报 `rejected` + shell 跑出 133 —— 前者是 **Gatekeeper 的分发评估**
> （与公证/票据有关，不妨碍本机运行），后者是**启动方式**的问题。实测 `open` 同样能起来。
> 真正需要 profile 的是**提交**，不是本机运行。

### 10.3 怎么**证明**一个 app 真的在沙盒里跑（`lsof` 看 cwd）

「进程活着」不足以证明它跑对了 —— 它可能 hang、可能没进沙盒、也可能进沙盒但写不了东西。
一条命令就能同时回答这三件事：

```bash
open "/abs/path/to/DroidBerth.app"; sleep 6
lsof -p "$(pgrep -f "Release-MAS/DroidBerth" | sed -n '1p')" | grep Containers
```

本机实测（**Apple Distribution 签名 + 无 provisioning profile** 的 MAS 包）：

```
cwd  DIR   /Users/tango/Library/Containers/dev.tango.droidberth/Data
3w   REG  3843  …/Containers/dev.tango.droidberth/Data/Library/Logs/DroidBerth/DroidBerth-2026-10-12.log
```

**三件事一次都成立**：`cwd` 是容器（**沙盒确实生效了**）、日志写在容器里（**没有误写真实家目录**）、
日志有 3843 字节（**它真的在干活，不是 hang 在那里**）。

对照：真实 `~/Library/Logs/DroidBerth/` 整份日志里**只出现过 `Release/`，从来没有 `Release-MAS`**
（用 `grep -n Release-MAS` 数得出来）。这一条把「沙盒版的行为会不会污染真实环境」也一起答了。

> 顺带说明一件事：**沙盒的初始化只看签名里的 entitlements，不要求 provisioning profile。**
> profile 是给**受限** entitlements（`com.apple.developer.*`）与 App Store 校验用的。
> 我们那 7 条都是标准 sandbox 权限，所以「无 profile 也能正常进沙盒」是预期行为，
> 不是侥幸 —— 也正是「无证书即可验行为」这条路成立的原因。

**「不能在本机跑」这个说法从哪来**（三条，前两条是误读、第三条是真的）：

| 说法 | 实际 |
|---|---|
| `spctl -a` 报 `rejected` | 那是 **Gatekeeper 的「能不能分发给别人」评估**，不是「能不能在本机运行」 |
| 从 shell 跑可执行文件 → 133 | **启动方式**问题（§10.2） |
| 真机上游这条说法的**正当**来源 | 给二进制加上**受限** entitlement（`com.apple.developer.*`）却没有对应 profile，内核会在启动时直接 `SIGKILL`（137）。**我们没用到任何受限 entitlement**，所以不落入这一条 |

---

## 11. 截图与 UI 验证（更正「本机无法截图」）

**结论：不是「无法截图」，是缺「屏幕录制」权限。** 这条差别很要紧 —— 前者是死路，后者是**一次授权**。

### 11.1 实测到的边界

| 试什么 | 结果 |
|---|---|
| `command -v screencapture` | ✅ 在（`/usr/sbin/screencapture`） |
| 找窗口（`CGWindowListCopyWindowInfo`）拿 id / 标题 / 边界 | ✅ **不需要任何权限**，实测拿到 `id=7257 bounds=640,144,1396,863` |
| 按窗口 id 抓像素（`screencapture -l <id>`） | ❌ `could not create image from window` |
| 整屏抓（`screencapture -x`） | ❌ `could not create image from display` |
| 把外层沙箱整个摘掉再抓 | ❌ 同样两句 ⇒ **是 TCC，不是沙箱** |
| 读 UI 树（`AXUIElementCopyAttributeValue`） | ❌ `err=-25211`（没有「辅助功能」权限）——**另一条独立的路，也一起被挡** |

⇒ 所以「本机看不到界面」是**权限问题**，不是能力问题。这两条权限任一开，
都能让 UI 这块从「只能人眼」变成「机器可验」。

### 11.2 授权方式

系统设置 → 隐私与安全性：
- **屏幕录制** → 勾上**运行命令的那个 app**（在 WorkBuddy 里跑就勾 WorkBuddy；在自己终端里跑就勾该终端）→ **重启那个 app**。
- （可选）**辅助功能** → 同一个 app。给了它就能读 UI 树，能验的比像素更多（控件文案、层级、状态），
  而且**不受分辨率与窗口遮挡影响**。

### 11.3 工具：`scripts/ui-shot.sh`

```bash
./scripts/ui-shot.sh                    # 默认找 DroidBerth 的窗口
./scripts/ui-shot.sh "<app 名片段>" <输出 png>
```

它做三件事：**按拥有者找主窗口**（`scripts/ui-shot.swift`，`layer == 0` 过滤掉菜单/阴影等附属窗口）
→ `screencapture -x -o -l <id>` **只抓那个窗口**（不抓整屏，避免把无关内容一起吃进来）
→ 打印**大小与像素尺寸**。

**为什么打印尺寸而不只看退出码**：没有权限时 `screencapture` 可能仍产出文件，
只是**窗口内容不在里面** —— 只看退出码会误判成成功。脚本自己也会在失败时
把「该开哪个开关」打出来，不用回来翻文档。

> ⚠️ 截图里会有你的文件名。落在 `reports/`（不入库），**看完就删**。

### 11.4 这件事改变了什么

原先「UI 全部未验收」是**1.0.0 的主阻塞项之一**（路线图 §5 的 A 类、验收清单 20 分钟全靠人眼）。
两条权限里任一条一开，这一块就能变成：**起 app → 截图/读树 → 逐条判据自动核对**。
App Store 那几张「必须是真实运行界面」的截图同理 —— 现在它是一项**可自动化的**工作。

### 11.5 两条路分工：**像素看「长什么样」，UI 树判「数字对不对」**

`scripts/ui-report.swift`（辅助功能 API）打的是 UI 树：角色 / 标题 / 描述 / 值 / 是否可按下。
跟截图是**互补**关系，不是替代：

| 问题 | 该用哪个 |
| --- | --- |
| 排版、配色、图标、对齐、留白 | **截图** |
| 「状态栏写 9 还是 3」「列表里真有几行」「按钮可不可按」 | **UI 树** |

**已经吃过一次教训**：第一轮看沙盒版截图时，我把底部读成「3 个项目」，而列表有 9 行 ——
看着像个「状态栏数字不对」的真 bug，差点写进验收报告。用 UI 树一读是 **「9 个项目」**：
**我在缩小后的位图里把 `9` 看成了 `3`**（侧载那份的 `13 个项目` 同样被我读成 `3`）。

⇒ **数数这类判据一律交给 UI 树**。位图适合判断「像不像」，不适合**读数**。

`ui-report.swift` 还支持 `--press <文字>`：按标题/描述/值含该文字且可 `AXPress` 的元素，
按完等 600 ms 再打一次树 —— 弹层/浮窗是**另一个 window**，所以要对刚取到的窗口列表重新遍历。
用它按过一次工具栏的来源选择器（会打出 `AXMenu` 里的 `Finder 位置` / `照片图库` 两项）。
