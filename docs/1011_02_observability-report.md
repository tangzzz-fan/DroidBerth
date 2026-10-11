# DroidBerth 可观测性方案：日志、崩溃收集与排障路径

> 分支 `feat/diagnostics`。对应你提的三个问题（有没有上报 / 怎么收集 crash / 有没有便捷方案）。
> 本文既是**分析**，也是**实施记录** —— 本轮已经落地，代码在 `macos/Sources/DroidBerth/Support/`。

---

## 0. 三问三答

| 你的问题 | 结论 |
| --- | --- |
| **① 当前项目有没有日志上报？** | **没有，一行都没有。** 全仓 `print(` 只有 **1 处**（在 `--spike-report` 里，而且只打印到 stdout）；`os_log` / `OSLog` / `Logger` / `NSLog` **0 处**；`URLSession` / 任何遥测 SDK **0 处**。工程里能算「诊断」的只有三样：sidecar 的 `doctor`、`--spike-report` 的 V1–V4、以及界面上那个验证面板。**出了事没有任何现场可查。** |
| **② adb crash / 用户 crash 怎么收集？** | 关键认识：这是**四类完全不同的故障**，各自要用不同手段，混在一起谈必然做不对（见 §2）。本轮四类都落了地：系统 `.ips`（app 崩溃）、`NSSetUncaughtExceptionHandler`（ObjC 异常，**系统不为它生成 `.ips`**）、会话哨兵（强退/掉电这类「没有信号的死亡」）、子进程失败的 stderr 尾部（adb / sidecar）+ **adb server 自愈**。 |
| **③ 有没有便捷方案？** | 有，而且**不要**为此引第三方 SDK。真正省事的是把「翻日志 → 跑命令 → 打包 → 发出来」压成**一次点击**（或一条命令）：本轮实现了 `导出诊断报告…` 菜单项与 `--export-diagnostics` 命令，产出**一个 zip**。第三方方案的对比与取舍见 §6。 |

---

## 1. 现状盘点（改造前）

### 1.1 有什么

| 资产 | 位置 | 它回答的问题 |
| --- | --- | --- |
| sidecar `doctor` | `sidecar/droidberth-adb doctor` | 「这个包自身完整吗」——bundle 里的 adb / sidecar 在不在、架构对不对 |
| `--spike-report`（V1–V4） | `Views/SpikeChecks.swift` | 「应然」层面的判据：进程封装、端到端 push/rm 能不能通 |
| 验证面板 | `Views/SpikeView.swift` + `SpikeReportWriter` | 同上，但是 GUI 一条路，JSON 落到 `~/Library/Application Support/DroidBerth/Reports/` |
| 界面提示（banner） | `AppModel.Banner` | **只有用户能看到** —— 关掉提示就没了，事后无从追溯 |

### 1.2 缺什么

- **没有历史**。`banner` 是唯一「发生了什么」的载体，而它是瞬时的。
- **崩溃现场为零**。用户说「它刚才闪退了」，开发者手上只有这一句话。
- **adb 的失败信息被丢掉了**。`ProcessRunner` 抓了 stderr，但失败后只把它拼成一句 `failureMessage` 交给界面，**不落盘**。
- **无法区分「没插设备」和「adb server 挂了」**。两者在界面上都是「设备栏空着」。

### 1.3 一处值得先说的认识

`PRD` 通篇没有提到日志与崩溃收集。这不是疏漏 —— 它是一份**产品**需求；而可观测性是**运维**需求，通常在第一次收到「用户说它不工作」时才被想起来。所以这一块是**独立于 PRD 的一层**，不该硬塞进 PRD 的章节里，但需要在 README 里给运维路径。

---

## 2. 故障的分类学（方案的全部依据）

先把「crash」拆开。不拆的话，任何方案都会退化成「加个 try/catch」：

| # | 故障 | 现场在哪 | 用什么 | 系统会不会自动给 |
| --- | --- | --- | --- | --- |
| 1 | **app 崩溃**（Swift 强制解包 nil、数组越界 trap、内存错误） | 进程被信号打死 | **系统 `.ips`**（`~/Library/Logs/DiagnosticReports/`），带全线程栈 | **会** |
| 2 | **未捕获的 Objective-C 异常**（`NSException`：`NSArray` 越界、显式抛出） | 进程 `abort()` | `NSSetUncaughtExceptionHandler` | **不会** ← 这是最容易漏的一格 |
| 3 | **异常退出但没有信号**（强制退出、掉电、`SIGKILL`） | 什么都没留下 | **会话哨兵**（启动写标记、正常退出补结束时间） | 不会 |
| 4 | **子进程故障**：adb / sidecar 崩了、起不来、超时 | 父进程手上有 stderr 与退出码 | 捕获 stderr 尾部 + 退出码 + 命令，落盘 | 不会 |
| 5 | **adb server 不可达**（`cannot connect to daemon` 之类） | 同上，但**可自愈** | 认出错措辞 → 重启 server → 重发一次 | 不会 |
| 6 | **设备侧失败**（未授权、被拒、空间不足） | 已有界面提示 | 把 banner 同时写进日志 | 不会 |
| 7 | **性能退化**（传得慢、界面卡） | 无 | **本轮未覆盖**，见 §9 | 不会 |

