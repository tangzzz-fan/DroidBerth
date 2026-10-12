# DroidBerth · 上架 Mac App Store 需要准备什么

| 项 | 值 |
|---|---|
| 日期 | 2026-10-11 |
| 依据 | App Review Guidelines（官方原文）、Apple App Sandbox 文档、App Store Connect 交付要求（各方一致的实施资料） |
| 现状 | 仓库当前形态是 **Developer ID 侧载分发**（DMG + 公证）。本文件只谈如何**新增** MAS 这条渠道 |
| 一句话 | MAS 版不是「现在这个 app 加个沙盒」——沙盒会**改变产品能力**（见 §2.1），所以第一步是拍板，不是写代码 |

> ⚠️ 本文件里凡是**没有官方出处**的判断都标了「**待实测**」或「**待确认**」。
> 不要把它们当成已核实的结论往下推。政策与工具链都在变，提交前请以 App Store Connect 当时的提示为准。

---

## 1. 先认清一件事：这会是**两个不同的构建**

| | 现在这条（侧载） | MAS 那条（新增） |
|---|---|---|
| 签名 | `Developer ID Application` | **`Apple Distribution`**（旧名 Mac App Distribution）+ `Mac Installer Distribution` 签 `.pkg` |
| 公证 | 必须自己跑 `notarytool` + `stapler` | **不需要**——Apple 在审核流程里处理 |
| 沙盒 | 可选 | **强制**（Guideline 2.4.5(i)） |
| 产物 | `.dmg` / `.zip` | **`.pkg`**（`productbuild`），由 Transporter / Xcode Organizer 上传 |
| 更新机制 | 自己发 Release（将来可接 Sparkle） | **必须走 Mac App Store**（2.4.5(vii)）⇒ **Sparkle 不能用** |
| 分发 | GitHub Releases | App Store Connect |

**两个直接影响：**

1. **PRD §27 计划的 Sparkle 2 更新链在 MAS 版上是不允许的。** 原文 2.4.5(vii)：
   *"They must use the Mac App Store to distribute updates; other update mechanisms are not allowed."*
   ⇒ 若同时走两条渠道，侧载版接 Sparkle、MAS 版靠商店更新，是两套逻辑。
2. **用 `Apple Distribution` 签出来的 app 在本机跑不起来**（只能从 MAS 下载）。
   本地自测要用 **`Apple Development` 证书 + development provisioning profile**
   （这就是 `mas-dev` 那种形态），而且这个形态**不会**进 App Store。
   ⇒ 「改一下就能在本地验一遍」是不成立的，得专门配一套调试签名。

---

## 2. 硬约束：官方条款逐条对照本项目

### 2.1 会影响产品能力的三条

| 条款 | 原文要点 | 对本项目意味着什么 |
|---|---|---|
| **2.5.2** | 不得读写 designated container **之外**的数据 | **这是最大的一条。**「浏览 Mac 上任意文件夹」是这个产品的核心体验，而沙盒里默认只能碰容器。要访问用户其它目录，只能靠 `NSOpenPanel` 让用户**亲自选**（`com.apple.security.files.user-selected.read-write`），并且**记住**要落 security-scoped bookmark。⇒ 首次使用会多一步「授权素材目录」，且**不允许默认就在 home 目录起**（现在 `AppModel.localDirectory` 默认是 `homeDirectoryForCurrentUser`） |
| **2.4.5(iii)** | 不得在用户退出 app 后留下**继续运行的进程** | **adb 的 server 是常驻的** —— 它 fork 自己监听 5037，退出 app 后还在。这直接撞条款。⇒ MAS 版必须在退出时 `adb kill-server`，并且**不能**让它在后台偷偷活着。**待实测**：沙盒下 kill 是否总能成功、残留如何自愈 |
| **2.4.5(vii)** | 更新必须走 Mac App Store | 见 §1 —— Sparkle 不能在 MAS 版用 |

### 2.2 沙盒本身（官方文档）

| 事实 | 出处 |
|---|---|
| **App Sandbox 是提交 Mac App Store 的硬性要求** | *"...the App Sandbox Entitlement, which is an App Store requirement for any app that you submit to the Mac App Store for review."* — Apple《Configuring the macOS App Sandbox》 |
| 沙盒**不限制**子进程：**子进程继承父进程的沙盒**，与它自己有没有 entitlement 无关 | Apple 开发者论坛（DTS 的说明） |
| 但 **App Review 要求所有 main executable 都带 `com.apple.security.app-sandbox`**；所以内嵌 helper 要带 **`com.apple.security.inherit`** 来触发继承 | 同上 |
| 容器启动时**不能任意执行 `.app` 之外的二进制** | Apple《Embedding a Command-Line Tool in a Sandboxed App》 |
| 沙盒把文件系统限制在容器内；容器里 `~/Downloads`、`~/Pictures` 等是符号链接，但**访问解析后的真实位置仍要相应 entitlement**，否则报 `Operation not permitted` | 同上 |
| **「所有文件」entitlement（`com.apple.security.files.all`）已标注 Deprecated** | Apple Entitlements 参考 —— 所以**不能**靠一个开关拿到整盘访问权 |

### 2.3 本项目需要的 entitlements（逐条对照代码）

| Entitlement | 为什么需要 | 对应代码 |
|---|---|---|
| `com.apple.security.app-sandbox` | MAS 强制 | `macos/Resources/DroidBerth.entitlements`（**现在没有，要新加**） |
| `com.apple.security.network.client` | adb 连 `localhost:5037`；无线 ADB 连手机 | `Sidecar/ProcessRunner`、`WirelessManager` |
| `com.apple.security.network.server` | **adb server 要监听 5037** | 同上。⚠️ 这条也是 §2.1「常驻进程」那条条款的放大器 |
| `com.apple.security.device.usb` | adb 要通过 IOKit 直接跟 Android 设备对话 | `ADB/ADBBinary`、`DeviceShell`。**官方定义**：*"whether your app may interact with USB devices. macOS 10.7+"*（Hardware → USB） |
| `com.apple.security.files.user-selected.read-write` | 用户选中的素材目录要有读写权 | `AppModel.navigateLocal` / `NSOpenPanel` 那条路 |
| `com.apple.security.assets.pictures.read-*`、`...movies...` | 「照片图库」来源与常用素材目录 | `Photo/PhotoLibraryModel`。**可能可以不要**（走 user-selected 或 PhotoKit）——待确认 |
| `com.apple.security.files.downloads.read-write` | 「下载」这个固定位置 | `LocalFileSystem.places()` |
| **内嵌二进制的继承标记** | `adb` 与 `droidberth-adb` 各自带 `app-sandbox` + `inherit` | `scripts/resign.sh` 现在**只给 app 签**，sidecar 不带 entitlements ⇒ 要新增一套 |

> 现在 `DroidBerth.entitlements` 里那三条（`allow-jit` / `allow-unsigned-executable-memory` /
> `disable-library-validation`）是 **Hardened Runtime 的例外**，不是沙盒权限。
> **要复核它们是否真的还需要** —— Swift 原生 app 通常不需要前两条，而审核更偏好最小权限集。

