# DroidBerth 设备端验收报告（2026-10-11）

> **环境**：macOS 本机 + Android **17 / API 37** 模拟器 `Pixel_10`
> （`sdk_gphone16k_arm64`，**16 KB 页**，`ro.build.type=user`、`ro.debuggable=0` ⇒ 无 `adb root`）
> **依据**：用户 2026-10-11 的要求 —— **先在 17 上测，以当前可用环境为准**
> **原始日志与脚本**：`docs/device-acceptance/2026-10-11/`（5 份日志 + 5 个可重跑脚本）
> **范围边界**：PRD §5 声明支持 **Android 10–16**，API 37 **在声明范围之外**。
> 本报告回答「新版还能不能用」，**不替代**声明范围内的验收。

---

## 0. 结论摘要

自动化能覆盖的部分**全部跑通**（自检 `V1=pass V2=fail V3=pass V4=pass`、`df` 解析正确、媒体自动入库）。
但量出**两条真缺陷**，并**推翻了代码里的两处前提**：

| # | 结论 | 级别 | 证据 | 状态 |
|---|---|---|---|---|
| **F1** | **远端缩略图成品率只有 3/8**，视频**全部失败**。而且失败的机制**不是 PRD 预言的那一个** | P0（功能） | §1 | **已修**（§9.2） |
| **F2** | **上传方向在不区分大小写的设备卷上会静默覆盖**用户手机上的文件 —— 而默认策略正是承诺「保留两者」。**同族还有两处**（重命名、移动），一并修掉 | P0（数据丢失） | §2 | **已修**（§9.1） |
| **F3** | 重命名长度校验用**字符数**，设备端用**字节数**：100 个汉字 / 200 个 emoji 能通过校验，但在设备上 `File name too long` | P1 | §3.2 | **已修**（§9.3） |
| **F4** | 设备端**自己就拒绝** FAT32 的非法字符集（`EPERM`）⇒ app 的校验缺口是**提示质量问题**，**不是**数据安全问题（比原先判断的轻） | P2 | §3.1 | **已修**（§9.3） |
| **F5** | `/sdcard` **不区分大小写**，且折叠规则与 macOS 默认卷**完全是同一张表**（含 `ß`↔`ss`、`ﬁ`↔`fi` 这类**完整**大小写折叠） | P0/P1 | §2 | 已并入 F2 的修法 |

**三处要改的既有陈述**在 §7。**本环境测不到的项**在 §8。**决定与实施**在 §9。

---

## 1. F1 · 远端缩略图成品率（PRD §13.3 的未验证项）

### 方法

复刻 `ThumbnailStore.startRemote` 的真实路径，一步不改：

```
adb -s <serial> exec-out "dd if='<远端路径>' bs=1024 count=64 2>/dev/null"
  → 落成【原文件名】的临时文件（AppPaths.makeThumbnailScratchFile 保留原名与扩展名）
  → QLThumbnailGenerator.Request(size: 512×512, scale: 1, .thumbnail)
```

**对照组**：同一文件的完整拉取过同一个探针。对照组 8/8 全 OK ⇒ 失败与截断有关，与文件本身无关。
判据是「能不能出图」，与 app 的 `.loaded` / `.unavailable` 一一对应。

### 结果（取头 64 KB，`ThumbnailConstants.remoteHeaderBytes` 的原值）

| 文件 | 远端大小 | 64 KB 头 | 完整文件 |
|---|---|---|---|
| photo.jpg | 1.58 MB | **OK** | OK |
| photo.png | 1.08 MB | **OK** | OK |
| photo.heic | 120 KB | **OK** | OK |
| photo.gif | 730 KB | fail | OK |
| photo.tiff | 15.7 MB | fail | OK |
| video-faststart.mp4（moov @28） | 1.78 MB | fail | OK |
| video-moovlast.mp4（moov @尾） | 1.78 MB | fail | OK |
| video.mov（moov @尾） | 701 KB | fail | OK |

**成品率 = 3 / 8 = 37.5%。** 取头本身很快（90–195 ms/条，主要是一次 adb 往返的开销）。

### 机制：不是 PRD 说的那个原因

