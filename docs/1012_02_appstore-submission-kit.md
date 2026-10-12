# App Store 提审清单（照着填）

> 2026-10-12 整理。**先看 §0 的阻塞项** —— 有两件不做完，提交按钮点不动。
> 文案分「中文」与「英文」两套；只上中国区填中文即可，上全球区两套都要。（**中文 4 段可直接粘贴**）

---

## §0 阻塞项（不做完提交会被拦住）

| # | 事项 | 状态 | 怎么做 |
|---|---|---|---|
| **B1** | **`Mac Installer Distribution` 证书** | ❌ **本机没有**（已用 `security find-identity` 核过：只有 Apple Development / Developer ID Application / Apple Distribution） | <https://developer.apple.com/account/resources/certificates> → ＋ → **Mac Installer Distribution** → 按提示在钥匙串里生成 CSR 上传 → 下载 `.cer` 双击入钥匙串 |
| **B2** | **Provisioning profile** | ❌ **一个都没有**（`~/Library/MobileDevice/Provisioning Profiles/` 目录不存在） | 先在 <https://appstoreconnect.apple.com> 建 App 记录（bundle id `dev.tango.droidberth`），再到 developer 后台建 **Mac App Store** 类型的 profile，下载双击安装 |
| **B3** | **隐私政策 URL** | ❌ **没有这个页面** | App Store 强制要求。最省事：在本仓库加 `PRIVACY.md`，URL 用 `https://github.com/tangzzz-fan/DroidBerth/blob/main/PRIVACY.md`（§4 已给草稿） |
| **B4** | **App 记录** | ❌ 未创建 | App Store Connect → 我的 App → ＋ → 新建 App：平台 macOS、名称 `DroidBerth`、主要语言中文、bundle id 选 `dev.tango.droidberth`、SKU 自定（如 `DROIDBERTH001`） |

> ⚠️ B1/B2 完成后，`project.yml` 里**不用改任何东西** —— profile 是**部署期数据**，
> 从命令行注入（见 §6）。**别把 profile 名字写进 `project.yml`**。

---

## §1 名称与副标题

| 字段 | 限制 | 中文（可直接粘贴） | 英文 |
|---|---|---|---|
| **App 名称** | 30 | `DroidBerth` | `DroidBerth` |
| **副标题** | 30 | `Mac 传视频照片到安卓手机`（12 字） | `Mac ⇄ Android file transfer`（26） |

> 名称别加「- 文件传输」这类后缀：App Store 的搜索靠**关键词**而不是名称堆词，
> 而名称里塞词会被审核以「关键词堆砌」为由打回。

---

## §2 描述（4000 字符上限，下面约 380 字）

### 中文（可直接粘贴）

```
把 Mac 上的视频和照片推到 Android 手机，像用 Finder 一样浏览两端。

DroidBerth 为「Mac → Android」这一个方向优化。插上数据线，左边是 Mac 的文件夹、
右边是手机，拖过去就行 —— 不需要装 Android SDK，不需要打开终端，不需要理解 ADB。

■ 为什么它适合传素材
· 双栏并列：一端一个窗格，选中直接拖到另一边，方向一眼看清
· 三种视图：列表 / 分栏 / 网格。网格带缩略图，几百个视频里也能认出要传的是哪个
· 照片图库直推：不用先导出到文件夹，从「照片」里选完直接推
· 不用等完整下载：预览窗格与快速查看让你先看一眼再决定
· 单次传输量大也不怕：后台队列 + 进度 + 失败重试，传完自动让相册重新索引

■ 它不做什么
不做备份，不做设备管理，不碰 MTP。范围刻意收窄 —— 只把一件事做顺。

■ 关于权限
· 只在你亲手选择文件夹之后才访问它，且只在你选过的范围内工作
· 需要 USB 访问权限，用于和你自己的手机通信（内嵌的 ADB 由 Google 发布，Apache-2.0 许可）
· 不联网上传任何文件；诊断报告只有你主动导出时才生成，且写入前已抹掉用户名与路径

Android 手机需要打开「USB 调试」。第一次连接时手机上会弹一次授权询问，
勾选「始终允许」之后就不用再管了。

隐私政策：<填 §0 的 B3 链接>
```

### 英文（若上全球区）