---

## 3. 五个真实风险（按「会不会让整件事白做」排序）

| # | 风险 | 为什么可能是致命的 | 最低成本的判据 |
|---|---|---|---|
| **R1** | **沙盒下 adb 的 USB 通道能否工作** | `com.apple.security.device.usb` 的官方描述是「通过 USB device access APIs 与 USB 设备交互」。adb 用的是自己的 IOKit 路径，**它是否落在那套 API 的范围内没有官方承诺**。若不行，MAS 版就只能走**无线 ADB**——产品可用性大幅下降（首次连接必须先用别的方式打开 tcpip） | 写一个最小沙盒 app（`app-sandbox` + `device.usb`），在里面跑我们内嵌的 `adb devices -l`，插一台真机看能否列出 |
| **R2** | **「浏览任意目录」这个核心体验与沙盒的冲突** | 沙盒要求用户逐个授权目录（user-selected + bookmark）。摄影师场景是「一个几百 GB 的项目文件夹」——**一次授权是可以接受的**；但「像 Finder 一样上下乱逛」不行。这会改变 PRD §3 的产品定位 | 不需要实验，**需要你拍板**：接受「首次授权素材目录」这个前提吗？ |
| **R3** | **adb server 常驻违背 2.4.5(iii)** | 条款原文明确禁止「用户退出后仍继续运行的进程」。adb server 天然如此 | 实测：退出时 `adb kill-server` 是否可靠；以及**连接期间** adb server 属于「我们起的、我们负责收」——把生命周期写进代码即可。这条**可以工程解决**，不是死结 |
| **R4** | **内嵌第三方二进制（adb）的许可与审核表述** | `adb` 是 Apache-2.0（`NOTICE.txt` 已随包），沙盒下自包含在 bundle 内，形式上符合 2.4.5(ii)「self-contained、不往共享位置装东西」。但**审核备注里必须解释清楚**「为什么一个文件传输 app 内嵌了一个命令行 adb」——否则容易被判 2.5.2/2.4.5(iv) | 我起草审核备注（§5.5），你提交时粘贴 |
| **R5** | **`disable-library-validation` 等例外被质疑** | 审核对 Hardened Runtime 例外会问用途。若确实不需要，留着只会增加沟通成本 | 逐条试去掉，编译 + 运行验证（半天内能做完） |

---

## 4. 需要新增的工程形态（我能做）

| # | 产物 | 说明 |
|---|---|---|
| E1 | `macos/Resources/DroidBerth-MAS.entitlements` | ✅ **已落盘**。七条，逐条在文件里注明对应哪段代码；**刻意不放**的三类也写明了理由（`files.all` 已废弃 / `assets.*` 不需要因为照片走 PhotoKit / 三条 Hardened Runtime 例外不需要） |
| E2 | `macos/Resources/Helper-MAS.entitlements` | ✅ **已落盘**。`app-sandbox` + `inherit`，并写明两者作用不同：前者是**审核要求**，后者才是继承机制，而**功能上子进程本来就继承** ⇒ 漏了 `inherit` 本地测不出来 |
| E3 | `macos/project.yml` 加一个 **`Release-MAS`** 配置 | ✅ **已完成并实测构建通过**。配置类型显式写成 `release`（XcodeGen 按名字推断类型，不然会掉进 Debug 预设拿到 `-Onone`），生成结果核对过：`-O` + `wholemodule` ✅。目标级换 `Apple Distribution` + E1，`PROVISIONING_PROFILE_SPECIFIER` **刻意不写**（部署期数据，从命令行注入） |
| E4 | `scripts/sign-embedded-tools-mas.sh` | ✅ **已完成并实测通过**。由内向外签（helper 带 E2 → app 带 E1），并**数清 `Contents/MacOS` 下恰好 3 个可执行文件**（多一个就会被静默按「无 entitlements」留在包里）。没有 Apple Distribution 证书时会退到 ad-hoc 并**大声说明**。实测：两个 helper 各 2 条、app 7 条。**2026-10-13 起由 `project.yml` 的 `postBuildScripts` 自动调用**（`--helpers-only`）—— 原因见 §4.7：不挂进构建链，Xcode 归档上传就收不到这两个 entitlements |
| E5 | `scripts/package-mas.sh` | ⬜ 待做。会用到 `Mac Installer Distribution` 证书（还没有） |
| E6 | `scripts/check-mas-readiness.sh` | ✅ **已完成并实测通过**。三档结论（PASS / FAIL / 人工项），实测 **PASS 23 · FAIL 1 · 人工项 6**，退出码 1 —— **唯一那条 FAIL 正是缺 `embedded.provisionprofile`**，也就是必须有 App Store Connect 记录才能生成的东西。它自己也在第一次跑就抓出一个缺陷（见 §4.2） |
| E7 | 启动时的**授权引导流程**（代码改动） | ⬜ 待做。**先看 §4.1 的实测数据** —— `places()` 不只是「要授权」，现在这个形态会**骗人** |
| E8 | 退出时 `adb kill-server`（代码改动） | ⬜ 待做 |

### 4.1 实测：容器里的固定位置长什么样（2026-10-12，`places()` 的直接依据）

拿 E1 那套 entitlements 打了一个沙盒探针（`scripts/spike-sandbox-adb.sh`，**权限来源已改成
直接读 `macos/Resources/` 的那两份**，不再自己抄一遍 —— 抄一份就会分叉，而分叉的表现是
「探针过了、真 app 没过」，那是最坏的一种：**它给你绿灯**）。

沙盒里的 `NSHomeDirectory()` 指向 `~/Library/Containers/<bid>/Data`，里面：

| 条目 | 是什么 | 读得动吗 |
|---|---|---|
| `Desktop` | 符号链接 → `../../../../Desktop` | ❌ **读不了**（`errno 257` = 没有权限） |
| `Downloads` | 符号链接 → `../../../../Downloads` | ✅ 可读（8 项）—— 因为正好有 `files.downloads.read-write` |
| `Movies` / `Pictures` / `Music` | 同上，符号链接 | ❌ **读不了**（`errno 257`） |
| `Documents` | **真目录，空的** | ⚠️ **读得动，但是空的**（0 项）—— **不报错** |

对照组（同一段代码、不带沙盒）：六项全部是真实目录、全部可读。

**为什么这条比「要授权」严重得多：** `LocalFileSystem.places()` 现在就是
`homeDirectoryForCurrentUser` 拼六个名字 + `fileExists()`，而 **`fileExists()` 会跟随符号链接**
⇒ 在 MAS 版里它会把这六项**全部列出来**。然后：

- 点「桌面」「影片」「图片」「音乐」→ 权限错误（4 项）
- 点「下载」→ 正常（1 项）
- 点「文稿」→ **打开一个空文件夹，而且不报任何错**（1 项）