**第 2 与第 3 类是最容易漏的**，也是「为什么不能只靠系统崩溃报告」的答案。

---

## 3. 方案

### 3.1 为什么不自己写 signal handler

自己抓 `SIGSEGV` / `SIGABRT` 是这条路上最常见、也最容易做坏的一步：崩溃那一刻进程状态**已经不可信**（堆可能已损坏），在里面调 Foundation 会二次崩溃，反而把系统本来能生成的完整报告弄丢。

所以这里的取舍是：**不抢系统的活**。第 1 类交给系统 `.ips`（它写得比我们好，有全线程栈与二进制 UUID），我们只做系统不做的那几格（2–6）。

### 3.2 三层的职责

```
          ┌─ 统一日志（os.Logger, subsystem=dev.tango.droidberth）   ← 开发者在自己机器上查
AppLog ───┤
          └─ 磁盘文件 ~/Library/Logs/DroidBerth/*.log             ← 用户交回现场
                    ↑ 写入前脱敏（用户名 / 序列号 / 密钥指纹）

CrashSentinel ── 会话哨兵（session.json）+ 捡系统 .ips + 抓 ObjC 异常
                    ↓
DiagnosticsExporter ── 把上面所有东西 + 自检 + doctor + adb 现场打成**一个 zip**
```

**为什么双写**：统一日志在**开发者的机器上**很方便（`log show --predicate ...`），但它①在别人的机器上拿不到，②系统会滚动删除，③用户不知道去哪找。文件那一路才是「用户报障时能交回来的东西」。

**为什么按天分文件 + 保留 7 天 + 单文件 4 MB 滚动**：日志的价值随时间迅速衰减（一周前的传输失败没人会看），而磁盘空间是用户的。

---

## 4. 落地了什么

| 文件 | 作用 |
| --- | --- |
| `Support/AppLog.swift` | 日志核心：分级 / 分类 / 双写 / **写入即脱敏** / 按天分文件 + 轮转 + 保留 7 天。刻意**不引第三方框架** |
| `Support/CrashSentinel.swift` | 会话哨兵、系统 `.ips` 收集、`NSSetUncaughtExceptionHandler` |
| `Support/DiagnosticsExporter.swift` | 把现场打成一个 zip（含 8 类内容，见 §5） |
| `Support/ZipWriter.swift` | 自研的最小 ZIP 写入器（deflate + store）。**不用 `ditto`** —— 理由见 §5.1 |
| `Support/ADBRecovery.swift` | adb server 自愈：认出错措辞 → 重启 → 重发一次 |
| `Support/AppPaths.swift` | 新增 `logsDirectory`（`~/Library/Logs/DroidBerth/`，macOS 约定位置）、`diagnosticsDirectory`、`sessionFile` |
| `Sidecar/ProcessRunner.swift` | **失败才记**：spawn 失败 / 超时 / 非 0 退出，各带 stderr 尾部 |
| `ADB/DeviceShell.swift` · `ADB/DeviceMonitor.swift` | 接上自愈（`DeviceMonitor` 那处最关键：server 挂掉时 `devices` 返回空表，症状与「没插设备」一模一样） |
| `App/AppModel.swift` | `Banner` 的 init 里统一记日志（几十处调用点，逐个补必然漏）+ 导出动作 |
| `Transfer/TransferQueue.swift` | 传输失败记全「够定位」的字段 |
| `DroidBerthApp.swift` | 启动/退出钩子、帮助菜单两项、两个命令行入口 |
| `Views/SettingsView.swift` | 「诊断」区块（三行：日志路径 / 导出 / 在访达中显示） |
| `scripts/check-diagnostics-bundle.py` | **回归守卫**（7 条断言）：条目数 / 中文名 UTF-8 标志 / 无 `__MACOSX` / 无用户名泄露。见 §7 末 |

### 4.1 两条刻意的设计取舍

**① 成功不记日志。** 设备轮询每 1–5 秒一次 `adb devices -l`，把它们全写进去只会让真正出事的那行被埋掉。**只记失败**。