PRD §13.3 写的是「**JPEG 通常能解出部分图像，但 HEIC / 视频容器（尤其 moov 在文件尾的 MP4）很可能解不出来**」。
把取头量做成一条曲线之后，这句话**两半都不准**：

| 文件 | 64 KB | 128 KB | 256 KB | 512 KB | 1 MB | 4 MB | 完整 |
|---|---|---|---|---|---|---|---|
| photo.jpg / png / heic | OK | OK | OK | OK | OK | OK | OK |
| photo.gif (730 KB) | — | — | — | — | **OK** | OK | OK |
| video-faststart.mp4 (1.78 MB) | — | — | — | — | **OK** | OK | OK |
| video-moovlast.mp4 (1.78 MB) | — | — | — | — | — | **OK** | OK |
| video.mov (701 KB) | — | — | — | — | **OK** | OK | OK |
| photo.tiff (15.7 MB) | — | — | — | — | — | — | **OK** |

读出来的三件事：

1. **HEIC 完全没问题** —— PRD 猜它「很可能解不出来」，实测 64 KB 就够。它是 `moov` 类容器，
   但 HEIC 的元数据 `meta` box 在文件头，64 KB 里既有索引也有足够一帧的数据。
2. **视频失败的头号原因不是 moov 位置，而是 mdat 字节数不够。**
   同尺寸的 `faststart`（moov 在头）在 512 KB 时仍然失败、1 MB 才成功；
   而 `moov` 在尾的那个要**整个文件**（4 MB 那次等于整文件，1.78 MB）。
   ⇒ moov 位置**是一个真实的额外代价**（同尺寸文件 1 MB vs 18 MB 的差别），但**不是**唯一原因。
3. **TIFF 要整个文件**（15.7 MB）⇒ 它根本不该进这条通道。

### 处置

**已拍板并实施**：走**方案甲**的变体 —— 远端**只做图片**，并且**只做本地能做、远端也不确定的那一侧**
（本地仍保留视频缩略图，因为文件就在本机，实测 8/8 全通过）；已知必失败的 gif/tiff 连请求都不发。
判据集中在 `ThumbnailPolicy`（纯函数，可单测）。理由与取舍见 §9.2。

---

## 2. F2 / F5 · 设备卷的大小写与归一化语义（**最严重的一条**）

### 实测

| 测法 | 结果 |
|---|---|
| `touch Case.txt` 后 `test -f case.txt` | **FOUND** |
| 先建 `Case.txt`，再建 `case.txt` | 两条都成功，但目录里**只有一个**文件（`Case.txt`） |
| `touch Report.txt` → `touch report.txt` → 写 `REPORT.txt` | 三次写入**落到同一个文件** |
| `adb push Report.txt`（内容 AAAA）→ `adb push report.txt`（内容 BBBB） | 目录里只剩 `report.txt`，**内容是 BBBB** ⇒ 第二个 push **静默替换**了第一个 |
| 分别建 NFC `café.txt` 与 NFD `cafe\U0301.txt` | 只剩**一个**文件，`od -c` 显示是 **NFC**（`caf 303 251 .txt`） |

⇒ 设备端 `/sdcard` 是**不区分大小写**的卷。

### 折叠维度不止「大小写」—— 两侧是**同一张表**

第一轮只测了大小写与 NFC。把「近似等价关系」往深挖一层才发现，真正的规则是
**Unicode 完整大小写折叠**（`CaseFolding.txt` 的 C+F 映射），而且
**macOS 默认卷（APFS）与设备端折叠的是完全相同的一组**：

| 对 | macOS `/tmp`（APFS 默认卷） | Android `/sdcard`（FUSE） |
|---|---|---|
| `IMG.JPG` ↔ `img.jpg` | **折叠** | **折叠** |
| `café`（NFC）↔ `café`（NFD） | **折叠** | **折叠** |
| `ß.txt` ↔ `ss.txt` | **折叠** | **折叠** |
| `ﬁle.txt` ↔ `file.txt`（连字） | **折叠** | **折叠** |
| `K.txt`（KELVIN U+212A）↔ `k.txt` | **折叠** | **折叠** |
| `Å.txt`（ANGSTROM U+212B）↔ `Å.txt`（U+00C5） | **折叠** | **折叠** |
| `σ` ↔ `ς`（希腊词尾 sigma） | **折叠** | **折叠** |
| `İ`（U+0130）↔ `i`+组合点 | **折叠** | **折叠** |
| `A.txt` ↔ 全角 `Ａ.txt` | 不折叠 | 不折叠 |
| `o.txt` ↔ 带圈 `ⓞ.txt` | 不折叠 | 不折叠 |
| `café.txt` ↔ `cafe.txt` | 不折叠 | 不折叠 |
| `a.txt` ↔ `a.txt `（尾随空格） | 不折叠 | 不折叠 |
| `a.txt` ↔ `a.txt.`（尾随点） | 不折叠 | 不折叠 |

