# DroidBerth 视觉层与图标层设计报告

| 项 | 值 |
|---|---|
| 版本 | v1.0 |
| 日期 | 2026-10-10 |
| 范围 | `macos/` Swift 原生外壳的**视觉层与图标层**（不动交互语义） |
| 依据 | PRD v2.1 §8 / §10 / §13 / §17 / §21 / §25 / §27；`1009_01_uiux-revamp-plan.md` 已知偏离清单；44 个 Swift 文件全量审阅；open-design 设计稿（§4 有出处） |
| 存放说明 | 刻意放 `docs/` 而不是 `reports/` —— `.gitignore:31` 把 `reports/` 排除（那是 doctor / spike 的**运行期输出**）。设计文档要跟 PRD 与改造方案放在一起，且要入库。 |

---

## 0. 结论

**交互层已经像 Finder 了，视觉层还不是。**

`1009_01` §8 的总验收清单已经全绿（三种视图、拖拽、⌘C⌘V、Quick Look、预览窗格、设备端写操作、菜单栏、Reduce Motion 全落地）。剩下的缺口全部是**视觉与图标**，且集中在三件事：

| # | 缺口 | 严重度 | 一句话 |
|---|---|---|---|
| G1 | **应用图标完全缺失** | P0 | 有一个从未被调用的图标生成脚本；app 在 Dock / Finder / About / DMG 里显示系统通用图标 |
| G2 | **文件类型图标 9 个符号 + 两栏规则分叉** | P0 | 同一份事实写了两遍，已经分叉（`.apk` / `.app` 在两栏显示不同图标） |
| G3 | **PRD §17.1 的连接引导卡片未实现** | P0 | 要求的「图示 + 三步 + 重新检测按钮 + 品牌差异」现在只是一个字符串 |
| G4 | 空态一律 `tray` | P1 | 四类语义不同的空态长得一模一样 |
| G5 | 品牌色事实上不存在 | P1 | 图标用 teal 渐变、界面用系统强调色、传输方向用 `Color.teal`，三者互不相干 |
| G6 | 无障碍只做到「部分」 | P2 | `1009_01` §4.8 已记录，**本次不碰** |

---

## 1. 审计方法（判据可复核）

| 手段 | 命令 / 位置 | 用途 |
|---|---|---|
| 资源目录清点 | `ls macos/Resources/` | 确认 bundle 里到底有什么 |
| 图标字段检索 | `grep -rn "CFBundleIcon\|icon.icns\|ASSETCATALOG\|make-icon\|Assets.xcassets"` | 确认图标是否接入构建 |
| 符号清单 | `grep -rn "systemName: \"\|systemImage: \"" macos/Sources` | 清点全部 SF Symbol |
| 类型映射对照 | `LocalFileSystem.swift:27-39` vs `RemoteEntry.swift:21-34` | 确认两栏规则是否一致 |
| 逐视图审阅 | `Views/*.swift` 全读 | 空态、材质、聚焦态、色板 |
| 基线 | `swiftc -typecheck … -Xfrontend -disable-sandbox` | 动手前的干净基线（2026-10-10 实跑：**0 error**） |

---

## 2. 逐条对照 PRD

| PRD 位置 | 要求 | 可执行判据 | 现状 | 结论 |
|---|---|---|---|---|
| §8 原则一 | 优先系统控件，不自造系统已有之物 | 有没有自造系统已提供的等价物 | 分栏已用 `NSBrowser`、列表已用 `Table`、预览已用 `QLPreviewPanel`、设置已用 `Form(.grouped)` —— **都对**。但**文件类型图标**自造了一张 9 行表去近似 `NSWorkspace` | ⚠️ G2 |
| §8 原则一 | 不引入非系统视觉 | 有没有自定义字体 / 配色 / 图标风格 | 无。全部 SF Symbol + 语义色 | ✅ |
| §8 原则三 | 材质用原生 API，导航层可用、内容区不用 | 内容区有没有材质 | 工具栏 / 窗格头 / 传输面板 / banner / 拖拽预览用材质；表格、网格、预览栏内容区用纯色 | ✅ |
| §8 判据 | 「和 Finder 并排放在一起，用户不应看出差别」 | 并排截图 | **应用图标这一项直接不成立** | ❌ G1 |
| §10 | 聚焦窗格有可见标识（描边 + 窗格头加重） | 两重区分、不只靠颜色 | `PaneFocusStyle`：2pt 系统色描边 + 6% 背景 + `PaneHeader` 字重加重 | ✅ |
| §13.1 | 列表四列 + 行首类型图标 | 每列都在、图标覆盖常见类型 | 四列齐；图标覆盖 **9/36 类** | ⚠️ G2 |
| §13.3 | 缩略图失败显示类型图标，不留空白 | 回退路径存在 | `ThumbnailStore.State.unavailable` → `placeholder(entry)`，所有路径都有占位 | ✅（回退用的就是 G2 那张表） |
| §17.1 | 未授权时显示**引导卡片**（图示 + 三步 + 重新检测 + 按品牌换图文） | 界面上有没有这张卡 | **没有**。只有 `ContentUnavailableView` + 一行字符串 | ❌ G3 |
| §17.2 | 无线的「需要插线重新激活」也做成引导 | 同上 | 只有 `rememberedWirelessDevices` + 设备菜单里的「尝试无线重连」，**没有引导卡片** | ❌ G3 |
| §21 | 三档外观，经 `NSApplication.appearance` 驱动 | 三档都在、切换即时 | `AppearanceController.apply` + 设置里分段控件 | ✅ |
| §25 | 聚焦态不只靠颜色 | 形状 + 字重双重区分 | 描边 + 字重 | ✅ |
| §25 | Reduce Motion | 位移类动画退化 | 交换两侧 / banner / 面板折叠 / 「查看原因」全部读 `accessibilityReduceMotion` | ✅ |
| §25 | 动态字体 / 对比度 | 逐屏核对 | 只做到「部分」（语义字号 + `@ScaledMetric`），**未逐屏核对** | ⚠️ G6 |
| §27 | 分发产物 | DMG 挂载后第一眼 | **卷里是一个没有图标的 app** | ❌ G1 |