**② 写入即脱敏，而不是事后过滤。** 日志一旦落到磁盘，就可能在用户没意识到的情况下被转发。在写入那一刻把家目录用户名 → `~`、设备序列号 → 前 3 位、RSA 指纹 → 前两组，比事后承诺「我们不会看」可靠。

**③ `adb server` 自愈只认「客户端 ↔ server 之间」的措辞**，不是「失败了就重启」。后者会把重试浪费在设备侧问题上，还会把真实错误信息冲掉。敢对**写操作**也重发，依据是这一族故障意味着命令**压根没执行**。

---

## 5. 两条使用路径

### 用户侧（一次点击）

**帮助 → 导出诊断报告…** 生成 `~/Desktop/DroidBerth-diagnostics-<时间>.zip`，并在访达里选中它。zip 里：

| 内容 | 为什么在 |
| --- | --- |
| `环境.txt` | 版本 / macOS / 架构 / 是否在 `/Applications` / adb 与 sidecar 的定位 —— 一半问题看这几行就定性 |
| `上次会话.json` | 上次是否异常结束 + 窗口内找到几份系统崩溃报告 |
| `崩溃报告/` | 系统 `.ips`（已脱敏），带线程栈 |
| `未捕获异常.txt` | 只在出过 ObjC 异常时存在 |
| `日志/` | 应用日志（已脱敏） |
| `自检报告.txt` | V1–V4，判据是「应然」而不是「日志里有什么」 |
| `sidecar-doctor.json` | sidecar 自身的诊断 |
| `adb.txt` | adb 版本 + 5037 端口归谁（PRD §17 点名的坑） |
| `设备列表.txt` | 连了几台、什么状态（序列号已掩） |
| `说明.txt` | 里面是什么、脱敏了什么、以及「上次会话.json 怎么看」 |

### 开发者侧（一条命令，不需要开界面）

```bash
DroidBerth.app/Contents/MacOS/DroidBerth --diagnose              # 打印摘要：环境 / 上次是否异常结束 / 崩溃报告 / adb / 日志尾部
DroidBerth.app/Contents/MacOS/DroidBerth --export-diagnostics    # 生成 zip，打印路径
DroidBerth.app/Contents/MacOS/DroidBerth --export-diagnostics=/tmp   # 指定落点
```

命令行那条不只是给人用 —— 它也是**验收手段**：不需要人来点界面就能验证整条链路（本轮就是这么验的，见 §8）。

### 5.1 为什么自己写 ZIP 而不是调 `ditto`

诊断包里的文件名是中文（`环境.txt` / `日志/` / `崩溃报告/`），实测三种打包方式：

| 工具 | 中文名的 **UTF-8 标志位**（`0x0800`） | `__MACOSX/` 垃圾项 |
| --- | --- | --- |
| `/usr/bin/ditto -c -k --sequesterRsrc` | **没设**（只写了 `0x0008`） | 6–8 项 |
| `/usr/bin/ditto --norsrc --noextattr` | **没设** | 0 项 |
| `/usr/bin/zip -r -X` | **没设** | 0 项 |

「没设标志位」= 名字虽然按 UTF-8 写进去，但**规范上它声称自己是 `cp437`**。
macOS 自家工具（`ditto -x`、访达双击）一律假定 UTF-8 所以看不出问题 —— 实测解压后磁盘上的
名字是对的 —— 但 Windows 资源管理器、Linux 的 Info-ZIP、7-Zip 会按声明去解，得到乱码名。
这个包是**要发给别人**的，名字读不出来等于丢了一半信息。

自己写还顺带去掉一个外部子进程依赖 —— 诊断模块是「出事时才起作用」的那一层，
少一个可能在关键时刻不可用的依赖，比省下这 100 行更值。

**实现要点**：名字走 UTF-8 + 显式置 EFS 标志；压缩用 `Compression` 框架的
`COMPRESSION_ZLIB`（它给的就是**裸 DEFLATE**，正是 ZIP method 8 要的，不需要 zlib 头尾），
压不动时回退 `store`；目录项以 `/` 结尾并带 MS-DOS 目录位。

---

## 6. 便捷方案对比