最后一条是**用户会以为文件丢了**的那种缺陷。所以 `places()` 在 MAS 版不能只是「加个授权」，
要么重写成「只列真正有权限的位置」，要么整个拿掉、改成「只用用户授权过的目录」。

> 顺带把方案 §2.3 里那条 `assets.pictures` 的疑问也答了：`places()` 列的 `~/Pictures`
> 在沙盒下根本读不动，**加 entitlement 不是解法** —— 照片图库走的是 PhotoKit
> （`Photos/PhotoLibraryModel.swift`），需要的是一条 `personal-information.photos-library`，
> 已经放进 E1 了。

**已修（2026-10-12）**：判据落成两个纯函数，`Support/LocalPlacePolicy.swift`：

1. **解析符号链接后必须落在容器之外** —— 拦掉容器里的空真目录（`Documents`）
2. **真的能列出内容** —— 拦掉容器外的符号链接但没权限的那些（`Desktop`/`Movies`/`Pictures`/`Music`）

`LocalFileSystem.places()` 按它过滤；`AppPaths.containerDirectory` 用**与 S1 探针同源**的判据
（`NSHomeDirectory()` vs passwd 家目录）判断「在不在沙盒里」，不在沙盒里时传 `nil` ⇒ 侧载版
行为**与从前完全一致**（也就说这条分支只在沙盒下生效）。

取证时有两个坑写进了代码注释：**不能用 `fileExists` 代替「能不能列」**（实测沙盒下它返回 true）、
`canList` **必须真的开一次目录**（`errno 257` 只有真列才报）。另外 `places()` 在 `MainView` 的
`body` 里被调用，所以结果**算一次就缓存** —— 否则每帧都做 IO。

新增第 5 道回归守卫 `scripts/check-local-place-policy.swift`：**这条分支靠手跑跑不出来**
（侧载版一百遍都走「都放行」那一路），只能把沙盒那一侧的输入直接喂进去。已接进 `check-all.sh`。

### 4.2 怎么验沙盒版：**不需要证书，也不需要 App Store Connect**

实测一遍完整流程（每步都验过）：

```bash
CONFIGURATION=Release-MAS ./scripts/build.sh                 # 用 Apple Distribution 签，BUILD SUCCEEDED
CONFIGURATION=Release-MAS ./scripts/check-mas-readiness.sh   # PASS 23 · FAIL 1 · 人工项 6
```

- `xcodebuild` 的 **`build` 动作不强求 provisioning profile**（只有 archive / 上传才要）
  ⇒ 没有 profile 也能构建、也能本机运行。**唯一那条 FAIL 就是缺 profile**，而那是必须
  先有 App Store Connect 记录才能生成的。
- 内嵌 helper 的 entitlements **由构建阶段自动补**（2026-10-13 起，机制见 §4.7）——
  **不再需要手工跑一次 `sign-embedded-tools-mas.sh`**。那个脚本现在只在「包已经构建好、
  要单独重签一个」时用（如修别人给过来的包）。

**两条硬规矩（都踩过）：**

1. **用 `open` 启动它，别从 shell 跑可执行文件。** 在有限制的会话里直接跑它 =
   `exit 133` + 一行输出都没有，`.ips` 栈顶 `libsecinit_appsandbox`（沙盒初始化失败）。
   这看着就是「沙盒把 app 挡住了」，其实只是**启动方式**不对 —— `open` 由 launchd 拉起，
   不继承你所在进程的沙盒。实测同一个包两种签名都能正常起来。
2. **判据每次现测。** 「本会话能不能施加限制性沙盒」在同一天里会变（06:20 是 0、06:41 是 71）
   ⇒ 别引用上一轮的结论。

> ⚠️ **更正一条早期结论（2026-10-12 复核过两轮）**：本方案曾口头写「用 Apple Distribution
> 签的包本机跑不起来」—— **不成立**。当时的两条依据都不支持它：`spctl -a` 报 `rejected` 是
> **Gatekeeper 的分发评估**（与公证/票据有关，不妨碍本机运行）；shell 跑出 133 是**启动方式**的问题
> （上一条）。
>
> **复核用的判据**（`lsof` 看 cwd，见 `1011_05` §10.3）：Apple Distribution 签名、**无 profile**
> 的 MAS 包经 `open` 启动后 —— `cwd` = `~/Library/Containers/dev.tango.droidberth/Data`、
> 日志写在容器里且有 3843 字节、真实 `~/Library/Logs/` 里从来没出现过 `Release-MAS`。
> ⇒ **它不但能跑，而且是作为一个正常的沙盒 app 在跑。**
>
> 所以**本机自测不必另配一套开发签名** —— 缺 profile 只会让 `check-mas-readiness.sh` 报那一条 FAIL。
> 沙盒初始化只看签名里的 entitlements；profile 是给**受限** entitlements（`com.apple.developer.*`）
> 与 App Store 校验用的，我们一条都没用到。

### 4.3 第一轮视觉验收量到的两条（2026-10-12）

完整的报告与证据在 **`docs/1012_01_mas-visual-acceptance.md`** + `docs/mas-acceptance/2026-10-12/`。
两条都是**新发现**，都会影响 E7 的形态：

**F1 · 沙盒版开局就站在自己的容器里。** 路径栏实测
`/ ▸ Users ▸ tango ▸ Library ▸ Containers ▸ dev.tango.droidberth ▸ Data`。
用户第一次打开看到的是**自己容器的内容**，不是家目录。
⇒ **E7 不是「可做可不做的优化」，是 MAS 版的必需件** —— §2.1 那条 Guideline 2.5.2 的代价
从纸面变成了画面。

**F2 · 沙盒下符号链接被显示成「文稿」，还带一个假的大小。** 实测：
`Desktop 文稿 19 B`、`Downloads 文稿 21 B`、`Movies 文稿 18 B`、`Music 文稿 17 B`、
`Pictures 文稿 20 B`（而真目录 `Documents/Library` 正常显示「文件夹」）。
原因：`LocalEntry.kindLabel` 只看 `isDirectory`，而沙盒下 `isDirectoryKey` **不跟随符号链接**；
大小那列读到的是**符号链接自身**的长度。
⚠️ 这与 `places()` 的过滤是**两件事**：过滤管「弹窗里列不列它」，F2 管「在列表里长什么样」——
而因为 F1，列表里**一定会看到这五项**，所以 F2 不是理论问题。

**F2 已修（2026-10-12）**：挖下去发现它是**「同一个概念两端语义不同」**那个老毛病 ——
设备侧 `RemoteEntry.kindLabel` **一直有** `isSymlink → 替身`，本地侧 `LocalEntry` 漏了这一支。
两端顺序与用词已统一，符号链接也**不再报大小**（`fileSizeKey` 给的是链接自身长度）。
实测行：`DroidBerth-symlink-test  替身  —`（证据 `docs/mas-acceptance/2026-10-12/07-*.ax.txt`）。

### 4.4 沙盒版当前**能访问哪些文件夹**（2026-10-12 实测）