**一句话概括这张表**：交互层 100% 达标，视觉层达标率低，且**失分点高度集中在图标**。这不是「审美不够」，是**一个 0（没有图标）加一个分叉**。

---

## 3. 缺口详述

### G1 [P0] 应用图标完全缺失 —— 证据链

| 检查 | 结果 |
|---|---|
| `ls macos/Resources/` | 只有 `DroidBerth.entitlements` + `Info.plist`，**没有任何图像资产** |
| `Info.plist` 的 `CFBundleIconFile` / `CFBundleIconName` | **不存在** |
| `project.yml` 的 `ASSETCATALOG_COMPILER_APPICON_NAME` | **不存在**；也没有 `.xcassets` 参与构建 |
| 全仓检索 `make-icon` / `icon.icns` / `CFBundleIcon` / `Assets.xcassets` | **命中 0 处**（排除 build 目录） |
| `scripts/make-icon.py` | 存在、能跑、会生成 `icon.png` + `icon.icns` + `icon.iconset/`，但**没有任何脚本或 build phase 调用它** |

**它是一个孤儿脚本。** 后果：

- Dock、⌘Tab、Finder、About 面板、DMG 挂载后的卷图标 —— 全部是系统通用应用图标
- 代价不是「不好看」，是**看起来像未完成的构建产物**。PRD §27 的分发链上，用户第一眼看到的就是它
- PRD §28 的发布检查清单里**没有图标项** —— 这一项连被检查的机会都没有

> 注：`macos/Resources/icon.png` 与 `icon.icns` 目前不存在，所以 `ls` 干净。脚本的默认输出目录就是 `macos/Resources`，但它从没被跑过（或跑过又被清掉了 —— `.gitignore` 没有排除它们，而它们不在库里，说明从未提交）。

### G2 [P0] 文件类型图标：9 个符号、两处重复、已经分叉

**覆盖面**：`LocalEntry.systemImage`（`LocalFileSystem.swift:27-39`）与 `RemoteEntry.systemImage`（`RemoteEntry.swift:21-34`）各一条 switch，最长路径共用 **9 个符号**：

```
folder.fill · film · photo · music.note · doc.zipper · shippingbox · doc.richtext · doc.text · doc
```

**分叉（这是最要紧的一条）** —— 两段代码看起来是复制粘贴，实际不是：

| 扩展名 | Mac 窗格（`LocalFileSystem`） | 设备窗格（`RemoteEntry`） | 症状 |
|---|---|---|---|
| `.apk` | `doc`（通用文稿） | `shippingbox`（盒子） | 同一个文件在两栏显示不同图标 |
| `.app` | `app` | `doc`（通用文稿） | 同上 |

`.apk` 在 Mac 窗格里显示成通用文稿 —— 而「把 apk 推到手机装」是这个产品的真实用法之一。

**这是「同一份事实写了两遍」的必然结果，而且症状是静默的**：没有任何测试或编译错误会告诉你它错了。

**其它覆盖缺口**（全部落到 `doc`）：
`docx / xlsx / pptx` · `dmg / iso` · `ttf / otf` · `db / sqlite` · `sh / py / js / ts / swift / rs / html / css` · `ipa / exe / aab` · `pages / numbers / key` · `rtf` · `svg / psd / ai`

**但下面这些「缺失」是刻意的、不该补**（见 §5.4）：`.jpg` 与 `.heic` 不该分图标；`.mp4 / .mov / .mkv / .avi / .webm` 不该分图标。**用户心智里它们是同一件事**，给不同图标只是给界面加噪音。

**根因与修法**：PRD §8 原则一说「优先系统控件，不自造系统已有之物」。文件图标正是系统已有的东西 —— 但**只在文件真实存在时**才拿得到：

- **左栏（本地）**：`NSWorkspace.shared.icon(forFile: path)` —— Finder 用的就是它，一行换到全部类型的正确图标，顺带白拿替身角标与 App 包的图标
- **右栏（设备）**：条目只是 `adb shell ls` 列出的一行，本机**没有对应文件**，问 `NSWorkspace` 只能拿到笼统的通用图标。⇒ 必须由一张自建的**完整扩展名精确映射表**（扩展名 → SF Symbol）接管
- **兜底**：两张路径都解析不出来（无扩展名 / 未知）时，落到通用 `doc`

这样两栏各有一条**明确**的路径（而不是两处各写一遍 switch），`.apk` 的分叉从结构上不可能再发生。详见 §4.2。初稿曾写「两栏都走 UTType → `NSWorkspace`」—— 对右栏不成立，稿子纠正了这一点。

### G3 [P0] PRD §17.1 的连接引导卡片未实现

PRD 原文要求得相当具体：

> **未授权**（`unauthorized`）时显示引导卡片：手机上的「允许 USB 调试？」图示 + 「勾选『始终允许』再点确定」+ 「已完成，重新检测」按钮
> **厂商差异**：小米 / OPPO / vivo 的开发者选项流程含额外风险提示与等待步骤，引导卡片按检测到的品牌显示对应图文

当前实现（`MainView.deviceEmptyMessage`）返回**一个字符串**，交给：