判据是拿四个「**只有完整折叠才会折叠**」的字符去两侧试出来的：KELVIN / ANGSTROM /
词尾 sigma / `İ` 全部折叠，而阴性对照 `é`↔`e`、`ﬁ`↔`f` 都不折叠。
证据：`06-name-fold.txt`（设备端第一轮）、`08-two-sided-fold.txt`（两侧对照）、
`07-fold-recipe.txt`（Swift 侧四个候选配方的对比）。

**这条结论让实现变简单了**：两侧同一张表 ⇒ `NameComparison.folded` 一个公式对两侧都对，
不需要按侧分叉。而「全角不折叠、尾随空格不折叠」也各有实测支撑，不该顺手加进去
（会多出无缘无故的 ` (1)`）。

> **一处需要更正我自己的说法**：NFC/NFD 其实**不构成**独立的缺陷路径 ——
> Swift 的 `String ==` 与 `Set.contains` 本来就按 **Unicode 规范等价**比较，
> 所以旧代码里的 `Set<String>` 已经处理了 NFC。
> 真正漏掉的是**大小写**与**完整折叠**（`ß`/`ﬁ`/`ς` 与规范化是两回事，它们是大小写折叠映射）。
> 用 `lowercased()` 也不够：它**不做完整折叠**（`ß` 不动、`ﬁ` 不动），四个候选配方里它错 3 项。

### 为什么这是数据丢失

`TransferPlanner.upload` 的冲突检测是**精确字符串比较**：

```swift
existingByDirectory[directory] = Set(entries.map { $0.name })   // 设备上已有的名字
if policy == .keepBoth, var taken = existingByDirectory[directory], taken.contains(name) {
```

而 `AppSettings.conflictPolicy` 的默认值是 **`.keepBoth`（保留两者）**。
于是：Mac 上上传 `photo.jpg`、设备上已有 `Photo.JPG` →
`taken.contains("photo.jpg")` **为假** → 判为「不冲突」→ 计划里 `remotePath` 就是 `.../photo.jpg`
→ `adb push` 在不区分大小写的卷上**替换掉 `Photo.JPG`**。

**用户手机上原有的文件没了，而设置里写着「保留两者」，界面上也不会报任何冲突。**
更隐蔽的一点：文件名**保持不变**（仍是 `Photo.JPG`），只是内容被换掉了 ——
所以事后连「哪个文件被动过」都不容易看出来。

### 同一族还有两处（本轮一并修掉）

按同一个判据把全仓的「同名比较」扫了一遍，另有两处是同一个形状：

| 位置 | 后果 |
|---|---|
| `AppModel.renameRemoteEntry`：`remoteEntries.contains(where: { $0.path == destination })` | 把 `b.txt` 改名成 `A.TXT` 时，设备上已有的 `a.txt` 被判为「不冲突」⇒ `mv` 覆盖它的内容 |
| `AppModel.moveRemotePaths`：`Set(listed.map(\.name))` + `contains` | 把 `photo.jpg` 移进已有 `Photo.JPG` 的目录 ⇒ `mv` 覆盖 |
| `AppModel.makeRemoteDirectory`：**完全没有冲突检查** | `mkdir -p` 对已存在的目录静默成功，而 `Photos` 与 `photos` 是同一个目录 ⇒ 「新建」退化成一次看不出问题的空动作（PRD §16 要求「重名时提示」） |

### 代码里的前提是错的

`TransferPlanner.conflictKey` 的注释写着：

> **上传方向刻意不折叠**：设备端主存储是 ext4 / f2fs 派生，确实区分大小写；而 FAT32 格式的 SD 卡不区分 —— 那一种要等真机实测后再定