用户问的就是这个。下面每一条都是**在这台机器上量出来的**，不是从 entitlements 推的：

| 位置 | 能读吗 | 判据 |
| --- | --- | --- |
| 真实 `~/Downloads` | ✅ **能** | 真 app 里实测：列出 6 项真实文件（`.dmg` / `.JPG` …） |
| 真实家目录 `~` 本身 | ❌ **不能** | 真 app 里按「向上」→ `未能打开文件"tango"，因为你没有查看它的权限。` |
| `~/Desktop` `~/Movies` `~/Pictures` `~/Music` | ❌ 不能 | 沙盒探针实测 `errno 257` |
| `~/Documents` | ❌ 读不到真实那份 | 探针：容器里那个 `Documents` 是**空目录** |
| `/` | 能列，但**只剩 4 项**（Applications / Library / System / Users） | 真 app 实测 |
| 照片图库 | ✅ 有 `personal-information.photos-library`（走 PhotoKit） | **未跑过真实相册验证** |
| 外置卷 / SD 卡 | ❓ **未实测** | 机制上只能靠用户经面板授权 |
| **任意素材目录** | ✅ **靠 `NSOpenPanel` + bookmark** | 就是 E7 |

⇒ **「用户的视频、照片不止在 Documents 中」正是要点。** 靠 entitlement 永远只能覆盖**有限的几个固定
位置**，而且每加一条就多一个要向审核解释的东西。**唯一能覆盖「素材在任意位置」的机制，是
「用户亲手选一次 + 记住 security-scoped bookmark」** —— 也就是 E7。

所以 **E7 不是「为了合规额外加的步骤」，它就是产品能力本身**：没有它，MAS 版**根本到不了用户的素材**。

> 可选便利（**建议先不做**）：加 `assets.movies.read-write` / `assets.pictures.read-write` 能让
> 「影片 / 图片」这两个固定位置开箱可读。但那仍然只是两个固定位置，不改变上面的结论。

### 4.5 同一轮补上的保护（用户指出「反倒没有保护」）

原先 `places()` 的过滤只挡住了**弹窗那一处**，而 `Library` / `SystemData` / `tmp` / `Documents`
照样被当成用户文件**列出来、还能走进去**。补了两处：

1. **`LocalFileSystem.list()` 拒绝列出容器内的路径** —— 放在这里而不是 `navigateLocal`，
   因为它是**列目录的唯一入口**，所有调用点一起受保护。判据与 `places()` **同一条**
   （`LocalPlacePolicy.isBrowsable`）。拒绝时用现成的错误态 UI（「打不开这个位置」+「重试」），
   文案明说「这是 DroidBerth 自己的容器，不是你的文件」。
2. **起始目录从「容器」改成「真实 `~/Downloads`」** —— 用户第一次打开看到的是**自己的文件**，
   而不是 App 的容器管道。

> ⚠️ 具体的取舍：起始目录**必须给真实路径**，不能给容器里那个链接名 ——
> 实测 `<容器>/Downloads` 用 `contentsOfDirectory(at:includingPropertiesForKeys:)` **列不出来**
> （`NSFileReadNoPermissionError`），而同一时刻用路径版 `contentsOfDirectory(atPath:)` 能列出 8 项。
> 原因见 `1011_05` 的「别做」清单。

### 4.6 E7 的形态（**已拍板**，用户 2026-10-12 确认）

`§4.4` 的结论是「只有『用户选一次 + 记住 bookmark』能到达任意素材目录」，所以 E7 是产品能力。
形态定了四个状态：

| 状态 | 界面 |
| --- | --- |
| ① 首次启动 · 未授权 | **空白引导**（不再是容器内容）：「还没有可访问的文件夹」+「沙盒版需要你指定一次素材目录，之后会记住」+ 主按钮「选择素材目录…」，**并给一条「或先用『下载』」的退路** |
| ② 选择目录 | 系统 `NSOpenPanel`（不自己画），外置硬盘也能选 |
| ③ 之后每次打开 | 直接落在那个素材目录；「位置」弹窗按**最近使用**排序 |
| ④ 授权失效时 | 「上次的目录打不开了 / 它可能被移动、改名或删除了」+「重新选择…」 |

两个已定的取舍：
- **首次启动走 ①（不是直接弹面板）** —— 用户要知道**为什么**需要这一步，取消之后也有地方可去；
- **记多个目录**（上限 10，按最近使用排序），而不是只记一个 ——
  对应真实场景「反复回同一个项目文件夹、偶尔换项目」。

**已实现并实测（2026-10-12）**：底座 `Support/BookmarkedFolders.swift`（security-scoped bookmark
列表；纯逻辑与持久化分开，存储位置**可注入** ⇒ 守卫能用临时文件真跑往返）+ 接入 `AppModel`
（`LocalAccess` 四态 / `rememberFolder` / `forgetBookmarkedFolders` / `useDownloadsAsStartFolder` /
`updateSecurityScope`）+ 两个空态 + 「位置」弹窗的书签段。

实测见 `docs/1012_01_mas-visual-acceptance.md`（证据 `docs/mas-acceptance/2026-10-12/08–09`）：

| 项 | 结果 |
| --- | --- |
| ① 未授权 | ✅ UI 树实测：标题 / 说明 / 两个按钮全在，列表为空 —— **不再显示容器内容** |
| ② 选目录 | ✅ `NSOpenPanel` → `rememberFolder` 落 security-scoped bookmark（实测容器里已有记录） |
| 跨启动恢复 | ✅ 重启后**直接落在授权目录**、列出用户真实文件 |
| ④ 授权失效 | ⚠️ **逻辑由守卫覆盖**（`FolderAccess.state` 四条分支各一条用例），**UI 未实测** —— 容器对自动化不可写，造不出「有记录但全坏」的现场 |
| 「位置」弹窗 | ✅ 沙盒版标题是「**已授权**」（侧载版是「最近使用」），列已授权项 |

⚠️ 顺手删掉了**旧的 `settings.recentLocalFolders`**（存**路径**、上限 8、UserDefaults）：
沙盒下路径根本读不了，留着就是同一概念的两种实现，而**只有一种在沙盒里有效**。

**实测中修掉的两条缺陷**（详情见 `1012_01`）：

1. **未授权时导航栏与内容区自相矛盾** —— 路径栏写着「下载」、内容区说「先选一个文件夹」，
   而那正是用户**第一眼**看到的画面。已改为未授权时不显示面包屑与导航按钮（`needsFolderAccess`）。
2. **「位置」里的「下载」指向容器内的符号链接**（未解析）—— `places()` 的判据用的是解析后路径、
   返回的却是链接名 ⇒「过了判据却打不开」（就是 F3 那条）。已改为返回 `resolvingSymlinksInPath()`。

---

### 4.7 内嵌工具 entitlements 的**正确落点**（2026-10-13，从「归档上传被拒」反推）

**症状**：Xcode Organizer 归档上传时，App Store Connect 直接拒收：