```swift
ContentUnavailableView {
    Label(emptyMessage, systemImage: "tray")
}
```

四项要求一项都没落地：

| PRD 要求 | 现状 |
|---|---|
| 手机上的授权弹窗图示 | 一个 `tray` 符号 |
| 三步操作说明 | 一句话（「请在手机上勾选『始终允许』后点确定」） |
| 「已完成，重新检测」按钮 | 没有按钮。只能去工具栏设备菜单里找「重新检测设备」 |
| 按品牌换图文 | 没有。而 `AndroidDevice` 的 `model` / `product` / `device` 三个字段**已经把品牌信息拿到了**，只是没有任何地方消费它 |

同理，PRD §17.2 的「手机重启后需要插线重新激活」也只是一句话，不是引导卡片。

### G4 [P1] 空态一律 `tray`

`EntryTable.swift:30` 与 `EntryGrid.swift:46` 都是 `Label(emptyMessage, systemImage: "tray")`。于是四类语义完全不同的空态长得一模一样：

1. 未检测到设备（要引导**插线**）
2. 照片图库权限被拒（要引导**去系统设置**）
3. 这个文件夹是空的（**中性**，不是错误）
4. 没有匹配「xxx」的项目（要能**一键清除筛选**）

`tray` 这个符号既不代表「没连设备」也不代表「没有搜索结果」。四类里三类有明确的下一步动作，而当前**一个按钮都没有**（清筛选要去工具栏找小叉、重新检测要去设备菜单）。

> **反例（做对了的样板）**：`PhotoSourceView.deniedView` / `promptView` 用的是 `ContentUnavailableView` 的完整形态 —— icon + description + **actions 按钮**，且两句文案分别区分了「被拒」与「尚未授权」。其余空态应该向它看齐。

**顺带一条**：空态是被**两个视图各自**实现的（`EntryTable` 一处、`EntryGrid` 一处），文案由 `MainView` 的 `macEmptyMessage` / `deviceEmptyMessage` 用字符串拼出来。这个结构本身就挡着「空态带按钮」——按钮要回调到 `AppModel`，而字符串传不了动作。**要加按钮，必须先把这个结构改掉。**

### G5 [P1] 品牌色事实上不存在

三处颜色互不相干：

| 位置 | 颜色 | 问题 |
|---|---|---|
| `scripts/make-icon.py:21-23` | teal 线性渐变 `(8,145,178) → (34,211,238)` | 唯一像「品牌色」的东西，但**图标没被用上**（G1） |
| 界面全处 | `Color.accentColor` | 跟随系统强调色（用户设成粉色，整个 app 变粉）。**这本身是对的**（Finder 也这样），且符合 §8「不引入非系统视觉」 |
| `TransferPanel.swift:147` | 上传 = `accentColor`，下载 = `Color.teal` | teal 是固定色板项，**不跟随强调色**。用户把强调色设成 teal，两个方向就同色了 |

方向不完全靠颜色区分（`Direction.symbol` 是 `arrow.up.circle.fill` / `arrow.down.circle.fill`，且带「上传」/「下载」胶囊文字），所以不构成 §25 的违规。但**用色任意**本身是缺口：为什么下载是 teal？没有理由。

**结论**：品牌色要先定下来（图标 + 界面共用同一个色），否则图标与界面必然分叉 —— 与 G2 是同一类病（同一份事实两个来源）。

---

## 4. 设计方案

> 设计稿由本地 open-design 守护进程产出（v0.23.1，`http://127.0.0.1:7456`）。
> 两个项目：`droidberth`（App 图标，**已 succeeded**）、`droidberth-icons`（图标体系与引导插图，**首次运行因 `AGENT_EXECUTION_FAILED / auth_required` 失败、已用新 requestId 重跑**）。
> 产物快照落在 `docs/design/2026-10-10-ui-icons/`（见 §4.4 的仓库约定）。

### 4.0 出稿记录

| # | 项目 | runId | 状态 | 产物 |
|---|---|---|---|---|
| 1 | `droidberth` | `499664fb-7406-4ae6-ba92-e48bd1d3ca6f` | ✅ succeeded（8.7 分钟） | `app-icon-directions.html` |
| 2 | `droidberth-icons` | `57418b81-2a9d-4570-b74d-1665434e1d4d` | ❌ failed（12.3 分钟，0 产物，`auth_required`） | — |
| 2′ | `droidberth-icons` | `10cdebb7-fbc3-4c35-8bad-3d360f76bf5b` | ✅ succeeded（7.1 分钟） | `icon-system.html` + `brand-spec.md` |

> **失败原因记录**：两次运行并发时，第二次在跑了 12 分钟后死于 `Claude Code could not authenticate with the configured custom Anthropic endpoint`（`failureCategory: auth`）。第一次成功、第二次失败 ⇒ **不要并发跑两个 open-design run**（同一个自定义 endpoint 会互相挤）。以后串行。

### 4.1 App 图标 —— 已出稿

**稿子**：`docs/design/2026-10-10-ui-icons/app-icon-directions.html`（920 行，全部内联 SVG）
**预览**：http://127.0.0.1:7456/api/projects/droidberth/raw/app-icon-directions.html
**runId**：`499664fb-7406-4ae6-ba92-e48bd1d3ca6f`（succeeded）

**三个方向**

| | 名字 | 剪影 |
|---|---|---|
| A | `two-berths` | 两块竖长白色圆角面板（各 190×480，rx 56）+ 中间一支粗圆头人字箭头（sw 86） |
| B | `push-rail` | 圆角方块骑在轨道左端，轨道向右收进一个大三角箭头 |
| C | `dock-port` | 粗圆环（外径 380 / 环宽 160）+ 一条平口引导线切在内圆左切点 |