实测推翻了前半句：**`/sdcard` 这一层（MediaProvider 的 FUSE）本身就不区分大小写**，
底下的 ext4 是否区分已经不重要 —— 用户面对的是 FUSE 这一层。
（下载方向不受影响：它用的是本机目标卷的 `volumeSupportsCaseSensitiveNames`，本机默认卷 → `false` → 会折叠。）

### 处置

**已拍板并实施**：上传方向**无条件折叠**，判据集中在 `NameComparison`；
冲突判定与改名抽成 `NameConflict`（纯函数，可单测）。理由与取舍见 §9.1。

---

## 3. 文件名（PRD §16 的待验证项）

### 3.1 合法字符集：**设备端自己就拒绝**

逐字符测了两条通道 —— 设备端 `touch`（重命名 / 移动走的 `mv` 通道）与 `adb push`（上传通道）。
两条通道的被拒集合**完全一致**：

| 字符 | 设备端结果 | 错误原文 |
|---|---|---|
| `:` `*` `?` `"` `<` `>` `\|` `\` 制表符 | **拒绝** | `Operation not permitted`（EPERM） |
| `'` `` ` `` `$` `;` `&` 空格 | 通过 | — |
| 中文 / emoji / 点前缀 / 前导 `-` / `~` `#` `%` `( ) [ ] { }` | 通过 | — |

**这是本次最有用的「坏消息里的好消息」**：被拒的正是 FAT32 明令禁止的那一组，
而拒绝者是 **Android 存储层自己**（为保持卷与 MTP 的 FAT 兼容语义），不是底层 ext4。
所以 `AppModel.validateRemoteName` 现在不挡 `: * ? " < > |`，**不会造成数据损坏** ——
操作会失败，`banner` 会报 `重命名失败：mv: '/sdcard/.../a:b.txt': Operation not permitted`。

⇒ 优先级从「数据安全」降到 **P2 提示质量**：校验前移能把错误文案从 errno 原文变成
「名称不能包含「:」」，并且在用户提交**之前**就禁用「确定」，而不是提交后再报错。

### 3.2 长度：字符数 vs 字节数 —— **这条是真缺口**

| 名称 | 字节数 | 字符数 | app 判据（`name.count > 255`） | 设备端 |
|---|---|---|---|---|
| `x`×251 + `.txt` | **255** | 255 | 放行 | **成功**（边界） |
| `x`×255 + `.txt` | 259 | 259 | 拒绝 | 失败 |
| 100 个汉字 + `.txt` | 304 | 104 | **放行** | **失败 `File name too long`** |
| 200 个 emoji + `.txt` | 804 | 204 | **放行** | **失败 `File name too long`** |
| 85 个汉字 + `.txt` | 259 | 89 | 放行 | 失败 |

设备端的限制是 **255 UTF-8 字节**（`NAME_MAX`），而 app 数的是 Swift `Character`
（字素簇）。汉字 3 字节、emoji 4 字节 ⇒ **64 个汉字或 emoji 之后就必然超**。

**修法**：把判据从 `name.count > 255` 改成 `name.utf8.count > 255`。
字符数 ≤ 字节数，所以后者严格更强，且正是设备的判据。错误文案也应改成
「名称过长（最多 255 字节；一个汉字占 3 字节）」。

---

## 4. Android/data 与存储卷（PRD §12.2）

| 路径 | 结果 | 备注 |
|---|---|---|
| `/sdcard/Android/data` 根 | **可写** | 与 PRD §12.2 的假设相反（真机 Android 11+ 通常不可写） |
| `/sdcard/Android/data/<某应用>` | **测不到** | 设备上 `Android/data/` 是**空的** —— 没有任何应用建过外部目录 |
| `/sdcard/Android/obb` 根 | **可写** | 同上 |
| `/sdcard/Android/media` | **可写** | |
| `/storage` 下的卷 | 只有 `emulated`（`/storage/emulated/0`）与 `self` | **没有 SD 卡** ⇒ §12.2 的「内部存储 / SD 卡」卷枚举**在本环境测不到** |

- 上一轮复核里「不可写」的那条是**我的测试写错了**：挑的 `com.android.settings` 外部目录
  根本不存在，错误是 `No such file or directory` 而不是 `Permission denied`。已改正。