```
Push videos and photos from your Mac to your Android phone — browse both sides like Finder.

DroidBerth is built for one direction: Mac → Android. Plug in a cable and you get the Mac's
folders on the left, the phone on the right, and drag-and-drop in between. No Android SDK,
no terminal, no need to know what ADB is.

WHY IT FITS MEDIA WORK
· Two panes side by side — drag from one to the other, direction never in doubt
· Three views: list, column, and grid. Grid shows thumbnails so you can spot the right clip
· Send straight from Photos, no exporting to a folder first
· Preview pane and Quick Look — look before you copy
· Built for large batches: background queue, progress, retry, and media re-index for you

WHAT IT DOESN'T DO
No backups, no device management, no MTP. The scope is deliberately narrow.

ABOUT PERMISSIONS
· Folders are accessed only after you pick them yourself, and only within what you picked
· USB access is used to talk to your own phone (bundled ADB is published by Google, Apache-2.0)
· Nothing is uploaded anywhere; diagnostics are generated only when you ask, and are
  scrubbed of usernames and paths before they are written

Your Android phone needs USB debugging enabled. The phone asks once — tick "always allow".
```

---

## §3 其余字段

| 字段 | 限制 | 建议值 |
|---|---|---|
| **关键词** | 100 | `Android文件传输,Mac传文件,adb,手机传视频,照片传输,安卓传输,USB传输,素材备份,file transfer` |
| **宣传文本** | 170 | `双栏 Finder 式界面，把 Mac 的素材拖到安卓手机。内嵌 ADB，不用装 SDK、不用终端。` |
| **支持 URL** | 必填 | `https://github.com/tangzzz-fan/DroidBerth/issues` |
| **营销 URL** | 选填 | `https://github.com/tangzzz-fan/DroidBerth` |
| **隐私政策 URL** | **必填** | §0 B3 |
| **主要类别** | — | **实用工具**（与 `Info.plist` 的 `public.app-category.utilities` 一致） |
| **次要类别** | 选填 | 摄影与录像 |
| **版权** | — | `© 2026 zhenzhi Tang`（与 `Info.plist` 的 `NSHumanReadableCopyright` 一致） |
| **价格** | — | 免费 |
| **年龄分级** | — | 4+（全部问题答「无」） |
| **出口合规** | — | 「不使用加密」或「使用 Apple 提供的标准加密」—— 本项目只用了 `URLSession`/TLS 之外无自研加密，选**豁免**即可 |
| **版本号** | — | **`1.0.0`**（`project.yml` 里默认 `0.1.0`，发版时从命令行注入） |

---

## §4 隐私政策草稿（复制成 `PRIVACY.md` 即可）

```markdown
# 隐私政策 · DroidBerth

最后更新：2026-10-12

DroidBerth 不收集、不上传、不分享任何个人信息。

## 我们处理什么
- **文件**：只在你亲手选择的文件夹范围内读写，用于在你与自己的 Android 设备之间传输。
  这些文件不会离开你的两台设备。
- **Android 设备信息**：设备型号、存储容量等，仅用于在界面上显示，不落盘、不外传。
- **诊断信息**：仅当你主动执行「导出诊断报告」时生成。报告写入磁盘前会抹去用户名与家目录路径。
  是否把它发给开发者完全由你决定。

## 我们不做什么
- 不联网上传你的任何文件
- 不含分析 / 追踪 / 广告 SDK
- 不在后台收集数据

## 第三方组件
本应用内嵌 Google 发布的 Android Platform Tools（ADB），以 Apache License 2.0 分发。
它仅用于通过 USB 与你自己的设备通信。

## 联系方式
如有疑问，请在 https://github.com/tangzzz-fan/DroidBerth/issues 提出。
```

---

## §5 截图（5 张，已由 `scripts/appstore-shots.sh` 生成）

规格（Apple 官方要求，已核）：**16:10、精确像素、PNG、不允许 alpha、sRGB、单张 ≤10 MB、1–10 张**。
允许的尺寸只有四种：**1280×800 / 1440×900 / 2560×1600 / 2880×1800**。
本机屏幕 2560×1440（16:9）放不下 2880×1800，所以统一用 **1440×900**。

| # | 文件 | 展示什么 | 为什么放在这个位置 |
|---|---|---|---|
| 1 | `01-two-panes.png` | 双栏主界面：左 Mac「下载」、右手机 `内部存储 ▸ Pictures` | Mac 浏览者在前 2 张里决定要不要下载，这张必须一眼说清「是什么」 |
| 2 | `02-grid-mac.png` | 网格视图 + **真实缩略图**（左栏 6 项，其中 4 张 JPG 有缩略图） | 摄影/视频用户的核心痛点：一堆素材里认出要传的那个 |
| 3 | `03-column-mac.png` | 分栏视图（⌘2）+ 窗格底部路径栏 | 给 macOS 老用户看「它就是 Finder 的手感」 |
| 4 | `04-column-root.png` | 分栏浏览整机（Applications / Library / System / Users 四列） | 分栏的**层级感**要有多列才看得出来，单列目录展示不了 |
| 5 | `05-swapped.png` | 交换两侧后的布局：手机在左、Mac 在右 | 说明窗格顺序可换（素材在右、手机在左也是常见摆法） |