**稿子的推荐：A `two-berths`**。理由（稿子原文的要点）：三个方向里只有 A 把「双栏」与「往对岸推」同时写进剪影；C 在 16pt 下最干净但它讲的是「连接」，任何配对/投屏工具都能用同一个形；B 的「推」最响，可斜向 L 形在圆角方形里重心不稳，16pt 下会糊成一个没有方向的钝角块。

**它对 16pt 的处理（重要，要落到代码里）**：A 在 16pt 下箭头与面板之间只剩约 1px 间隙，因此**给 16pt 单独出一档**：把间隙压到 0、箭头并进左侧面板做成实心楔形；其余档位共用同一份几何。⇒ 生成脚本不能只渲染一张 1024 母版再 `sips` 降采样，**小尺寸档必须原生渲染**。

**推荐方向的几何（可直接抄进 `make-icon.py`）**

| 元素 | 值 |
|---|---|
| 底板 | 超椭圆 `\|x\|⁵ + \|y\|⁵ = 412⁵`，中心 (512,512) —— **不是** CSS 圆角，也不是圆弧近似 |
| 底板填充 | 垂直线性渐变 `#F9A04A → #DE6B20` |
| 左面板 | `rect x=158 y=272 w=190 h=480 rx=56`，白 |
| 右面板 | `rect x=676 y=272 w=190 h=480 rx=56`，白 |
| 箭头 | `M453 402 L571 512 L453 622`，`stroke=#fff width=86`，`linecap/linejoin=round` |

> 稿子用超椭圆 n=5 逼近 Apple 的 continuous corner：45° 处离角点 53.3px，而 spec 的 r=185.4 普通圆角是 54.3px —— 切口对得上，肩部更接近连续曲率。这是个好做法，照抄。

**品牌强调色（稿子给的）**

| 角色 | Hex | OKLCH | 深色底 | 浅色底 |
|---|---|---|---|---|
| 主色 · Mac → Android | `#ED8725` | `oklch(0.72 0.16 58)` | 6.6:1 ✅ | 2.6:1 ⚠️ 需降到 `#B44F00`（5.2:1） |
| 辅色 · Android → Mac | `#1CA0AC` | `oklch(0.645 0.105 205)` | 5.4:1 ✅ | 4.6:1 ✅ |

**⚠️ 我对这个配色有一处反对意见**（需要你裁决，见 §7）：`#ED8725` 与 App 里**现有的警示色撞车** —— `MainView.color(for: .warning) → .orange`、`TransferPanel` 的「媒体入库失败」用 `.orange`、`PhotoSourceView` 的「仅部分照片可访问」条也用 `.orange`。把品牌主色定成暖橙，等于**让「正常的主要动作」和「出事了」共用一个色相**。这在传输工具里代价不小：传输面板上橙色同时意味着「上传中」和「入库失败」。
可选修法有三条，我倾向第二条：① 接受，靠图标与文案区分；② 品牌主色改成一个不与系统语义色冲突的色相（例如 `#3B7BE0` 一档的中蓝——但稿子反对蓝，理由是 Dock 里都是蓝的）；③ **图标用暖橙，界面里的方向标识继续用系统语义色**（上传 `accentColor` / 下载 `teal`），也就是品牌色只活在图标里。

**规范（严格遵守 macOS Big Sur+ 图标规范）**

| 项 | 值 |
|---|---|
| 画布 | 1024 × 1024 |
| 内容区（超矩形 squircle） | 824 × 824 居中，四周 100 pt 透明留白 |
| 圆角 | ≈185.4 pt（continuous corner，不是普通圆角） |
| 投影 | Apple 规范量级，落在 100 pt 留白里 |
| 禁止 | 文字 / 字母缩写 / 水印 / 照片纹理 / 多层高光 / 3D 渲染感 |
| 硬约束 | **必须能缩到 16×16 pt 仍可辨认主形** |

**实现路径：用代码画，不放位图。** 这是本仓既有做法（`scripts/make-icon.py` 是零依赖纯 Python，只经 `sips` + `iconutil` 出 `.icns`）。理由：

- 可复现、可 diff：改一个色值就能重出全套十档
- 不把二进制资产塞进版本库（与 `vendor/`、`macos/Sidecar/` 的处理一致）
- 与 §4.1 的「几何必须清晰」约束是同一件事 —— **稿子定的是几何契约，不是像素**

**判据**：`python3 scripts/make-icon.py` 幂等重出 `macos/Resources/{icon.png, icon.icns}`；`iconutil` 十档齐全（16/32/64/128/256/512/1024）。

### 4.2 文件类型图标体系 —— 已出稿

**稿子**：`docs/design/2026-10-10-ui-icons/icon-system.html`（1016 行）+ `brand-spec.md`
**预览**：http://127.0.0.1:7456/api/projects/droidberth-icons/raw/icon-system.html
**runId**：`10cdebb7-fbc3-4c35-8bad-3d360f76bf5b`（succeeded，重跑后）

**结论一：两条路径各管一栏，而不是一条路管两栏**

这是稿子里我认为最要紧的一个判断，它修正了我在 §4.2 初稿里的写法：

| 栏 | 路径 | 为什么 |
|---|---|---|
| **左（这台 Mac）** | `NSWorkspace` 系统彩色图标 | 文件**真实存在**，交给系统零维护，顺带白拿替身角标、全部办公文档类型、App 包的图标 |
| **右（设备）** | 自建的「完整扩展名 → SF Symbol」精确映射表 | 条目只是 `adb shell ls` 列出的一行，本机**没有对应文件**，问 `NSWorkspace` 只能拿到一个笼统的通用图标 |