- 模拟器的 `shell` 用户被授予了 `ext_data_rw` / `ext_obb_rw` 组，所以根可写。
  **涉及设备端权限的结论不能只靠模拟器** —— 这一条仍然有效，§12.2 需真机复核。

---

## 5. 媒体入库（PRD §19，产品风险最高的一项）

| 项 | 结果 |
|---|---|
| `cmd -l` 里有没有扫描服务 | **都没有**（`media_scanner` / `media.scan` 均不存在，共 324 个服务）⇒ app 会选 **`broadcast` 兜底** |
| 广播兜底能不能跑 | `Broadcast completed: result=0`（能跑，但结果码 0 不代表真扫了） |
| jpg 推到 `DCIM/` | **立刻查到** ⇒ API 37 **自动入库**（印证 PRD §19.2 的推断） |
| png 推到 `Download/` | 也**立刻查到** ⇒ Download 是标准媒体目录 |
| heic 推到**自建目录** `/sdcard/DroidBerthProbeNoScan/` | **也立刻查到** ⇒ 自动入库**不限于标准目录** |
| `.txt` 推到 `DCIM/` | 表 = `nil` ⇒ 非媒体，app 保持**沉默**（三态设计正确） |
| `_data LIKE '%/name'` 的大小写 | 用**小写** `caseprobe.jpg` 查到了设备上的 `CaseProbe.jpg` ⇒ **SQLite 的 LIKE 对 ASCII 不区分大小写** |

最后一条很重要：它证明 `MediaScanner.isIndexed` 里那个「再按 basename 精确核一遍」**不是多余的**
—— 少了它，查 `a.jpg` 会命中 `A.jpg` 并报「已进入相册索引」，而那个文件根本不存在。

**结论**：在 API 37 上「入库」几乎总是自动完成的，`.notIndexed` 这个状态**很难被触发**。
三态逻辑本身正确，但它在这台设备上大概率只会输出「已进入相册索引」。
⇒ PRD §19 的成败点仍需**在 Android 10 / 13 / 15 上**验证（那里才是「推过去看不见」的高发区）。

---

## 6. 解析正确性核对（顺带验证，都通过）

| 代码 | 实测 |
|---|---|
| `DeviceShell.availableBytes`：`df -k <path>` 取 `fields[3]` | `['/dev/fuse','10167132','709628','9310048','8%',...]` → 取到 `9310048 KB` = **8.88 GiB** ✅ 字段位置正确 |
| `MediaScanner.isIndexed` 的 `_data LIKE` 后缀匹配 | MediaStore 存 `/storage/emulated/0/...`、app 用 `/sdcard/...` ⇒ **后缀匹配是必需的**，等值匹配会永远查不到 ✅ |
| 自检 `--spike-report` | `SUMMARY: V1=pass V2=fail V3=pass V4=pass`（V2 的 fail 是未公证 / 未装 `/Applications`，属发布前动作，非缺陷） ✅ |
| `[manual] #9 adb.port_5037` | 5037 被 SDK 的 adb 占用（pid 27723）—— 与本项目内嵌的 adb **逐字节相同** ⇒ 版本不一致的风险在这台机器上不存在 |

**顺带记录一条性能基线**（**不代表真机**）：`adb push` 64 MB → **≈350–375 MB/s**（模拟器走内存）。
PRD 附录 B #3「传输开销 ≤ 裸 `adb push` 的 110%」**仍无法在此验收** —— 它要 app 的传输队列真的跑起来（GUI），
模拟器吞吐又说明不了真机性能。

---

## 7. 要改的既有陈述（文档与代码注释）

| 位置 | 现在写的 | 实测 |
|---|---|---|
| `TransferPlanner.conflictKey` 注释 | 「设备端主存储是 ext4 / f2fs 派生，**确实区分大小写**」 | **不成立**：`/sdcard`（FUSE 层）不区分大小写并归一化到 NFC |
| PRD §13.3 | 「JPEG 通常能解出部分图像，但 **HEIC / 视频**很可能解不出来」 | HEIC **没问题**；视频失败的真因是 **mdat 字节数**，moov 位置是次要因素 |
| README「已实测（Android 模拟器）」一节 | AVD 是 `Medium_Phone_API_37.0` | 已换为 **`Pixel_10`**（API 37，**16 KB 页**） |