| 方案 | 覆盖 | 优点 | 为什么（不）选 |
| --- | --- | --- | --- |
| **本轮的自建方案** | 1–6 类 | 零依赖、零网络、零费用；**不引入任何数据出境路径**；一个 zip 覆盖现场 | ✅ **选它**。这个 app 是 Developer ID 直发、自身就在做「不联网也能用」的事，为排障引一个联网 SDK 与产品气质冲突 |
| **Sentry（sentry-cocoa）** | 崩溃 + 性能 + 面包屑 | 崩溃聚合成 issue、有栈、有版本分布；免费额度够个人用 | 需要账号 / DSN / 网络；**默认会把设备与用户信息发到第三方**，需要改隐私声明；崩溃上报本身也该让用户知情同意。**适合将来上架 / 用户量上来之后**，不是现在 |
| **PLCrashReporter / KSCrash** | 崩溃 | 成熟的进程内崩溃捕获，能抓到系统 `.ips` 也有的信号类崩溃 | 只解决 §2 的第 1 类（而系统已经免费给了），且要自己建收集端。**投入产出不划算** |
| **MetricKit** | 崩溃 / 卡顿 / 电量 | 系统级、无需第三方 | **面向 App Store / TestFlight 分发**；Developer ID 直发的包拿不到。而且它异步投递、延迟可达一天 |
| **Xcode Organizer** | 崩溃 | 聚合最好 | 同样只对 App Store 分发有效 |
| **`sysdiagnose` / `log show`** | 系统级 | 信息最全 | **体积巨大（几百 MB）且含系统级隐私信息**，不该让用户交这个。开发者自己在**自己**机器上排查时可以用 |

**结论**：现在这一层（自建 + 一个 zip）已经能回答「用户报障时我需要什么」。Sentry 那条路留到有真实用户量、且愿意改隐私声明时再上。

---

## 7. 隐私

三条硬规则，都写进了代码注释：

1. **写入即脱敏**（家目录路径 + JSON 转义形式 / 序列号 / 指纹），不是事后过滤。
2. **没有任何自动上传**。诊断包只生成在用户机器上，要不要发、发给谁由用户决定（`说明.txt` 里也是这么写的）。
3. **用户可以只发一部分**。`说明.txt` 明确告诉他：删掉 `日志/` 与 `崩溃报告/` 两个目录再发也足以定位大多数问题。

补两条**判据层面**的：

4. **不含路径的隐私要单独处理。** 路径替换只能盖住「以路径形式出现的用户名」；
   `lsof` 那种「属主列」是裸 token，抓不到。**这类只能从源头不输出**。
5. **脱敏的判据要精确，否则会误报。** bundle 标识符天然含用户名
   （`dev.<用户名>.droidberth`），把它当泄露会让守卫天天报警，最后被人关掉。
   **一个持续误报的判据等于没有判据。**

这一层有**自己的回归守卫**：`scripts/check-diagnostics-bundle.py`（7 条断言）——
它第一次跑就抓出了上面这两处真泄露。这与 `check-icon-mapping.swift` 同一个思路：
**把「打开产物来看一眼」这件事自动化掉**，因为这类缺陷没有任何编译期信号。

与 PRD §28 的关系：公证与「隐私声明」是发布前的事，**这一层不改变它** —— 因为没有任何数据离开用户机器。等真要接 Sentry 时，才需要动隐私声明。

---

## 8. 验证（本轮实跑）

| 项 | 结果 |
| --- | --- |
| `swiftc -typecheck`（全量，`-strict-concurrency=complete`） | 0 输出、退出码 0 |
| `xcodebuild Release` | **BUILD SUCCEEDED**，0 error / 0 warning |
| 新文件已进工程 | 5 个（`xcodegen generate` 后逐个核对 `project.pbxproj`） || `--spike-report` | `V1=pass V2=fail V3=pass V4=manual`（4.2 s；V2 属发布前动作） |
| `--diagnose` | 0.2 s 出摘要 |
| `--export-diagnostics`（**裸**） | 5.4 s，落桌面 |
| `--export-diagnostics <目录>`（空格形式） | 5.4 s |
| `--export-diagnostics=<目录>`（**等号形式**） | 5.8 s ← **原先这条是坏的**，见下 |
| 未识别参数 | 往 stderr 提示后按普通启动处理 |
| 包内容 | **11 个条目**、`unzip -t` 无错、`ditto -x` 与 `unzip` 解出的中文名均正确 |
| 脱敏 | 包里搜不到用户名 `tango`（`grep -r`） |
| 旧回归未被破坏 | `check-icon-mapping.swift`（77 扩展名）与 `check-transfer-semantics.swift` 均 **ALL OK** |
| **新增守卫** `scripts/check-diagnostics-bundle.py` | **ALL OK（7 项）** —— 首跑即抓出下面第 ③ 条真泄露 |

### 8.1 验证中挖出的两个真缺陷（都已修）

**① 等号形式的命令行参数静默落到 GUI。**