**结论二：净增只有 3 个符号** —— 判据是三条同时成立：① 用户会对它做出**不同的动作**；② 在目标用户的文件里**高频**；③ SF Symbols 里有一个**现成的、16pt 下与已有符号可辨**的符号（③ 不过就合并，**不要为了凑一个图标去自绘**）。

| 新增 | 符号 | 理由 |
|---|---|---|
| 表格 | `tablecells` | 「里面有格子、要横向看的数据」，动作与文稿不同 |
| 磁盘映像 | `opticaldisc` | dmg / iso 的动作是**挂载成一个卷**，不是解压 |
| 代码 / 配置 | `chevron.left.forwardslash.chevron.right` | 目标用户就是开发者；`</>` 在 16pt 下辨识度极高 |

**刻意不新增**（每条都有具体理由）：全部图片格式合并（heic 与 jpg 给不同图标是纯噪声）；RAW 不单独给符号（**能不能开是运行时才知道的事，该由文案回答，不该由图标承诺**）；全部视频/音频容器合并；无扩展名与未知类型合并；pptx 合并（判据 ③ 不过）；`aab / ipa / exe` 并入 `shippingbox`（**不要用图标表达「这个不能推到 Android」**，那是禁用态与文案的职责）。

**结论三：稿子推荐策略乙（本机彩色 / 设备单色）**，并且否掉甲的**理由比我预想的更硬**：

> 甲被否掉不是因为不好看，而是它在设备侧会**稳定谎报**：`base.aab` 这种 Android 专有扩展名会回退成灰色的通用文稿图标，混在彩色图标里看起来仍像「系统认识它」。

这条我接受 —— 它把「甲看起来更原生」这个表面优势，换成了「它在右栏会撒谎」这个实质问题。

**稿子提的两处对系统默认的有意偏离（我逐条给判断）**

| 稿子的建议 | 我的判断 |
|---|---|
| 种类 / 大小 / 日期列**不用** `secondaryLabelColor`（浅色 3.95:1 < AA 的 4.5:1），改用 `#6E6E73`（5.1:1） | ✅ **接受**。这不是「引入非系统视觉」，而是 **PRD §25 明文要求「所有文本满足 WCAG AA（4.5:1）」**，而系统 `.secondary` 达不到 ⇒ 偏离是**被 PRD 要求**的。这条正好补上 `1009_01` §4.8 里那句「本轮没有走这一步」 |
| 选中行填充改用派生深橙 `oklch(56% .152 55)`（品牌原色作底白字只有 2.6:1） | ⚠️ **只接受一半**。理由：`Table` 的行选中**由系统绘制、改不了**；只改网格会造成「列表与网格两套选中视觉」。而 Finder 的选中本来就是系统强调色。⇒ 采纳它的**诊断**（品牌原色不能作填充底），不采纳它的**药方**（改用品牌橙）。选中继续走 `Color.accentColor`，网格那处 `Color.accentColor.opacity(0.18)` 保持不变 |

**稿子自己标出的待核对项**（照抄，别当已验证）：`arrow.turn.up.right` / `opticaldisc` / `cable.connector` 三个符号名是按记忆写的，**要在 SF Symbols.app 里过一遍**；`chevron.left.forwardslash.chevron.right` 与 `tablecells` 需要 SF Symbols 4（macOS 13+），本项目最低 macOS 14 ✅。

**收敛为单一事实来源**：新增 `Support/FileTypeIcon.swift`，两处 switch 全部删掉。

### 4.3 连接引导卡片（PRD §17.1）—— 已出稿

按 **300pt 宽**设计（要嵌进 340pt 的窗格），浅色 / 深色两版并排，含：手机授权弹窗示意图（标题 + 设备指纹码 + 「一律允许」复选框 + 取消 / 允许两个按钮）、三步说明、「已完成，重新检测」主按钮，以及**品牌变体只换底部那一段文案**的结构 —— 小米 / OPPO / vivo 与「弹窗不再出现」四种变体单独成表，并给出 `getprop ro.product.brand` 的检测值。

**文案（稿子给的原文，可直接抄）**

| 位置 | 文案 |
|---|---|
| 标题 | 手机还没授权这台 Mac |
| 副标题 | 看一眼手机屏幕，上面应该有一个弹窗在等你确认。 |
| 步骤 1 | 用数据线连接手机与 Mac，手机上把 USB 用途选为「传输文件」。 |
| 步骤 2 | 手机弹出上面这个窗口时，勾选「一律允许」再点「允许」。 |
| 步骤 3 | 回到 DroidBerth，点下面的按钮重新检测。 |
| 主按钮 | 已完成，重新检测 |

**结构与前置改动**：空态现在是「字符串 + 图标名」，**必须先改成「结构 + 动作」**（icon / 文案 / 按钮都作为参数传进空态视图），否则「重新检测」这个按钮挂不上 —— 这正是 §5 把 S1 排在 S4 前面的原因。

**四类空态的规格（稿子给的）**

| 场景 | SF Symbol | 颜色 | 按钮 |
|---|---|---|---|
| 未连接任何设备 | `cable.connector`（回退 `bolt.horizontal`） | `.secondaryLabelColor` | 主按钮「重新检测」+ 文字链「连接不上？」 |
| 照片图库权限被拒 | `lock`（备选 `hand.raised`） | 语义色（**不用警示橙**） | 主按钮「打开系统设置」+ 文字链「稍后再说」 |
| 文件夹是空的 | `folder`（备选 `tray`） | `.secondaryLabelColor` | **默认不放按钮** |
| 搜索无结果 | `magnifyingglass` | `.secondaryLabelColor` | 主按钮「清除筛选条件」（标签自适应：清除搜索词 / 清除类型筛选 / 全部清除） |