---

## 8. 本环境**测不到**的项（不要误读为「已验证」）

| 项 | 为什么测不到 |
|---|---|
| 媒体入库在 **Android 10 / 13 / 15** 上逐版本（附录 B #1） | SDK 里只有 API 37 一个镜像 |
| `/sdcard/Android/data/<别的应用>` 不可写（§12.2） | 模拟器上该目录是空的；且模拟器 shell 有 `ext_data_rw` |
| **卷枚举 / SD 卡**（§12.2、附录 B #2） | 模拟器没有可移除卷 |
| `tcpip 5555` 在 11+ 上的行为（附录 B #2） | 对正在使用的模拟器切传输方式有风险，未做 |
| 多设备并发（附录 B #7） | 只有一个 AVD 在跑 |
| 干净 macOS VM 复验（附录 B #11） | 需要 VM |
| 传输开销 ≤ 110%（附录 B #3） | 需要 GUI 跑起来；模拟器吞吐无意义 |
| 交互层体感（附录 B #16）：拖拽 / ⌘C⌘V / Quick Look / 网格 / 预览窗格 / 分栏 | **需要你人工操作** |
| 厂商品牌文案（小米 / OPPO / vivo） | 本机是 Google 模拟器（`ro.product.brand=google`）⇒ 那条分支走不到 |
| 图标观感、四类空态与引导卡片的运行时行为 | 需要人工看 |

---

## 9. 决定与实施（2026-10-11 拍板，已落地）

原则：**尽量让用户看到的交互是简洁的**。两个决定都按这条推出来的 ——
**可预期 > 覆盖得广**，而且两条的修法都是**把判据收进一个纯函数**（而不是在调用点各写一遍），
所以顺带把这一族缺陷的其他实例一起收掉了。

### 9.1 上传方向的「同名」判定 → **无条件折叠**

**怎么定的**：两个候选是「运行时探测目标卷的大小写语义」与「无条件折叠」。
选后者，理由是：

1. **探测自己会失败。** 它要在用户的目标目录里建临时文件 —— 目录只读、权限被拒、超时都得兜底，
   于是多出一个状态机与一个「探测失败时按哪边」的二次决策。而折叠只需要一个纯函数。
2. **探测是多余的。** 复核把两侧的折叠表量完之后，结论是 **macOS 默认卷与设备端折叠的是同一张表**
   （§2）—— 既然两侧一样，就没有「按卷决定」的必要。
3. **误判代价不对称。** 多折一次最多多出一个 ` (1)`（碍眼）；少折一次是**丢用户手机上的数据**。
   这与 `NameComparison` 里「取不到卷信息时按不区分处理」是同一条推理。

**改了什么**：

| 文件 | 变化 |
|---|---|
| **新增** `Support/NameComparison.swift` | 折叠规则的唯一入口。`folding(options: .caseInsensitive)` + NFC —— **不用 `lowercased()`**（它不做完整折叠，四个候选配方里错 3 项） |
| **新增** `Transfer/NameConflict.swift` | 冲突判定与改名（纯函数）：`foldedSet` / `conflicting(_:existing:excluding:)` / `keepBothName(for:taken:)` |
| `Transfer/TransferPlanner.swift` | 上传：设备上已有的名字**也折叠**后再比；改名走 `NameConflict`。下载：`conflictKey` 转发给 `NameComparison.key` |
| `App/AppModel.swift` | **重命名**与**移动**的冲突预检同样折叠（原先也是精确比较，同样会静默覆盖）；**新建文件夹**补上缺失的冲突检查（PRD §16 要求「重名时提示」） |

`excluding:` 参数专为「重命名」而设：把 `a.txt` 改成 `A.txt` 是按折叠判据当然会与自己冲突，
但它是**合法**的改大小写操作，所以要把被改的那一项本身排除掉。

### 9.2 远端缩略图 → **只做图片，且只在能保证成功的地方做**

**怎么定的**：三个候选（甲：只做 jpg/png/heic；乙：按类型分档到 1 MB；丙：小文件直接拉整文件）。
选**甲的变体**：