```
App sandbox not enabled. The following executables must include the
"com.apple.security.app-sandbox" entitlement with a Boolean value of true in the
entitlements property list: [( "…/DroidBerth.app/Contents/MacOS/adb",
                               "…/DroidBerth.app/Contents/MacOS/droidberth-adb" )]
```

**根因不是「配置写错」，而是「没有任何一处在做这件事」**：

| 环节 | 它做了什么 | 结果 |
| --- | --- | --- |
| `build-sidecar.sh` | 把两个二进制暂存进 `macos/Sidecar/` | 刻意 **unsigned** |
| `CodeSignOnCopy` | Xcode 用 app 的 identity 签它们 | `--preserve-metadata=…entitlements…` 保留的是**源文件本来就有**的 ⇒ **0 条** |
| `sign-embedded-tools-mas.sh` | 由内向外补签 | ✅ 但**只在手工流程里**才被调用 |

⇒ `build.sh` 出来的包是对的（因为第 3 步会被手工执行），而 **`xcodebuild archive` /
Xcode Organizer 完全不知道第 3 步的存在** —— 归档上传被拒的正是它产出的包。

**修法**：把补签挂到 **`project.yml` 的 `postBuildScripts`**（target 级，`--helpers-only`）。
**时机就是这件事的全部**：

```
Copy Files（CodeSignOnCopy，此刻仍是 0 条）
   ↓
postBuildScripts        ← 这里补 app-sandbox + inherit
   ↓
CodeSign 任务（helper ×2 → app）   ← 不再回头重签 helper，我们的签名保留
```

实测顺序（构建日志的行号即顺序）：`CodeSign …/droidberth-adb (723)` → `CodeSign …/adb (731)`
→ `PhaseScriptExecution Sign embedded tools… (739)` → `CodeSign …/DroidBerth.app (1376)`。

**判据**（必须读 **archive 里**的包，不是 `build/` 下那个）：

| 检查对象 | 期望 |
| --- | --- |
| `…xcarchive/Products/Applications/DroidBerth.app/Contents/MacOS/adb` | **2 条**（app-sandbox + inherit） |
| `…/MacOS/droidberth-adb` | **2 条** |
| `…/Contents/MacOS/DroidBerth`（app 自己） | 7 条 |
| 侧载版 `Release` 的同两个 helper | **0 条**（构建阶段按配置跳过，侧载不受影响） |
| `codesign --verify --deep --strict` | 通过 |

⚠️ **一条被证伪的「更聪明做法」**：把 entitlements **预签到** `Sidecar/*` 源文件上
（看着能利用 `--preserve-metadata`，改动最小）。**不行** —— 带 `app-sandbox` 的二进制
被**独立执行**时启动即死：`preBuildScripts` 里那句 `droidberth-adb version` 自检会直接
`Trace/BPT trap: 5`，构建报 `PhaseScriptExecution failed`（看着像脚本坏了）。2026-10-13 实测。
⇒ **判据：任何「让 Sidecar 带上 entitlements」的方案，都必须同时回答「它还能不能自己跑」。**

**同一批日志里的两条 dSYM 警告**（`Upload Symbols Failed … adb` / `… droidberth-adb`）：
是 **warning，不阻断上传、不影响审核**。`dsymutil` 对两个二进制都报 `no debug symbols`
（`adb` 是 Google 的预编译产物、我们无法重新编译 Android 的 adb；`droidberth-adb` 是 Rust
release，Cargo 默认不带 debug info）。⇒ **`adb` 那条无法从工程侧消除**；`droidberth-adb`
想消除就得给 Cargo 开 debug info —— **拿体积换**，属产品取舍，未做。

## 5. App Store Connect 侧要准备的材料

> 分三栏：**我能准备** / **必须你准备** / **待定**。

### 5.1 账号与协议

| 项 | 谁 |
|---|---|
| Apple Developer Program 会员（已是，Team ID `UKXWZ3FS84`） | ✅ 已有 |
| 在 App Store Connect 里**新建 App 记录**（bundle id `dev.tango.droidberth`） | 你（要登录，我代不了） |
| Paid Applications Agreement / 各类协议签署 | 你 |
| 若免费分发：无需银行与税务信息 | — |

### 5.2 证书与描述文件（都在你的开发者账号里，我代不了）

| 项 | 说明 |
|---|---|
| `Apple Distribution` 证书（app 签名） | ✅ **已经有了**（2026-10-11 实测 `security find-identity -v -p codesigning` 里就有 `Apple Distribution: zhenzhi Tang (UKXWZ3FS84)`）。本文件初稿写「要新申请一张」，是错的 |
| `Mac Installer Distribution` 证书（`.pkg` 签名） | ⬜ **要新申请**（本机目前只有 Apple Development / Developer ID Application / Apple Distribution 三张） |
| **Mac App Store provisioning profile** | MAS 与侧载最大的差别之一：**必须有 profile**，绑定 App ID 与你勾选的 entitlements。开发自测另需一个 **Mac App Development** profile |
| App ID 的 capability 勾选 | 要与你声明的 entitlements 一致，漏勾会在签名/上传时失败 |

### 5.3 App Store Connect 元数据（文案我能写，提交要你）

| 项 | 谁 | 备注 |
|---|---|---|
| App 名称 / 副标题 / 分类 | 我起草 | 分类已定：`public.app-category.utilities`（`Info.plist` 里已有） |
| 描述（Description）+ 关键词 | **我写** | 可直接复用 README 的定位段与关键词 |
| 「新功能」（What's New） | **我写** | Guideline 2.3.12 要求如实描述变更 |
| 支持 URL（**必填**，Guideline 1.5 要求能联系到你） | 你 | 可以是 GitHub Issues 页或一个简单网页 |
| 营销 URL / 隐私政策 URL | 我起草，你确认主体 | 本 app **不收集任何数据**（诊断包只在用户机器上生成、不自动上传）⇒ 隐私政策可以很短 |
| App 隐私声明（App Privacy 问卷） | 我列逐项答案，你点 | 与「不收集数据」一致 |
| 年龄分级 | 我填（应是最低档） | |
| 定价 | 你 | |
| 中国大陆上架所需的额外资质 | **你确认** | 涉及 ICP / 软件著作权等；**我没有判据，不要猜** |

### 5.4 视觉素材（我生成不了，必须你在真机上截）

| 项 | 要求 | 谁 |
|---|---|---|
| App 图标（1024×1024） | 已有（`scripts/make-icon.py` 的母版） | ✅ |
| **macOS 截图** | App Store 要求若干张，且**必须是真实运行界面**。⚠️ 更正（2026-10-12）：不是「本机无法截图」，而是**缺「屏幕录制」权限** —— 工具已就绪（`scripts/ui-shot.sh`，按窗口 id 精确截图，避开整屏）。**权限已到位，这一项我能做** | **我** |
| **视觉验收** | 沙盒版**第一次真的看过界面**（2026-10-12）。方法与结果见 `docs/1012_01_mas-visual-acceptance.md`，证据在 `docs/mas-acceptance/2026-10-12/`（像素 + UI 树两份） | ✅ 已做第一轮 |
| 预览视频（可选） | | 你 |