**四条落地规则**（都是能直接判对错的）：① 主文案要**带上产生空态的那个具体值**（「没有找到与『合同』匹配的文件」比「无搜索结果」多给一条确认信息）；② 空文件夹**不要用任何警示色或感叹号**，也不该有主按钮（中性状态做成操作入口会让人以为出了问题）；③ 照片权限那条**必须写明「其余功能不受影响」**（最坏的后果不是少了照片，而是用户以为整个 App 废了）；④ 搜索空态的按钮**始终只有一个**，但它清除的正是当前生效的那个筛选。

### 4.4 仓库约定

```
<repo>/docs/design/
├── DESIGN.md                    # 设计令牌唯一来源（S5 建立），稿子与代码都对齐它
└── 2026-10-10-ui-icons/
    ├── brief.md                 # 喂给 open-design 的需求与约束原文（本轮已落盘）
    ├── app-icon-directions.html # App 图标稿快照（920 行，便于 diff 与追溯）
    ├── icon-system.html         # 图标体系稿快照（1016 行）
    ├── brand-spec.md            # 稿子附带的品牌规范：六个 OKLCH token + 三条硬性禁忌
    └── shots/                   # before / after 截图 —— **本机无法截图**（`1009_01` §4.8），
                                 # 这一栏只能由人工补。不留空目录。
```

> `DESIGN.md` 的**内容已经现成**：`brand-spec.md` 里那六个 OKLCH token 与三条禁忌就是它。
> S5 要做的只是把它落成 macOS 侧的语义色映射（`Color.secondary` / 定值 hex / `.quaternary` 分别对应谁）。

---

## 5. 实施计划

> 每步都保证**可编译**（`swiftc -typecheck` 门禁），每步都可单独回滚。

| 步 | 改什么 | 文件 | 验收判据 | 回滚 |
|---|---|---|---|---|
| **S1** | 空态从「字符串 + 图标名」改成「结构 + 动作」 | `Views/EntryTable.swift`、`Views/EntryGrid.swift`、`Views/MainView.swift`、新增 `Views/EmptyStateView.swift` | 四类空态各有自己的 icon / 文案 / 按钮；`ContentUnavailableView` 的 actions 挂得上 | 单文件 |
| **S2** | 图标体系收敛到单一事实来源 | 新增 `Support/FileTypeIcon.swift`；删 `LocalFileSystem.swift:27-39` 与 `RemoteEntry.swift:21-34` 的 switch；`BrowserEntry` 改为携带 `icon: FileTypeIcon` | 同一扩展名在两栏得到**同一个**图标；`.apk` 在 Mac 栏不再显示通用文稿 | 单文件 |
| **S3** | App 图标生成 + 接入构建 | `scripts/make-icon.py` 重写为稿子定下的几何；`scripts/env.sh` 加图标路径；`scripts/build.sh` 加「生成图标」步（**必须在 xcodegen 之前**）；`project.yml` 加 `icon.icns` 资源 + `CFBundleIconFile`；`Info.plist` 加 `CFBundleIconFile` | `iconutil` 十档齐全；构建后 `Contents/Resources/icon.icns` 存在；`codesign -d --entitlements -` 仍是 **3 项**（不含 `get-task-allow`）；Dock 与 Finder 显示新图标 | `project.yml` + `Info.plist` 两处 |
| **S4** | 连接引导卡片 | `Views/EmptyStateView.swift`（或 `Views/DeviceGuideCard.swift`）、`AppModel` 暴露品牌字段 | 未授权时出现卡片；「重新检测」可点且真的重新检测；品牌槽位随 `model` 变化 | 单文件 |
| **S5** | 建立设计令牌 | `docs/design/DESIGN.md` | 稿子与代码的颜色 / 圆角 / 尺寸都能在令牌表里找到唯一来源 | 文档 |

**S3 的顺序约束（容易踩）**：`xcodegen` 在 `generate` 时**要求 `project.yml` 里列出的路径存在**，所以 `icon.icns` 必须在 `xcodegen generate` **之前**生成。这跟 sidecar 的暂存是同一个形状的前置条件 —— 放 `build.sh` 的 `==> 1/3` 之前即可。

**S2 的两处实现细节（稿子给的，都当待核对处理）**

- **缓存**：左栏走 `NSWorkspace.icon(forFile:)` 是同步调用，200 行列表不能每帧去要 ⇒ 按 `path` 缓存 `NSImage`（`NSCache`，与 `ThumbnailStore` 同风格）
- **稿子顺手改了音频符号**：现有 9 个符号里有 `music.note`，稿子改成 `waveform`。**这是一次有意改动**，不是笔误 —— `music.note` 是个音符（音乐），`waveform` 才是「一段音频」。要改就整体改，别只改一处

**S4 的文案与规格全部来自稿子 §3.3 / §4.1**（§4.3 已抄录），实现时**原样使用**，不要临场改写 —— 那三句「三步说明」和「其余功能不受影响」是经过推敲的。

### 5.4 刻意不做的事