1. **视频的成败取决于容器的 `moov` 位置 —— 用户既看不见也猜不到。**
   后果是同一批视频「有的有缩略图、有的没有」，而且看起来随机。**稳定地没有，好过不稳定地有**：
   前者用户能建立预期（视频就是类型图标），后者只会让人觉得这个 app 时好时坏。
2. **不做假承诺。** 走乙的话，每条视频要拉 1 MB 头 —— 对 1.78 MB 的文件是 57% 的流量，
   而**结果仍然不确定**。花了大代价买到一个不确定的收益，是这笔账最难看的地方。
3. **本地那一侧照做。** `QLThumbnailGenerator` 对完整文件实测 8/8 全通过 ⇒
   这不是「砍掉视频缩略图」，而是**只在能保证成功的那一侧做**。
4. **已知必失败的连请求都不发**（gif / tif / tiff）。省下的不只是一次 64 KB 往返：
   `EntryGrid` 在 `.loading` 时显示 `ProgressView`，不请求就直接落到类型图标 ⇒
   也省掉了「转圈 → 还是类型图标」的闪烁。

**改了什么**：

| 文件 | 变化 |
|---|---|
| **新增** `Support/ThumbnailPolicy.swift` | `allowsLocalFile` / `allowsRemoteFile` / `isKnownRemoteFailure` |
| `Support/ThumbnailStore.swift` | `isThumbnailable` 改为按来源分派给 `ThumbnailPolicy`，自身只剩「目录不做」这一条 |

要恢复远端视频预览，应该另开一条**能保证成功**的通道（例如按需下载完整文件、
或在设备端生成），而不是把取头量往上加着碰运气。这条列为后续候选，不在本轮。

### 9.3 顺带一起对齐的两条（都在同一族里，一起改成本最低）

| # | 动作 | 依据 |
|---|---|---|
| 3 | **名称长度校验从「字符数」改成「UTF-8 字节数」**（新增 `Support/DeviceNameRules.swift`，`AppModel.validateRemoteName` 转发） | 设备端限 255 **字节**，而旧校验数的是 Swift 字素簇：100 个汉字（304 字节）/ 200 个 emoji（804 字节）通过校验却在设备上 `File name too long` |
| 4 | **`: * ? " < > \| \` 制表符的前置提示**（同上文件） | 设备端自己就拒（`EPERM`）。前移不是为了挡下本来能成功的操作，而是把 `mv: '...': Operation not permitted` 换成人话，并在提交**之前**禁用「确定」 |

### 9.4 对应的测试

| 产物 | 内容 |
|---|---|
| **新增** `scripts/check-transfer-semantics.swift` | 四段断言：**折叠实测表 14 行**（正反各一遍）、`NameConflict` 冲突与改名（含 F2 的回归断言「设备上有 `Photo.JPG` 时 `photo.jpg` 必须判为冲突」）、`DeviceNameRules` 的长度边界与字符集（含实测放行的那些必须放行）、`ThumbnailPolicy` 33 个扩展名 + 「远端许可集是本地真子集」的不变式 |
| **新增** `docs/device-acceptance/2026-10-11/09-conflict-e2e.txt` | **设备端集成证明**：拿真实设备返回的文件名跑新旧两套判据 —— 旧判据漏判、新判据拦住、并确认设备端确实把两者当同一个文件 |

跑法（不需要 Rust / adb，约 5 秒，写在脚本头）：

```bash
mkdir -p /tmp/transfercheck && cp scripts/check-transfer-semantics.swift /tmp/transfercheck/main.swift
swiftc -O -o /tmp/transfercheck/run \
  -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 6 -strict-concurrency=complete -Xfrontend -disable-sandbox \
  macos/Sources/DroidBerth/Support/NameComparison.swift \
  macos/Sources/DroidBerth/Transfer/NameConflict.swift \
  macos/Sources/DroidBerth/Support/DeviceNameRules.swift \
  macos/Sources/DroidBerth/Support/ThumbnailPolicy.swift \
  macos/Sources/DroidBerth/Support/ByteFormat.swift \
  /tmp/transfercheck/main.swift && /tmp/transfercheck/run