> 截图这一项要设计几个脚本：**双栏主界面**、**网格视图带缩略图**、**传输进行中**、
> **连接引导卡片**、**预览窗格**。我可以先在代码里确认这些界面都在，你只需要按脚本截。

### 5.5 审核备注（App Review Notes）—— **我起草**

沙盒 app 里内嵌命令行工具、要求 USB 访问权、还要访问用户目录，这三件事都必须在备注里讲清楚。
我会写成一段可直接粘贴的英文说明，涵盖：
① 这个 app 做什么（Mac ↔ Android 文件传输，给摄影师用）；
② 为什么内嵌 `adb`（用户不该被要求装 Android SDK；adb 是 Apache-2.0，`NOTICE.txt` 随包）；
③ 为什么需要 USB / 网络 / 用户选中目录三类权限，各自的用途；
④ **登录/账号：不需要**（没有账号体系，审核员直接就能用）；
⑤ 无网络后端、不收集数据。

### 5.6 法律与主体的三件（之前就在路线图里，这里再列一次）

| 项 | 说明 |
|---|---|
| **仓库 LICENSE** | 与 MAS 无直接冲突，但公开仓库该有（路线图 B1） |
| **`NOTICE.txt` 的 §3.5 适用性** | 附录 B #2 的待验证项：发 **App Store 包**时更需要它 —— 商用分发。**这不是法律意见，要法务确认** |
| `NSHumanReadableCopyright` | 空串。填一行版权声明（我能改，主体你定） |

---

## 6. 我的建议：先花半天做可行性，再决定投不投入

沙盒化是个**会反向改产品**的工程（§2.1），不要一次做完才发现 R1 走不通。建议这个顺序：

```
S1  最小沙盒 app spike（半天）—— 只验一件事：沙盒里 adb 能否列出 USB 设备
       ├─ 能 → 继续
       └─ 不能 → 决策点：MAS 版是否只支持「无线 ADB」？若也不行 ⇒ MAS 这条路放弃，
                 继续做侧载分发（并把这半小时的结论写进文档，免得半年后再试一遍）
S2  E1–E3（entitlements + MAS 配置）          半天
S3  E7 + E8（授权引导 UI + 退出时收 adb）      1–2 天（UI 改动，先出图）
S4  E4 + E5 + E6（签名 / 打包 / 上架前自检）   半天
S5  元数据 + 截图 + 审核备注                   你半天（我出文案）
S6  首次提交 → 应对审核反馈（预留 1–3 个来回）
```

**关键判断：S1 的结论决定后面全部。** 而那半天是**可以现在就做的**——
不需要任何新证书、不需要 App Store Connect 记录，只要一个沙盒 flag 加在本机构建上。

### 6.1 S1 探针已经写好了：`scripts/spike-sandbox-adb.sh`

它做三件互相独立的事，因为三者的结论完全不同：

| 判据 | 问的是 |
|---|---|
| **S1-a** | 沙盒里能不能**执行**包内内嵌的 adb |
| **S1-b** | adb 的 server 能不能在沙盒里**起在自定义端口**（要 `network.server`） |
| **S1-c** | 沙盒里 adb 能不能**通过 USB 看见真机** |

跑法：

```bash
./scripts/spike-sandbox-adb.sh          # 默认端口 15037，刻意避开你自己的 5037
```

它同时打**两个** bundle：沙盒版 + **不带沙盒的对照组**（两边跑同一段代码）。
对照组是必需的 —— 只测沙盒版的话，「adb 失败」既可能是沙盒挡的，也可能是探针自己打包错了，
**分不清的两件事等于没测**。跑完自动注销 LaunchServices 记录、删掉临时目录与它创建的容器。

**2026-10-12 实测结果：S1-a / S1-b 已过，只剩 S1-c**

| 项 | 结论 |
|---|---|
| 对照组（未沙盒） | ✅ 探针本身没坏：`adb version` 与 `adb devices -l` 都退出码 0，server 起在 `tcp:15037` |
| **S1-a 沙盒内执行包内 adb** | ✅ **PASS** |
| **S1-b 沙盒内 adb server** | ✅ **PASS** —— 起在自定义端口 `tcp:15037`（说明 5037 不是必须的） |
| **S1-c adb 经 USB 见真机** | ⏸ **仍未验证** —— 当时只连着 `emulator-5554`（走 TCP）+ **一台 iPhone**（adb 看不见 iOS 设备）。需要一台 **Android** 真机 |
| **S1-c′ USB 通路（辅助判据，本轮新增）** | ✅ **成立** —— 沙盒内 IOKit 枚举到 **4 个 `IOUSBHostDevice`**，与不沙盒的对照组**数量完全一致** |

判据自检「沙盒真的生效了吗」= **是**（`NSHomeDirectory` 指向容器、真实家目录不可列）⇒ 上面的 PASS 可信。

**S1-c′ 是什么、为什么值得加**：S1-c 的真判据必须有 Android 真机，插上之前什么都证不了。
但**权限通路**可以先单独验掉：`adb` 在 macOS 上走 libusb、libusb 走 IOKit。沙盒里若连
`IOUSBHostDevice` 都枚举不到，S1-c 几乎必然失败 —— 不用等手机就知道结论。这条已经在沙盒里过了，
而且看到的是**真实的用户外设**（键盘 / 鼠标 / 显示器 USB Hub / iPhone），不是只有根集线器。

> ⚠️ 它只是**辅助**：枚举得到 ≠ adb 一定打得开设备（打开还要额外一步授权）。
> 所以它过了也**不把 S1-c 判成 PASS**。

**还剩一件事，需要你**：插一台 **Android 真机**、在手机上确认 USB 调试授权，再重跑一次上面的脚本。
脚本现在是只读探针、跑完自己收工；**退出码 0 = 沙盒真的生效且 S1-a/S1-b 通过**（环境不可信时返回非 0，
不让调用方把「没验到」当成绿灯）。

### 6.1 ⚠️ 一条被**推翻**的结论（记在这里，因为它差点让这条路被白否掉）

2026-10-11 本方案与工程笔记都写过「**本机 agent 会话做不了沙盒验证**」，判据是：

```bash
sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok   # 退出码 71
```

**这条是错的。** 那份 profile 里**没有 `allow process-exec`**，而 `sandbox-exec` 施加完 profile
之后**还要 exec 目标程序** —— 是 profile 自己拒绝了 exec，**也就是说 profile 其实施加成功了**。
补上 `allow process-exec` 后同一条命令退出码 **0**。

同类第二个坑：探针里一度把被施加的程序写成 `/bin/true` —— macOS **没有**这个路径，是 `/usr/bin/true`。
路径写错同样报 71、同样报 `execvp() … failed`。**一条六行的探针连错两次，两次都指向同一个错结论。**