⚠️ **两张原本想做但做不到的**（如实记下，别以为漏了）：

- **「照片图库」**（宣传里「不用先导出到文件夹」的那条）：沙盒版首次进入该模式会显示
  「需要照片图库权限」的请求页 —— 而**批准那个系统弹窗必须人工点一次**（自动化点不了跨进程的 TCC 弹窗）。
  你点一次「授权访问」并允许之后，它就能作为**第 6 张**补上（ASC 最多 10 张）。
- **「预览窗格」**（⇧⌘P）：它是「显示」菜单项，而工具栏里没有等价按钮 ⇒
  当前的自动化手段（AX 按工具栏控件）够不到它。要这张得手工按一次快捷键再截。


> ⚠️ 三条硬约束（**违反会被打回**）：① 必须是**真实运行的界面**，不是设计稿；
> ② **不要出现价格**（地区定价不同，Apple 明确列为打回原因）；
> ③ 不要出现其他 App Store 的 logo 或贬低竞争对手的文案。

---

## §6 审核备注（**这一段最关键，别空着**）

被拒的最大风险不是功能，而是**审核员手上没有 Android 手机**。所以备注要把「为什么需要
USB、为什么内嵌 adb、没设备时能看到什么」一次讲清。

```
感谢审核。

【这个 app 是什么】
DroidBerth 在 Mac 与用户自己的 Android 手机之间传输文件（照片 / 视频为主）。
它把 Google 官方发布的命令行工具 ADB 封装成了图形界面，用户不需要安装 Android SDK，
也不需要打开终端。

【为什么内嵌 ADB】
ADB 是 Google 随 Android Platform Tools 发布的官方工具，许可证为 Apache License 2.0
（随 app 的 NOTICE.txt 中已附完整声明）。它只做一件事：通过 USB 与**用户自己插入的设备**
通信。本 app 不会用它访问任何远程服务，也不会上传任何数据。

【为什么需要这些权限】
· USB 设备访问：与插入的 Android 手机通信（这是核心功能，见上）
· 用户选择的文件夹读写：传输源文件。**只在用户通过系统面板亲手选择的目录内**工作，
  不会扫描其他位置
· 网络客户端：仅用于「无线调试」模式，即用户主动开启后经局域网连接自己的手机

【审核员没有 Android 手机时可以看到什么】
app 可以正常启动并完整浏览左侧 Mac 文件窗格（三种视图、缩略图、预览、Quick Look 都可用）。
右侧设备窗格会显示连接引导，其中说明了需要什么条件。要验证完整传输链路，需要一台
开启了 USB 调试的 Android 手机（设置 → 关于手机 → 连点版本号 → 开发者选项 → USB 调试）。

【已做的自查】
· 沙盒：已开 `app-sandbox`，并使用 security-scoped bookmark 记住用户选择的目录
· 退出时无残留进程：退出时结束内嵌的 ADB 后台进程（Guideline 2.4.5(iii)）
· 内嵌二进制：每个都带 `app-sandbox` + `inherit`

如需任何补充信息，请随时联系。
```

---

## §7 提交前自检（三条命令，都能直接跑）

```bash
cd ~/Developments/DroidBerth

# 1) 构建 + 重签内嵌工具 + 上架前自检（唯一 FAIL 应当只剩缺 profile）
CONFIGURATION=Release-MAS ./scripts/build.sh
CONFIGURATION=Release-MAS ./scripts/sign-embedded-tools-mas.sh
CONFIGURATION=Release-MAS ./scripts/check-mas-readiness.sh

# 2) 出 .pkg（B1 证书到位后才能跑）
CONFIGURATION=Release-MAS ./scripts/package-mas.sh 1.0.0

# 3) 校验截图（尺寸 / alpha / 色彩空间 / 大小 / 张数一次全查）
./scripts/appstore-shots.sh verify docs/appstore/screenshots/1.0.0
```

> `check-mas-readiness.sh` 有三档结论：**PASS / FAIL（退出码 1，不可绕过）/ 人工项**。
> 人工项里有两条是**法务**（NOTICE 的豁免适用性、中国大陆上架资质），工程改不了。