`firstIndex(where: { $0 == "--export-diagnostics" })` 是**精确相等**匹配，于是
`--export-diagnostics=/tmp/out` 匹配不上，悄悄走 `DroidBerthApp.main()` 起界面。
在终端里的表现是**命令挂住不返回**（图形进程不会自己退出），且**不报任何错** ——
第一次实跑就是这样，白追了一轮（日志里留下了铁证：那次「导出」的运行记录里有
`应用启动完成（界面已就绪）`，那是 `applicationDidFinishLaunching` 才写的）。
已改成前缀匹配，并加了「未识别 `--xxx` 往 stderr 说一句」的兜底。

**② ZIP 里只有一个根目录条目 —— 空包。**

`zipEntries` 原本用 `FileManager.enumerator` + `url.path.hasPrefix(root.path)`，
结果整个包只有 1 个条目。根因是**符号链接**：`root.path` 是 `/tmp/...`，
而枚举器返回的是**解析过符号链接**的 `/private/tmp/...`，前缀判断对每个子项都为假，
全部被静默跳过 —— 不报错、不警告，产出一个「能解压但空」的包。
已改成从根自己递归、子项路径用 `lastPathComponent` 逐级拼，**全程不碰绝对路径**。

> **教训（已记进项目笔记）**：不要拿绝对路径做前缀匹配 —— 同一个目录在
> `/tmp` 与 `/private/tmp` 下有两个不同的字符串形式。而且这类缺陷**没有任何报错**，
> 只有把产物打开来数条目才会发现。

**③ 脱敏漏了两处 —— 打包出来的包里能读到本机用户名。**

是新增的守卫脚本（`scripts/check-diagnostics-bundle.py`）第一次跑就抓到的：

| 来源 | 漏出来的样子 | 根因 |
| --- | --- | --- |
| `adb.txt` | `adb 41421 **tango** 16u … TCP 127.0.0.1:5037` | `lsof` 默认输出的**进程属主列**，那是用户名但**不是路径**，路径替换抓不到 |
| `本次会话.json` / `上次会话.json` | `"bundlePath" : "\/Users\/tango\/…"` | 这两份 JSON **完全没走脱敏**；而且 `JSONEncoder` 把 `/` 转义成 `\/`，**就算走了也匹配不上** |

修法分别是：
- `port5197Owner` 改用 `lsof -F pcn` 的**字段化输出**（只要 pid / 命令 / 地址），
  从源头不输出属主列 —— 排障只需要知道「谁在监听、是不是我们自己那个 adb」，用户名无用。
- 会话档改成**编码前脱敏结构体字段**（`redactedForExport`），而不是编码后替换文本；
  `AppLog.redact` 同时补上 JSON 转义形式（`\/Users\/x`）的替换。

**一处刻意不脱敏**：`sidecar-doctor.json` 里的 `"identifier": "dev.tango.droidberth"`。
那是 bundle 标识符，公开且排障时有用；把用户名当裸词全局替换会连它一起毁掉。
守卫脚本为此加了「先把标识符替掉再找用户名」这一步 —— **判据太粗会天天误报，
然后被人无视**，和没有判据一样糟。

---

## 9. 未做 / 后续

| 项 | 说明 |
| --- | --- |
| **性能退化（第 7 类）** | 传得慢、界面卡，目前没有任何埋点。真要做得上 signpost（`os_signpost`）量传输各阶段耗时 —— 那是独立的一轮 |
| **日志里的「一次传输的完整时间线」** | 现在只有失败那条记了一行。给每个 job 记开始/结束/字节数，才能回答「为什么这次慢」 |
| **诊断包体积** | 会跑一遍自检（含一次 `push`/`rm`），在有设备时会操作设备。要不要在无设备时跳过 V4 —— 已由 `SpikeChecks` 自己判为 `manual`，不必额外处理 |
| **自动附带 `banner` 历史** | banner 现在只进日志（按顺序），诊断包里没有单独的「用户看到过什么」一节。日志里已经能看，暂不单列 |
| **Sentry 之类的托管方案** | 见 §6，留到有用户量之后 |
| **zip 只在 macOS 上验过** | 已验：`unzip -t` 无错、`ditto -x` 与 `unzip` 解出的中文名正确、Python `zipfile` 按规范读出的名字与标志位都对。**没在 Windows / Linux 上实机验过** —— 那需要一台别的机器。补一句实测到的坑：macOS 自带的 `unzip 6.00`（Apple 改版）在 `-l` 列表里**不认** EFS 标志，中文名照样显示成 `τÄ»σóâ` 那种乱码，**但解压到磁盘是对的** —— 别拿 `unzip -l` 的显示去判断包的编码