| 不做 | 理由 |
|---|---|
| VoiceOver 标签 | 用户 2026-10-10 明确要求跳过（`1009_01` §4.8） |
| 引入自定义图标集 / 位图资产 | PRD §8 原则一；且我无法维护一套自绘图标 |
| 给 `.jpg` / `.heic` 分不同图标 | 用户心智里是同一件事，分图标只是噪音 |
| 给 `.mp4` / `.mov` / `.mkv` / `.avi` / `.webm` 分不同图标 | 同上。视频就是视频 |
| 改交互语义 | `1009_01` §8 总验收清单已全绿。这次只碰视觉 |
| 菜单栏常驻图标 | PRD §27 列为 P2，且会引入第二套状态机 |
| DMG 背景图 | PRD §27.2，非阻塞 |
| 自定义强调色覆盖系统设置 | 会违反 §8「不引入非系统视觉」。品牌色只用在**图标**与**传输方向**这种不受系统强调色管辖的地方 |

---

## 6. 风险

| 风险 | 说明 | 等级 |
|---|---|---|
| **图标进 bundle ⇒ 产物内容变化** | `CFBundleIconFile` 是 bundle 资源，**不属 §26.1 的身份字段**，不会作废已有公证记录。但发布前仍应重跑 `checklist.sh` 验一遍 | 低 |
| **`NSWorkspace.icon(forFile:)` 的同步开销** | 200 行列表不能每帧调用。必须按 `path` 缓存，否则会拖慢滚动 | 中 |
| **系统图标在 16pt 下的辨识度** | Finder 的彩色图标缩到 16pt 会糊成一团色块。这是「像 Finder」**必须付的代价** —— Finder 自己就是这样。若实测不可接受，退回策略乙/丙 | 中 |
| **本机无法截图** | `1009_01` §4.8 已记录：本机不能截图，视觉改动只能靠**编译 + 链接 + 人工验收**。所有「看起来对不对」的结论都要标注为待验收 | 中 |
| **稿子与代码分家** | 一旦令牌写两份（稿子一份、代码一份），下轮改版就要重新对一遍。故 S5 的 `DESIGN.md` 是**唯一来源** | 中 |

---

## 7. 待确认的五个决定

### 决定 1 · App 图标方向

稿子推荐 **A `two-berths`**（两块竖长面板 + 中间粗箭头）。我的判断：**同意 A**。它唯一的弱点是 16pt 下箭头与面板只剩约 1px 间隙 —— 而稿子已经给了修法（16pt 单独一档、间隙压到 0、箭头并进左面板），这条约束会真的落到生成脚本里，不是嘴上说说。

备选：C `dock-port` 在 16pt 下最干净，但「圆环 + 一条线」在任何连接类工具里都成立，失去身份。B 重心不稳，且 16pt 会糊成钝角块。

### 决定 2 · 品牌主色要不要用暖橙 ⚠️ 我的反对意见

| 选项 | 内容 | 代价 |
|---|---|---|
| ① 接受稿子的暖橙 | 主色 `#ED8725` 同时用于图标与界面方向标识 | **与现有警示色撞车**：`.orange` 现在表示「媒体入库失败」「仅部分照片可访问」，传输面板上会同时出现「上传中（橙）」与「入库失败（橙）」 |
| ② 换一个不撞语义色的主色 | 例如中蓝一档 | 稿子反对蓝的理由成立：Dock 里访达 / Safari / 文件夹全是蓝的，蓝色图标在 Dock 里最不跳 |
| **③ 品牌色只活在图标里（我倾向这条）** | App 图标用暖橙渐变；界面里的方向标识**继续用系统语义色**（上传 `accentColor` / 下载 `teal`），并把 `Color.teal` 换成定名的品牌辅色 `#1CA0AC` | 图标与界面不完全同色 —— 但这本来就是 macOS 的常态（Finder 图标是蓝色的，Finder 窗口里的选中色跟随系统强调色）。同时**顺手修掉 G5**：把「随便挑的 teal」变成「定名的品牌辅色」 |

**为什么倾向 ③**：它同时满足两件本来会互相打架的事 —— 图标有辨识度（Dock 里跳出来），界面不引入非系统视觉（PRD §8 原则一）。而且它把 G5 从「需要一个新决策」降级成「一次重命名」。

### 决定 3 · 两栏来源区分策略

稿子的结论：**策略乙**（本机彩色 `NSWorkspace` / 设备单色 SF Symbol）。

**我同意。** 稿子否掉甲的论据比「好不好看」硬得多 —— 甲在设备侧会**稳定谎报**：`base.aab` 这种 Android 专有扩展名在设备栏只能回退成灰色通用文稿图标，而它混在一排彩色图标里看起来仍像「系统认识它」。

代价（照实说）：同一扩展名在两栏会有**不同形状**；网格视图里设备端条目「有缩略图时彩色、回退时线框」不一致。第二条是真代价，若你更在意它，丙（两栏都单色）是唯一自洽的替代。

### 决定 4 · 两处「对系统默认的有意偏离」接不接受

稿子主动提出两处，我在 §4.2 给了逐条判断：

| 偏离 | 我的建议 |
|---|---|
| 次级列文字不用 `secondaryLabelColor`，改用 5.1:1 的定值 | **接受** —— 这是 PRD §25 的 AA 要求逼出来的，不是审美偏好 |
| 选中行填充改用品牌橙派生色 | **不接受** —— `Table` 的选中由系统画，改了只有网格跟着变，会造成两套选中视觉；诊断接受（品牌原色不能作底），药方不采纳 |

### 决定 5 · `docs/design/DESIGN.md` 的建立时机

建议与 S2 合并做（图标体系一落地，令牌同时定下来），避免「先建令牌再改标准」的返工。稿子的 `brand-spec.md` 已经把六个 OKLCH token 和三条硬性禁忌写出来了，`DESIGN.md` 主要是把它落成 macOS 侧的语义色映射。

---

确认后按 §5 的 S1 → S5 顺序执行，每步跑一次 `swiftc -typecheck` 门禁，每步单独提交。