```

> 为什么是独立脚本而不是测试 target：本项目没有测试 target（见 `0926_03` §5.3），
> 与既有的 `scripts/check-icon-mapping.swift` 同一套做法。
> **代价要认**：这些脚本不会在 CI / 构建时自动跑，靠人记得跑。目前有两份。
>
> 测试本身也踩过一次坑：我给「NFC/NFD 两个字面量必须不同」写了断言，结果它**失败了** ——
> 因为 Swift 的 `String ==` 按规范等价比较。这个失败是对的（用例在测一个恒真的东西），
> 改成按 `utf8` 字节比之后才有效。**一个从不失败的断言等于没有断言**。

### 9.5 验收结果

| 项 | 结果 |
|---|---|
| `swiftc -typecheck`（全量，`-strict-concurrency=complete`） | **0 输出，退出码 0** |
| `xcodebuild Release` | **BUILD SUCCEEDED**，0 error / 0 warning |
| `scripts/check-transfer-semantics.swift` | **ALL OK** |
| `scripts/check-icon-mapping.swift`（回归） | **ALL OK**（77 个扩展名） |
| 设备端集成证明 | 旧判据漏判、新判据拦住 ✓ |
| 新增源文件已进工程 | 4 个（`xcodegen generate` 后逐个核对 `project.pbxproj`） |

**仍需人工 / 真机**：上传与重命名/移动这几条改动都是**行为变更**，要在运行时确认
（尤其是「保留两者」的 note 文案与 ` (1)` 名字在界面上的呈现）；以及 §8 列的那些项。

---

## 10. 复现方法

```bash
# 环境：Android 模拟器已在运行（adb devices 能看到 emulator-5554）
cd docs/device-acceptance/2026-10-11

# 备好素材（图片由 sips 从系统 HEIC 放大；视频用 avconvert，--disableFastStart
# 才能造出 moov 在文件尾的那种）
/usr/bin/python3 make-media.py

# 01 缩略图成品率（会 push 到 /sdcard/DCIM/DroidBerthProbe，跑完自动清理）
./test-thumb.sh

# 02–04 设备端语义（文件名 / Android data / 存储卷 / 大小写 / 媒体入库）
/usr/bin/python3 test-semantics.py
/usr/bin/python3 test-semantics2.py     # 对 02 的聚焦复核
/usr/bin/python3 test-semantics3.py     # 收口：字节数边界、push 覆盖的内容级证明

# 05 取头大小的成功率曲线
./test-thumb-sweep.sh

# 06–08 折叠语义：设备端全维度 / 设备端规则判定 / 两侧对照
/usr/bin/python3 test-name-fold.py       # 06 尾随空格、全角、连字…逐维度过一遍
/usr/bin/python3 test-fold-rule.py       # 07 用四个「只有完整折叠才会折叠」的字符判定规则
/usr/bin/python3 test-mac-fold.py        # 08 macOS 侧同一批（镜子测试）
```

**不经设备**的两件（几秒，改完代码就该跑）：

```bash
# 传输语义回归（折叠表 / 冲突与改名 / 校验规则 / 缩略图策略）
#   跑法见 scripts/check-transfer-semantics.swift 的文件头

# 设备端集成证明（拿真实设备返回的文件名跑新旧两套判据）—— 需要设备
swiftc -O -o /tmp/e2e/run ... macos/Sources/DroidBerth/Support/NameComparison.swift \
  macos/Sources/DroidBerth/Transfer/NameConflict.swift ... && /tmp/e2e/run
```

脚本里有两个**必须保留**的写法，改掉就会得到错误结论：

1. **临时文件必须保留原扩展名** —— `QLThumbnailGenerator` 按扩展名挑缩略图器。
   我自己踩过一次：把对照文件命名成 `photo.jpg.full`，8 个文件**全部**被误判为失败。
   这也正是 app 的 `AppPaths.makeThumbnailScratchFile(named:)` 保留原名的原因。
2. **判「文件是否真的存在」用 `find` 数，不要数 `ls -a` 的行** —— `adb shell` 的 stdout 走 pty，
   `ls` 的列输出与转义在 pty 下不可靠。（同源问题：`fetchHeader` 必须用 `exec-out` 而不是 `shell`。）
3. **别用 `print(String(format: "%-10s", swiftString))`** —— `%s` 要的是 C 字符串，
   传 Swift `String` 会直接 `SIGSEGV`（exit 139）。要么用 `%@`，要么自己按 `count` 补空格。