代价是实的：这条误读让「做不了」被写进方案、工程笔记与项目记忆，而实际上沙盒版探针在这里
**跑得完全正常** —— S1-a / S1-b 当场就 PASS。**判据错一个方向，挡住的是自己的路。**

它的推论「本机构建需要 `-Xfrontend -disable-sandbox`」也一并被否：2026-10-12 实测完整
`build.sh`（`xcodebuild`）**不带**该参数也 `BUILD SUCCEEDED`，日志里 `sandbox_apply` /
`malformed response` 一条都没有。该机制保留（探测不命中时零影响），但**必要性未被证实**，已在
`scripts/check-all.sh` 的注释里如实标注。

---

## 7. 需要你先拍板的三件事

| # | 决策 | 选项 |
|---|---|---|
| **D1** | 要不要做 MAS 版？ | ① 做（多一条渠道，但要有第二套签名/打包，且 MAS 版功能受限）② 不做，专注侧载（`release-local.sh` 已经跑通，1.0.0 就能发）③ 先做 S1 的半小时 spike 再定 |
| **D2** | 如果做：接受「首次运行要授权素材目录」吗？ | 这是沙盒换来的**不可回避**的代价。不接受的话，MAS 版对主场景（几百 GB 项目文件夹）的体验会明显差于侧载版 |
| **D3** | 如果做：MAS 版与侧载版的关系 | ① 两者并行（MAS 版可能不支持 USB，只支持无线）② MAS 版为主，侧载版只给老用户 ③ 先只发侧载，MAS 作为 1.1 |

---

## 8. 不确定 / 待确认清单（不要当结论用）

| # | 项 | 为什么不确定 |
|---|---|---|
| U1 | `com.apple.security.device.usb` 是否足够让 adb 的 IOKit 通道工作 | 官方只承诺「USB device access APIs」，没有点名 adb 走的那条路。**已部分回答**：S1-c′ 证明沙盒内 IOKit 能枚举到 USB 设备（与不沙盒一致），但「**打开**设备」还没验 —— 需要 Android 真机（S1-c） |
| U0 | ~~受限会话里跑不了沙盒进程~~ ❌ **这条结论是错的，已推翻（2026-10-12）** | 原判据的 profile 少了 `allow process-exec`，把「profile 生效」读成了「施加不了」。实测沙盒版探针在这里跑得完全正常，S1-a / S1-b 当场 PASS。详见 §6.1 |
| U2 | adb server 在沙盒下的行为（能否 bind 5037、能不能 kill 干净、容器内的 `$HOME/.android` 是否被正确使用） | 要实测 |
| U3 | 沙盒下 `~/Library/Logs/DroidBerth` 会落到容器内哪一层 | ✅ **已实测（2026-10-12）**：落到 `~/Library/Containers/dev.tango.droidberth/Data/Library/Logs/DroidBerth/`。⚠️ 但 app **自己报出来的仍是原样的 `~/Library/Logs/DroidBerth`** —— 那在 MAS 版里是个**不存在的路径**。用户按支持说明去找日志会找不到，所以 `AppPaths` / 诊断入口要报**解析后**的路径 |
| U5 | Hardened Runtime 那三条例外是否还能去掉 | 🔶 **部分回答**：MAS 版（E1）**刻意没放**这三条，而 `Release-MAS` 实测**构建通过**。⇒ 至少**编译期不需要**。运行期是否需要要跑一遍才知道（属于方案 §3 的 R5） |
| U4 | `assets.pictures` / `movies` 这两组 entitlement 是否真需要（还是 user-selected 就够） | ✅ **已回答（2026-10-12）**：**不需要**。照片图库走 PhotoKit（`Photos/PhotoLibraryModel.swift`），要的是 `personal-information.photos-library`（已放进 E1）；而 `places()` 列的 `~/Pictures` 在沙盒下**根本读不动**（§4.1 实测），加 entitlement 不是解法 |
| U6 | 中国大陆上架需要的额外资质 | **我没有可靠判据，必须你或代理确认** |
| U7 | MAS 版本的**体积**限制（我们要内嵌约 40 MB 的 platform-tools） | 各方资料口径不一，提交时以 App Store Connect 的提示为准 |

---

## 9. 证书链路与自动化工具选型（fastlane / match 值不值得上）

> 2026-10-12 记录。起因是「涉及多套证书链路时，fastlane + match 是否能提高管理效率」。

### 9.1 先答「现在支持 MAS 了吗」：**没有，一行代码都没动**

这一条要用证据回答，不能靠印象。仓库当前状态（2026-10-12 实查）：

| 查什么 | 结果 |
|---|---|
| `macos/` 下的 `app-sandbox` | **0 处** —— 沙盒是 MAS 的硬性要求（Guideline 2.4.5(i)），这条不成立就谈不上「支持」 |
| entitlements 文件 | 只有 `Resources/DroidBerth.entitlements` 一个，内容是三条 **Hardened Runtime 例外**（`allow-jit` / `allow-unsigned-executable-memory` / `disable-library-validation`），**不是沙盒权限** |
| `project.yml` 的配置 | 只有 **Debug / Release 两个**；签名写死 `CODE_SIGN_IDENTITY: "Developer ID Application"` + `CODE_SIGN_STYLE: Manual`，**没有** `PROVISIONING_PROFILE_SPECIFIER`（MAS 必须有 profile） |
| 证书 | Apple Development / Developer ID Application / **Apple Distribution** 三张。缺 `Mac Installer Distribution`（签 `.pkg` 用） |
| 打包形态 | 只有 `package-release.sh`（DMG + zip）。**没有** `productbuild` 的 `.pkg` 那条路 |
| fastlane / Gemfile | 不存在 |

**目前存在的只有两样东西**：一份**方案**（本文档）与一个**可行性探针**（`scripts/spike-sandbox-adb.sh`）。
而那个探针的结论**还没出来** —— 它需要不受限的终端 + 一台真机。

⇒ 所以准确的说法是：**MAS 是一条已论证清楚、但尚未开工、且可行性未验证的路。**

### 9.2 现在到底有几条证书链

把两条渠道摊开数一遍（这是判断「要不要工具」的前提）：

| 渠道 | 需要的东西 | 现在有没有 |
|---|---|---|
| **侧载（Developer ID）** | ① `Developer ID Application` 证书 | ✅ |
| | ② 公证凭据：App Store Connect API key，或 Apple ID + app-specific password | ✅（`.env` 三件套） |
| | ③ profile：**不需要**（Developer ID 不走描述文件） | — |
| **MAS** | ④ `Apple Distribution` 证书 | ✅ **已有** |
| | ⑤ `Mac Installer Distribution` 证书（签 `.pkg`） | ⬜ 待申请 |
| | ⑥ Mac App Store **distribution profile** | ⬜ 待建 |
| | ⑦ Mac App Development profile（本地自测要另配一套） | ⬜ 待建 |
| | ⑧ 上传凭据：App Store Connect API key —— **可与 ② 共用同一把** | ✅（若统一） |

**合计 4 张证书 + 2 个 profile，且是单人单机。** 这个规模是判断的关键。