---

## 9. 执行记录（2026-10-11）：五个决定全部按建议落地，S1–S5 已完成

用户的裁决是「意见采纳」——即全部按 §7 里我给出的倾向执行。实际做法与判据：

| 步 | 结果 | 判据 |
|---|---|---|
| **S2** 图标体系 | ✅ | 新增 `Support/FileTypeIcon.swift`（77 个扩展名的单一表）+ `Views/EntryIconView.swift`（策略乙）。两处 switch 已删。**回归核对落成了仓库里的脚本** `scripts/check-icon-mapping.swift`（29 条断言，跑法见 README「编译验证」）：`.apk` → `shippingbox`、`.app` → `doc`（原来分叉的那两条）、`m4a` 不被 `m4` 吞、`tsx` 不被 `ts` 吞、无扩展名落 `doc` —— 实跑 **ALL OK**。本项目没有测试 target，这个脚本是那条「两份事实必然分叉」缺陷目前唯一的自动化守卫 |
| **S1** 空态结构 | ✅ | 新增 `Views/PaneEmptyState.swift`（`PaneEmptyState` + `PaneEmptyStateView` + 「连接不上？」popover）。`EntryTable` / `EntryGrid` / `PhotoSourceView` 的 `emptyMessage: String` 全部换成 `emptyState:` |
| **S4** 引导卡片 | ✅ | 新增 `Views/DeviceGuideCard.swift`（手机授权弹窗示意图 + 三步 + 「已完成，重新检测」+ 品牌信息条）。`AndroidDevice.BrandFamily` 从 `devices -l` 已有字段推断 |
| **S3** App 图标 | ✅ | `scripts/make-icon.py` 重写；接入 `project.yml` / `Info.plist` / `build.sh` / `.gitignore` |
| **S5** 设计令牌 | ✅ | `docs/design/DESIGN.md` + `Support/DesignTokens.swift` |

### 三处「我来定」的判断，与原稿不同，理由都记下来了

| 项 | 稿子/原稿的意思 | 实际做法 | 为什么 |
|---|---|---|---|
| **16pt 档几何** | 稿子：「把间隙压到 0、箭头并进左侧面板做成实心楔形」 | **反向操作**：间隙**拉大**到 1.1px 以上、栏加宽、箭头换实心三角 | 照字面做，三块会并成**一片连续的白**，16px 下只剩一个白团 —— 那正是稿子自己反对 B 方向时用的失败判据。逐像素字符画核对：三段式在 16px 下成立 |
| **`sips -z` 降采样** | 原稿：「大尺寸沿用 `sips`」 | **自研 2×2 面积平均**（预乘空间，逐级折半） | 实测 `sips` 把投影压掉约 25%（母版下缘 30/255 → 256 档只剩 24），系统图标是 35。自己做既准又可复现，顺带少一个外部依赖 |
| **投影的剖面形状** | 原稿：`A·exp(-q²/2)` | **正态 CDF**（`Φ(z)`） | 高斯本身会给出一个**假的平顶**；真实（被模糊的阶跃）剖面在边缘就已经开始衰减。换 CDF 后拟合残差平方和从 935 降到 **24** |

### 数值验收（都跑过，不是推断）

| 项 | 结果 |
|---|---|
| SF Symbol 可用性 | 用 `NSImage(systemSymbolName:)` 逐个探测：**69 + 14 = 83 个全部存在**，含稿子标为「把握较低」的 `tablecells` / `opticaldisc` / `cable.connector` / `arrow.turn.up.right` |
| 图标几何 | 母版实体 bbox **824×824**、边距 **100** —— 与 Apple 规范（以及系统图标实测的 816/104，差值即边缘抗锯齿）一致 |
| 投影剖面（256 档，下缘） | 自研 **31/255**，系统图标 **35/255**；上缘 12 / 12；侧向 21 / 23 |
| bundle 内图标 | `Contents/Resources/icon.icns` 与生成物 **逐字节相同**（`cmp`）；`iconutil` 解出 **10 档**；`CFBundleIconFile = icon` |
| 图标真的生效 | 把 app 复制到新路径交给 `NSWorkspace.icon(forFile:)`，取回的是**橙底 + 白色双栏**（不是系统通用图标）。⚠️ 原地路径上 LS 会命中**旧缓存**仍返回灰色通用图标 —— 这是重建同一个 bundle id 时的既有行为，不是图标的问题 |
| 构建 | Release + Debug **双配置 0 error / 0 warning** |
| Release entitlements | **3 项**、不含 `get-task-allow`（PRD §28 判据）；Debug 4 项、含（调试 attach 需要） |
| `Contents/MacOS/` | 恰好 3 个可执行文件 |

### 踩到并记下的新坑

1. **新增源文件后必须重跑 `xcodegen generate`** —— 否则文件不在工程里，报的是「cannot find X in scope」加一个「failed to produce diagnostic」的级联错误。`DesignTokens.swift` 就栽在这里。
2. **`xcodebuild` 在本机沙箱里需要 `OTHER_SWIFT_FLAGS=-disable-sandbox`**（只加在命令行，**不进工程文件**）。不带它会得到一组看起来像真错误的诊断。
3. **`main.swift` 的顶层代码在 Swift 6 下是 MainActor 隔离的** —— 以此写一次性核对脚本时，顶层 `var` 不能被 nonisolated 的 helper 改动，helper 要标 `@MainActor`。
4. **`NSWorkspace.icon(forFile:)` 返回的是「类型图标」不是内容**，拿它探 PNG 只会得到灰色图片图标 —— 探 app 才有意义（但会命中 LS 缓存）。