### 9.3 `match` 解决的是**分发**问题 —— 而本项目现在没有这个问题

`match` 的定位说得很明白（原文）：*"An Apple Distribution certificate belongs to the team...
Its private key, though, is created on one Mac. So the question every team hits is:
**how do the other Macs, and the build server, get that key?**"*

它给的是这个答案：把证书 + 私钥 + profile 放进一个**加密的私有 git 仓库（或 S3/GCS）**，
用**一个共享口令**（OpenSSL 加密）保护，任何机器 `match` 一下就能取到。

本项目的现实是：**1 个人、1 台 Mac、仓库只有 1 个协作者。**
「key 怎么到别的机器上」这个问题**不存在** ⇒ `match` 的收益 ≈ 0。

而它带来的成本在这个项目里是**实打实**的，而且第 1 条正好撞上一个已经做过的决定：

| # | 成本 | 为什么在这里格外贵 |
|---|---|---|
| 1 | **它要求把签名私钥放进一个 git 仓库** | 本项目**刚刚明确决定过**「签名凭据一步都不离开本机」，README 里为此写了整段理由（Developer ID 私钥给的不是「读你的数据」，是「以你的名义签发任何 macOS 都信任的软件」）。上 `match` 等于**把这个决定重新打开**，而且现在还要多放一套 MAS 的私钥。这是**新增攻击面**，不是中性动作 |
| 2 | 单一口令，**丢了无法恢复** | 只能 `match nuke` 重建；口令得进密码管理器 —— 又多一件必须保管的秘密 |
| 3 | `match nuke` 会**吊销它管理的所有证书** | 会打断正在进行的构建；而 Apple 对分发证书有**数量上限（3 张）**，反复 nuke/重建很容易撞上限 |
| 4 | 多一个仓库（或 bucket）+ `MATCH_PASSWORD` 的保管链路 | 单人维护两处凭据，比维护一处更费神 |
| 5 | 引入 Ruby / bundler 到仓库与 CI | 现在的 CI 是刻意极简的（装工具链 → 取 adb → 构建 → 跑守卫） |

**什么时候它会开始划算？** 三条触发条件，命中任意一条再谈：
① 出现**第二台 Mac**（家里 + 公司）；② **CI 要签名**（而不是像现在只做验证）；
③ 出现**第二个人**参与签名/发版。

> 顺带一句：即便要上，也应让 `match` 跑 `--readonly` 供取用，只在一处读写下发新证书 ——
> 在新鲜 runner 上跑读写模式会**悄悄新签一张证书**，吃掉 Apple 那 3 个名额里的一个。

### 9.4 `fastlane`（不含 `match`）逐项评估

它不是一个整体，要拆开看。结论是：**只有 MAS 的元数据/TestFlight 那一块有实质收益。**

| 组件 | 在本项目值不值 | 理由 |
|---|---|---|
| `deliver`（ASC 元数据 / 截图） | ✅ **值**（仅当走 MAS） | 元数据变成仓库里的一组文本文件，可 review、可回滚、可 diff —— 比在网页上一个一个填强得多。这是 fastlane 对本项目**唯一**明显省事的部分 |
| `pilot`（TestFlight） | ✅ **值**（仅当走 MAS） | 同上，上传与分发测试版 |
| `gym`（构建） | ❌ **不值** | 它只是包一层 `xcodebuild`。而 `build.sh` 是**四步链**（图标 → NOTICE 暂存 → sidecar → xcodegen → xcodebuild），`gym` 顶多替最后一步。更关键的是 `build.sh` 里攒着一批踩过的坑（bash 3.2 空数组展开、`XCODEBUILD_ARGS` 这个唯一可靠的口子）。换掉它 = **同一件事两份实现**，正是这个仓库反复修过的形状 |
| `scan`（测试） | ❌ **接不上** | 本项目**没有测试 target**；四道守卫是独立编译的脚本（`check-all.sh`），不是 XCTest |
| `notarize` | ❌ **不值** | `notarize.sh` 已经做了 app + DMG **双**公证 + staple，并带三条踩过的坑（`zip -X -y`、`ditto` vs `cp -R`、DMG 本身的签名）。替换的风险 > 收益 |
| `snapshot`（截图） | ❌ 不适用 | 不是 iOS。macOS 截图靠 `screencapture -l <window-id>`（`scripts/ui-shot.sh`）—— **前提是有「屏幕录制」权限**（见 `1011_05` §11） |

⚠️ 还有一个**容易忽略的冲突**：`match` 会把证书装进钥匙串并**改动 Xcode 的签名设置**，
而本项目是 `CODE_SIGN_STYLE: Manual` + 写死 `CODE_SIGN_IDENTITY`。
「profile 与 entitlements 在 Xcode 管理与 match 管理之间漂移」是已知痛点 ——
一旦两套机制并存，签名问题会变得难以定位，而签名问题恰恰是**最难排查**的一类。

### 9.5 推荐的路径（比 fastlane 更省事，且不与既有决定冲突）

1. **证书与 profile 交给 Apple 自己的工具**：证书用 Xcode → Settings → Accounts →
   Manage Certificates；profile 在开发者网站建好后**不落盘到仓库**。
   单人单机时，`xcodebuild -allowProvisioningUpdates` + `PROVISIONING_PROFILE_SPECIFIER`
   是最少活动的方案 —— **密钥不出本机**，与既有决定一致。
2. **把「App Store Connect API key」变成唯一的密钥。** 同一把 `.p8`（+ Key ID + Issuer ID）
   既给 `notarytool --key` 用，也能给 ASC 上传用 ⇒ **一把钥匙替掉 Apple ID + app-specific
   password 两件秘密**。这同时补上 README 里记着的那个缺口：`env.sh` / `build.sh` 早就预留了
   `APPLE_API_KEY` / `APPLE_API_ISSUER`，但 **`notarize.sh` 目前只实现了 profile 与 Apple-ID 两条路** ——
   要用得先补。这是**当前就能做、且立刻减少秘密数量**的一步。
3. **要上 MAS 且嫌元数据填报烦**：只引入 fastlane 的 `deliver`（+ `pilot`），
   收敛成**一个 lane**；**不引入 `match`，不用 `gym` 替 `build.sh`**。
4. **别做的事**：不要让 fastlane 接管 `build.sh` / `notarize.sh` / `check-all.sh` / `check-release.sh`。
   这四个脚本里每一条都是踩出来的，换掉等于把知识从代码里赶回到人的记忆里。

### 9.6 顺序上的提醒

**现在讨论工具链优化，前提还没成立。** S1（沙盒里 adb 能否看见真机）**还没跑出结论**，
而它有可能直接判「MAS 这条路走不通」。给一条还没确认要走的路配工具，是典型的过早优化。

⇒ 顺序应该是：**先跑 S1 → 再决定要不要做 MAS → 要做的话再选工具**。
唯一现在就该做、且无论走不走 MAS 都受益的，是上面第 2 条（把凭据收敛成一把 ASC API key）。
