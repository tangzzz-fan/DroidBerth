# 设计稿 ↔ 实现 一致性审计（2026-10-11）

| 项 | 值 |
|---|---|
| 版本 | v1.0 |
| 日期 | 2026-10-11 |
| 范围 | `macos/Sources/DroidBerth/` 的图标 / 空态 / 引导卡片 / 品牌文案 / 颜色令牌 / App 图标几何 |
| 稿件（真源，只读） | `docs/design/2026-10-10-ui-icons/icon-system.html`、`docs/design/2026-10-10-ui-icons/app-icon-directions.html`、`docs/design/DESIGN.md`、`docs/1010_01_ui-icon-design-report.md` |
| 性质 | **只读审计**。除本文件外未改动任何代码 |
| 判定词 | **一致** / **偏离** / **未实现**（三选一） |
| 有意偏离口径 | `1010_01` §9 记录的三处（16pt 档几何反向、投影用 CDF 而非高斯、`sips`→自研面积平均）与 `DESIGN.md` 记录的偏离，**不计为缺陷**；但逐条核对是否真按记录执行（见 §7） |

---

## 0. 一句话结论

**总体符合度高（一致 53 条 / 偏离 16 条 / 未实现 9 条），结构性设计（符号映射表、四类空态骨架、策略乙、App 图标几何）几乎零偏差；所有偏差集中在「文案」与「DESIGN.md 主动否决稿子」这两类。最该修的 3 条：**

1. **USB 卡片品牌文案整段未按稿子落**（`AndroidDevice.swift:101-114`）——稿子 §3.3 给了逐字文案，实现是自写的 5 段（且默认「没看到弹窗？」与「弹窗不再出现」两段**根本没实现**）。这是用户会照着操作的说明文字，最该修。
2. **USB 卡片手机弹窗示意图三处文案与稿子不同**：指纹标签（`这台 Mac 的 RSA 密钥指纹：` vs 稿子 `计算机的 RSA 密钥指纹为：`）、复选框（`一律允许` vs 稿子 `一律允许使用这台计算机进行调试`）、指纹示例值不同（`DeviceGuideCard.swift:175/180/189`）。
3. **空态 4 的按钮未做标签自适应**（`PaneEmptyState.swift:59` 恒为 `清除搜索词`），稿子 §4.1/§5 C 要求按当前筛选项在 `清除搜索词 / 清除类型筛选 / 全部清除` 之间切换；另 §5 C 表格与 §4.1 表对按钮文案本身不一致（见 §8）。

次要但建议一并处理：目录图标常驻 `folder.fill`（稿子：默认 `folder`、选中 `folder.fill`）、USB 卡片头部缺 `cable.connector`、空态 2 未上稿子指定的品牌深橙、空态图标未按 48pt。

---

## 1. ① 文件类型符号映射

真源：`icon-system.html` §1.2 表 + §5 A 代码块。实现：`Support/FileTypeIcon.swift`。

| 稿子要求（精确到字） | 实现（file:line + 精确字符串/符号名） | 判定 |
|---|---|---|
| 文件夹：右栏 `folder`，**选中态** `folder.fill`（§1.2 / §5 A） | `FileTypeIcon.swift:37` `static let directorySymbol = "folder.fill"`（常驻，无未选中/选中之分） | 偏离 |
| 替身 / 符号链接：右栏**不适用、不新增**（§1.2；仅策略丙才需 `arrow.turn.up.right`） | 未新增任何替身符号；`LocalFileSystem.swift:37` / `RemoteEntry.swift:22` 只调 `FileTypeIcon.symbol(forName:isDirectory:)` | 一致 |
| 无扩展名 → `doc`（§1.2 / §5 A 注释） | `FileTypeIcon.swift:36` `fallbackSymbol = "doc"`；`:82` `guard !ext.isEmpty else { return fallbackSymbol }` | 一致 |
| 未知类型 → `doc`（§1.2 / §5 A 注释） | `FileTypeIcon.swift:83` `symbolByExtension[ext] ?? fallbackSymbol` | 一致 |
| 图片（位图）jpg jpeg png heic heif gif webp tif tiff bmp avif → `photo`（§1.2 / §5 A） | `FileTypeIcon.swift:49-51` `put("photo", ["jpg","jpeg","png","heic","heif","gif","webp","tif","tiff","bmp","avif","svg", …])` | 一致（多 `svg`，见 §4） |
| 相机 RAW dng raw cr2 nef arw → `photo`（并入图片，B-1） | `FileTypeIcon.swift:51` `"dng","raw","cr2","nef","arw"` | 一致 |
| 视频 mp4 mov m4v mkv avi webm wmv flv 3gp ts → `film`（§1.2 / §5 A） | `FileTypeIcon.swift:52` `put("film", ["mp4","mov","m4v","mkv","avi","webm","wmv","flv","3gp","ts"])` | 一致 |
| 音频 mp3 wav aac flac m4a ogg opus → `waveform`（§1.2 / §5 A） | `FileTypeIcon.swift:53` `put("waveform", ["mp3","wav","aac","flac","m4a","ogg","opus","wma"])` | 一致（多 `wma`，见 §4） |
| 纯文本 / 标记 txt md → `doc.text`（§1.2 / §5 A） | `FileTypeIcon.swift:56` `put("doc.text", ["txt","md","log","doc","docx","pages","ppt","pptx","key"])` | 一致（多 `log`，见 §4） |
| PDF pdf → `doc.richtext`（§1.2 / §5 A） | `FileTypeIcon.swift:54` `put("doc.richtext", ["pdf", "rtf"])` 的 `"pdf"` | 一致 |
| 富文本 / 办公文稿 rtf doc docx pages → `doc.text`（§1.2 表 + §5 A 代码 `put("doc.text", ["txt","md","rtf", …])`） | `FileTypeIcon.swift:54` 把 `"rtf"` 放进 `doc.richtext`；`:56` 的 `doc.text` **不含** `rtf` | 偏离（跟了 DESIGN.md §3.3，非稿子） |
| 表格 xls xlsx csv numbers → `tablecells`（新增）（§1.2 / §5 A） | `FileTypeIcon.swift:55` `put("tablecells", ["xls","xlsx","csv","numbers"])` | 一致 |
| 演示文稿 ppt pptx key → `doc.text`（不新增，B-5） | `FileTypeIcon.swift:56` 含 `"ppt","pptx","key"` | 一致 |
| 压缩包 zip rar 7z tar gz → `doc.zipper`（§1.2 / §5 A） | `FileTypeIcon.swift:57` `put("doc.zipper", ["zip","rar","7z","tar","gz","bz2","xz"])` | 一致（多 `bz2 xz`，见 §4） |
| 磁盘映像 dmg iso → `opticaldisc`（新增）（§1.2 / §5 A） | `FileTypeIcon.swift:58` `put("opticaldisc", ["dmg","iso"])` | 一致 |
| 安装包 apk aab ipa exe → `shippingbox`（并入 apk，B-7） | `FileTypeIcon.swift:59` `put("shippingbox", ["apk","aab","ipa","exe"])` | 一致 |
| 代码 / 配置 json xml yaml yml toml plist sh py js swift rs html css → `chevron.left.forwardslash.chevron.right`（新增）（§1.2 / §5 A） | `FileTypeIcon.swift:60-62` `put("chevron.left.forwardslash.chevron.right", ["json","xml","yaml","yml","toml","plist","sh","py","js","tsx","swift","rs","html","css"])` | 一致（多 `tsx`，见 §4） |
| 净增 **3** 个符号：`tablecells` / `opticaldisc` / `chevron.left.forwardslash.chevron.right`（§1.5 / §5 A） | 新增符号恰为这 3 个 | 一致 |
| 必须**完整扩展名精确匹配**，不能截前缀（§1.6） | `FileTypeIcon.swift:81` `name.pathExtensionLowercased`（取整段扩展名）；`:83` 精确查表 | 一致 |

**小结：一致 17 / 偏离 1 / 未实现 0**（§1 共 18 条）。

---

## 2. ② 四类空态

真源：`icon-system.html` §4 样张 + §4.1 规格表 + §5 C 文案清单。实现：`Views/PaneEmptyState.swift`、`Views/MainView.swift`、`Views/PhotoSourceView.swift`。

| 稿子要求（精确到字） | 实现（file:line + 精确字符串/符号名） | 判定 |
|---|---|---|
| 空态 1 符号 `cable.connector`（回退 `bolt.horizontal`）（§4.1） | `MainView.swift:621` `systemImage: "cable.connector"` | 一致 |
| 空态 1 主文案「还没有连接 Android 设备」（§4.1 / §5 C） | `MainView.swift:622` `title: "还没有连接 Android 设备"` | 一致 |
| 空态 1 辅文案「用 USB 线把手机接到这台 Mac，手机上把 USB 用途选为「传输文件」。」（§5 C；§4.1 用『』） | `MainView.swift:623` `message: "用 USB 线把手机接到这台 Mac，手机上把 USB 用途选为「传输文件」。"` | 一致 |
| 空态 1 主按钮「重新检测」（§4.1 / §5 C） | `MainView.swift:624` `.init(title: "重新检测")` | 一致 |
| 空态 1 文字链「连接不上？」（§5 C） | `MainView.swift:625` `troubleshooting: Self.usbTroubleshooting` → `PaneEmptyState.swift:137` `Button("连接不上？")` | 一致 |
| 空态 2 符号 `lock`（备选 `hand.raised`）（§4.1） | `PhotoSourceView.swift:184` `systemImage: "lock"` | 一致 |
| 空态 2 主文案「DroidBerth 没有照片访问权限」（§4.1 / §5 C） | `PhotoSourceView.swift:185` `title: "DroidBerth 没有照片访问权限"` | 一致 |
| 空态 2 辅文案「照片图库暂时不能浏览。文件推送、设备浏览等功能不受影响。可在「系统设置 › 隐私与安全性 › 照片」里重新打开。」（§5 C） | `PhotoSourceView.swift:188` `"照片图库暂时不能浏览。文件推送、设备浏览等功能不受影响 —— 可在「系统设置 › 隐私与安全性 › 照片」里重新打开。"`（多插入了 ` —— `） | 偏离 |
| 空态 2 主按钮「打开系统设置」（§4.1 / §5 C） | `PhotoSourceView.swift:189` `.init(title: "打开系统设置")` | 一致 |
| 空态 2 文字链「稍后再说」（§4 样张 / §5 C） | `PhotoSourceView.swift:190` `.init(title: "先用 Finder 位置")` | 偏离（有意，DESIGN.md §5.4 规则 3 明确否决「稍后再说」；见 §8） |
| 空态 2 颜色＝品牌深橙 `oklch(56% .152 55)`（§4 sec-sub + §4.1 表） | `PhotoSourceView.swift:181-193` 走 `PaneEmptyStateView`→`ContentUnavailableView`，**未上任何品牌色** | 未实现（跟了 DESIGN.md §2/§4） |
| 空态 3 符号 `folder`（备选 `tray`）（§4.1） | `PaneEmptyState.swift:44` `systemImage: "folder"` | 一致 |
| 空态 3 主文案「这个文件夹是空的」（§4.1 / §5 C） | `PaneEmptyState.swift:45` `title: "这个文件夹是空的"` | 一致 |
| 空态 3 辅文案「这里还没有文件。可以从另一栏拖进来，或直接把文件拖到这个窗口。」（§4.1 / §5 C） | `PaneEmptyState.swift:48` 完全相同 | 一致 |
| 空态 3 **默认无按钮**（§4.1「默认无按钮」/ §5 C「可选，默认不放按钮」） | `PaneEmptyState.swift:42-50` 无 `primary`/`secondary` | 一致（跟了 §4.1/§5 C 版；§4 样张画了「刷新」按钮——见 §8） |
| 空态 4 符号 `magnifyingglass`（§4.1） | `PaneEmptyState.swift:54` `systemImage: "magnifyingglass"` | 一致 |
| 空态 4 主文案「没有找到与「{关键词}」匹配的文件」（§4.1 / §5 C） | `PaneEmptyState.swift:57` `title: "没有找到与「\(query)」匹配的文件"` | 一致 |
| 空态 4 辅文案「试试更短的关键词，或者清除当前的筛选条件。」（§4.1 / §5 C） | `PaneEmptyState.swift:58` 完全相同 | 一致 |
| 空态 4 按钮**标签自适应**：`清除搜索词 / 清除类型筛选 / 全部清除`（§4.1 注 / §4 要点 2 / §5 C） | `PaneEmptyState.swift:59` 恒为 `Action(title: "清除搜索词", …)` | 未实现 |

**小结：一致 15 / 偏离 2 / 未实现 2**（§2 共 19 条）。

---

## 3. ③ USB 引导卡片

真源：`icon-system.html` §3.1 / §3.2 / §3.3 / §5 C。实现：`Views/DeviceGuideCard.swift`、`Views/MainView.swift`。

| 稿子要求（精确到字） | 实现（file:line + 精确字符串/符号名） | 判定 |
|---|---|---|
| 标题「手机还没授权这台 Mac」（§3.2 / §5 C） | `MainView.swift:580` `title: "手机还没授权这台 Mac"` | 一致 |
| 副标题「看一眼手机屏幕，上面应该有一个弹窗在等你确认。」（§3.2 / §5 C） | `MainView.swift:584` `subtitle: "看一眼手机屏幕，上面应该有一个弹窗在等你确认。"` | 一致 |
| 步骤 1「用数据线连接手机与 Mac，手机上把 USB 用途选为「传输文件」。」（§3.2 / §5 C） | `MainView.swift:586` 完全相同 | 一致 |
| 步骤 2「手机弹出上面这个窗口时，勾选「一律允许」再点「允许」。」（§3.2 / §5 C） | `MainView.swift:587` 完全相同 | 一致 |
| 步骤 3「回到 DroidBerth，点下面的按钮重新检测。」（§3.2 / §5 C） | `MainView.swift:588` 完全相同 | 一致 |
| 主按钮「已完成，重新检测」（§3.2 / §5 C） | `MainView.swift:590` `primaryTitle: "已完成，重新检测"` | 一致 |
| 卡片头部用 `cable.connector`（回退 `bolt.horizontal`），与空态 1 同符号（§3.3 技术注） | `DeviceGuideCard.swift:19-60` 头部只有 illustration + 标题，**无 header 图标**；`cable.connector` 仅出现在 `:78` 的无线插图里 | 未实现 |
| 手机弹窗标题「允许 USB 调试吗？」（§3.2） | `DeviceGuideCard.swift:170` `Text("允许 USB 调试吗？")` | 一致 |
| 指纹标签「计算机的 RSA 密钥指纹为：」（§3.2） | `DeviceGuideCard.swift:175` `Text("这台 Mac 的 RSA 密钥指纹：")` | 偏离 |
| 指纹示例值「A4:7B:9F:2C:11:E8:5D:03 / 6A:B2:44:19:7C:D5:88:31」（§3.2；§3.3 注为示例值） | `DeviceGuideCard.swift:180` `Text("4B:1C:9F:22:AE:70:5D:38\nC1:04:7A:9E:B3:56:20:DD")` | 偏离（示例值不同，非功能） |
| 复选框文案「一律允许使用这台计算机进行调试」（§3.2） | `DeviceGuideCard.swift:189` `Text("一律允许")` | 偏离 |
| 弹窗按钮「取消」/「允许」（§3.2） | `DeviceGuideCard.swift:197-198` `mockButton("取消", prominent: false)` / `mockButton("允许", prominent: true)` | 一致 |
| 底部默认品牌文案「**没看到弹窗？**请确认「开发者选项」里的「USB 调试」已经打开，并把 USB 用途改为「传输文件 / MTP」。」（§3.2 样张 + §3.3 表第一行） | `DeviceGuideCard.swift:36-38, 110-123` 仅在 `guide.brandNote != nil` 时渲染；默认 `brandNote = device.brandFamily?.authorizationNote`（未识别品牌 = `nil`）⇒ **无默认文案** | 未实现 |
| 卡片按 **300pt 宽**设计、正文 **≥11pt**（§3 sec-sub / §3.3） | `DeviceGuideCard.swift:17` `contentWidth = 300`；正文用 `.caption`（≈11pt） | 一致 |
| 主按钮高度 30–32pt（§3.3 技术注） | `DeviceGuideCard.swift:41-43` `.buttonStyle(.borderedProminent).controlSize(.regular)`，未指定 30–32pt | 未实现 |

**小结：一致 9 / 偏离 3 / 未实现 3**（§3 共 15 条）。

---

## 4. ④ 品牌变体文案

真源：`icon-system.html` §3.3 表（5 行，逐字文案）。实现：`ADB/AndroidDevice.swift:100-115`（`BrandFamily.authorizationNote`）。

> 稿子 §3.3 规定：检测方式 `adb shell getprop ro.product.brand`（回退 `ro.product.manufacturer`）；译文**逐字**。`DESIGN.md` §5.5 主动改了两点：① 检测改用 `adb devices -l` 已有字段（`model`/`product`/`device`）；② 文案写成「还可能需要…」而非断言。实现跟了 `DESIGN.md` 的思路并要求逐字核对。

| 稿子要求（精确到字） | 实现（file:line + 精确字符串） | 判定 |
|---|---|---|
| 通用（默认）「**没看到弹窗？**请确认「开发者选项」里的「USB 调试」已经打开，并把 USB 用途改为「传输文件 / MTP」。」 | 未实现（`brandNote` 为 nil 时不渲染，见 §3） | 未实现 |
| 小米 / Redmi / POCO「**小米设备：**先到「设置 › 我的设备 › 全部参数与信息」连点「MIUI 版本」7 次，再回「设置 › 更多设置 › 开发者选项」打开「USB 调试」。部分机型需要登录小米账号并插入 SIM 卡后，才能打开「USB 调试（安全设置）」。」 | `AndroidDevice.swift:104` `"检测到 \(label)。这类机型在「开发者选项」里通常还有一个「USB 调试（安全设置）」，需要单独打开并等待倒计时结束。"`（`label` = `"小米 / Redmi / POCO"`） | 偏离 |
| OPPO / realme / 一加「**OPPO 系设备：**到「设置 › 关于手机 › 版本信息」连点「版本号」7 次，再回「设置 › 系统设置 › 开发者选项」打开「USB 调试」。部分 ColorOS 版本要求先登录 OPPO 账号。」 | `AndroidDevice.swift:106` `"检测到 \(label)。这类机型的「USB 调试」可能带一个需要登录账号才能开启的开关；另外确认「默认 USB 配置」是「传输文件」。"` | 偏离 |
| vivo / iQOO「**vivo 设备：**到「设置 › 更多设置 › 关于手机」连点「软件版本号」7 次，再回「设置 › 系统管理 › 开发者选项」打开「USB 调试」。开启前需登录 vivo 账号。」 | `AndroidDevice.swift:108` `"检测到 \(label)。这类机型可能要求登录账号后才能打开「USB 调试（安全设置）」，打开后请再插拔一次数据线。"` | 偏离 |
| 「弹窗不再出现」（任意品牌）「**还是没有弹窗？**到「开发者选项」里点一次「撤销 USB 调试授权」，然后拔掉数据线重新插上。」 | 未实现：无对应文案；`MainView.swift:629-634` 的 `usbTroubleshooting` 四条均未提「撤销 USB 调试授权」 | 未实现 |
| 检测方式 `getprop ro.product.brand`（回退 `ro.product.manufacturer`）（§3.3） | `AndroidDevice.swift:56-65` 用 `adb devices -l` 的 `model`/`product`/`device` 做子串匹配 | 偏离（有意，DESIGN.md §5.5 说明未授权时 `adb shell` 不可用） |

**小结：一致 0 / 偏离 4 / 未实现 2**（§4 共 6 条；「三星」「华为」两族为稿子未列的额外实现，见 §6）。

---

## 5. ⑤ 颜色 / 尺寸令牌

真源：`icon-system.html` §5 B 表（颜色/状态 token）、§4 sec-sub（空态图标 48pt）、§3.3（按钮高度）。实现：`Support/DesignTokens.swift`、`Views/MainView.swift`（`PaneFocusStyle`）、`Views/EntryGrid.swift`、`Views/EntryTable.swift`。

| 稿子要求（精确到字） | 实现（file:line + 精确值） | 判定 |
|---|---|---|
| 选中行填充＝`oklch(56% .152 55)`，两模式同值（§5 B） | 未使用品牌橙填充：列表走系统选中；网格 `EntryGrid.swift:126` `Color.accentColor.opacity(0.18)` | 偏离（有意，DESIGN.md §7「已否决」） |
| 选中行内文字与图标＝纯白，**不做任何透明度衰减**（§5 B） | 列表由系统绘制、网格用 `accentColor`（无纯白覆写） | 未实现（不可行，同 DESIGN.md §7） |
| 列表图标（未选中）＝`.secondaryLabelColor`（§5 B） | `EntryIconView.swift:35` `.foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)` | 一致 |
| 种类 / 大小 / 日期列文字＝浅 `#6E6E73`　深 `rgba(235,235,245,.62)`（§5 B） | `DesignTokens.swift:39-42` `columnText = adaptive(light: 6E6E73, dark: rgba(235,235,245,.62))`；落点 `EntryTable.swift:47/56/64`、`EntryGrid.swift:120`、`PreviewPane.swift:99/102/106` | 一致 |
| 48pt 空态图标＝`.secondaryLabelColor` `.regular`（§4 sec-sub / §5 B） | 走 `ContentUnavailableView`（`PaneEmptyState.swift:110-123`），未设 48pt | 未实现（DESIGN.md §4 改为「系统默认尺寸」） |
| 焦点环＝**品牌深橙，不是 `#ED8725`**（§5 B） | `MainView.swift:1098` `strokeBorder(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)` | 偏离（有意，DESIGN.md §2 用系统色） |
| 品牌原色 `#ED8725` 只用于非文字强调与渐变，**不作填充底**（§5 B） | `DesignTokens.swift:21` `brandPrimary` 定义但注释「界面里不要用它」；界面无品牌橙填充底 | 一致（实现侧行为与稿子「不作填充底」一致） |
| `.tertiaryLabelColor` **禁用于空态图标**（§5 B） | 空态图标未使用 `.tertiary` | 一致 |

**小结：一致 4 / 偏离 2 / 未实现 2**（§5 共 8 条）。

---

## 6. ⑥ App 图标几何

真源：`app-icon-directions.html`（规范段）+ `1010_01` §7 决定 1。实现：`scripts/make-icon.py`。

| 稿子要求（精确到字） | 实现（file:line + 精确值） | 判定 |
|---|---|---|
| 画布 `1024 × 1024 px`（规范） | `make-icon.py:40` `CANVAS = 1024` | 一致 |
| 内容区超矩形 `824 × 824` 居中，四周 `100 pt` 透明留白（规范） | `make-icon.py:41-43` `CONTENT = 824`、`CONTENT_MIN = 100`、`CONTENT_MAX = 924` | 一致 |
| 底板超椭圆 `\|x\|⁵ + \|y\|⁵ = r⁵`（非普通圆角）（规范） | `make-icon.py:44` `SUPER_N = 5`；`:97-103` `superellipse_distance` | 一致 |
| 底板填充垂直渐变 `#F9A04A → #DE6B20`，铺满**内容区**（规范 / 色板段） | `make-icon.py:47-48` `BRAND_LIGHT = (249,160,74)`、`BRAND_DARK = (222,107,32)`；`:208` 按内容区高度求 t | 一致 |
| 左 / 右栏圆角矩形 `(158,272)-(348,752)` / `(676,272)-(866,752)`，圆角 56（母版说明） | `make-icon.py:65-68` `((158,272,348,752,56),(676,272,866,752,56))` | 一致 |
| 箭头折线 `(453,402)→(571,512)→(453,622)`，线宽 86、圆头圆角，白（母版说明） | `make-icon.py:69-70` `((453,402),(571,512),(453,622))`、`STANDARD_ARROW_HALF_WIDTH = 43.0`（线宽 86）；白 `:204` | 一致 |
| 32 与 16 两档**不加投影**（尺寸阶梯注，A/B/C 三段均有） | `make-icon.py:287` `render()` 对**所有**尺寸都调用 `shadow_alpha`；16pt 档 `:414` 原生渲染仍带投影，32/16px 由母版降采样也带投影 | 偏离 |
| 16pt 单独一档：稿子「把间隙压到 **0**、箭头并进左侧面板做成**实心楔形**」（推荐段） | `make-icon.py:83-87` `SMALL_PANELS`（间隙**拉大**）+ `SMALL_ARROW_TRIANGLE` 实心三角 | 偏离（有意，`1010_01` §9 / `DESIGN.md` §6.3 记录为反向操作） |
| 投影按系统量级模拟：**y 18 / blur 40 / 45% 黑**（规范） | `make-icon.py:56-58` `SHADOW_ALPHA = 0.18`、`SHADOW_DY = 8.5`、`SHADOW_SIGMA = 15.0`，剖面用**正态 CDF**（`:221-235`） | 偏离（有意，`1010_01` §9 记录改用 CDF） |
| 选方向 **A `two-berths`**（verdict 段） | `make-icon.py` 全篇按 A 的几何实现 | 一致 |
| 不放文字 / 字母 / 水印（规范约束 02） | 几何仅超椭圆 + 圆角矩形 + 折线，无文字 | 一致 |

**小结：一致 8 / 偏离 3 / 未实现 0**（§6 共 11 条）。

---

## 7. 「偏离 / 未实现」清单（按用户可见程度排序：文案 > 符号 > 颜色 > 尺寸）

> 「改法」列写的是**照抄即可**的具体内容。

### A. 文案（最该先修）

| # | 位置 | 现在（file:line） | 改成（稿子原文） |
|---|---|---|---|
| A1 | 品牌变体·小米 | `AndroidDevice.swift:104` | `小米设备：先到「设置 › 我的设备 › 全部参数与信息」连点「MIUI 版本」7 次，再回「设置 › 更多设置 › 开发者选项」打开「USB 调试」。部分机型需要登录小米账号并插入 SIM 卡后，才能打开「USB 调试（安全设置）」。` |
| A2 | 品牌变体·OPPO | `AndroidDevice.swift:106` | `OPPO 系设备：到「设置 › 关于手机 › 版本信息」连点「版本号」7 次，再回「设置 › 系统设置 › 开发者选项」打开「USB 调试」。部分 ColorOS 版本要求先登录 OPPO 账号。` |
| A3 | 品牌变体·vivo | `AndroidDevice.swift:108` | `vivo 设备：到「设置 › 更多设置 › 关于手机」连点「软件版本号」7 次，再回「设置 › 系统管理 › 开发者选项」打开「USB 调试」。开启前需登录 vivo 账号。` |
| A4 | 品牌变体·通用（默认）**未实现** | `DeviceGuideCard.swift:36-38`（nil 时整段不渲染） | 新增默认分支：`**没看到弹窗？**请确认「开发者选项」里的「USB 调试」已经打开，并把 USB 用途改为「传输文件 / MTP」。`（`brandFamily == nil` 时使用） |
| A5 | 「弹窗不再出现」变体**未实现** | 无 | 在排查清单或品牌条增加：`**还是没有弹窗？**到「开发者选项」里点一次「撤销 USB 调试授权」，然后拔掉数据线重新插上。` |
| A6 | USB 弹窗·复选框 | `DeviceGuideCard.swift:189` `一律允许` | `一律允许使用这台计算机进行调试` |
| A7 | USB 弹窗·指纹标签 | `DeviceGuideCard.swift:175` `这台 Mac 的 RSA 密钥指纹：` | `计算机的 RSA 密钥指纹为：` |
| A8 | 空态 2·辅文案多出 ` —— ` | `PhotoSourceView.swift:188` `…不受影响 —— 可在…` | 删去 ` —— `：`照片图库暂时不能浏览。文件推送、设备浏览等功能不受影响。可在「系统设置 › 隐私与安全性 › 照片」里重新打开。` |
| A9 | 空态 4·按钮未自适应 | `PaneEmptyState.swift:59` 恒 `清除搜索词` | 按当前筛选项切换：`清除搜索词` / `清除类型筛选` / `全部清除`（三者都生效＝`全部清除`） |
| A10 | USB 弹窗·指纹示例值 | `DeviceGuideCard.swift:180` `4B:1C:9F:22:AE:70:5D:38 / C1:04:7A:9E:B3:56:20:DD` | 稿子示例：`A4:7B:9F:2C:11:E8:5D:03 / 6A:B2:44:19:7C:D5:88:31`（§3.3 明示为示例值，非功能项） |
| A11 | 空态 2·文字链（**有意偏离**，确认保留） | `PhotoSourceView.swift:190` `先用 Finder 位置` | 稿子：`稍后再说`；DESIGN.md §5.4 规则 3 主动否决。**按 DESIGN.md 保留**，只在文档里登记 |

### B. 符号

| # | 位置 | 现在 | 改成 |
|---|---|---|---|
| B1 | 目录图标默认态 | `FileTypeIcon.swift:37` `directorySymbol = "folder.fill"`（常驻） | 未选中 `folder`、选中态 `folder.fill`（§1.2 / §5 A） |
| B2 | USB 卡片头部图标**未实现** | `DeviceGuideCard.swift:19-60` 无 header 图标 | 卡片头部加 `cable.connector`（回退 `bolt.horizontal`），与空态 1 同符号（§3.3） |

### C. 颜色

| # | 位置 | 现在 | 改成 |
|---|---|---|---|
| C1 | 空态 2 图标色**未实现** | `PhotoSourceView.swift:181-193` 走系统 `ContentUnavailableView` 默认色 | 品牌深橙 `oklch(56% .152 55)`（§4 sec-sub / §4.1） |
| C2 | 空态图标 48pt 与色**未落** | `PaneEmptyState.swift:110-123` 系统默认 | 48pt `.regular`、`.secondaryLabelColor`（§4 sec-sub / §5 B）；= `DESIGN.md` §4 改成系统默认尺寸 |
| C3 | 焦点环 / 选中填充（**有意偏离**） | `MainView.swift:1098` `accentColor`；`EntryGrid.swift:126` `accentColor.opacity(0.18)` | 稿子：品牌深橙 / `oklch(56% .152 55)`；DESIGN.md §2/§7 主动保持系统色。**按 DESIGN.md 保留** |

### D. 尺寸

| # | 位置 | 现在 | 改成 |
|---|---|---|---|
| D1 | USB 主按钮高度**未实现** | `DeviceGuideCard.swift:41-43` `.controlSize(.regular)` | 高度 30–32pt（§3.3 技术注） |
| D2 | 32 / 16 档仍带投影 | `make-icon.py:287` 全档调用 `shadow_alpha` | 32 与 16 两档不加投影（尺寸阶梯注） |
| D3 | 16pt 档几何（**有意偏离**） | `make-icon.py:83-87` 反向操作 | 稿子：间隙压到 0、实心楔形；`1010_01` §9 / `DESIGN.md` §6.3 记录为有意反向 |
| D4 | 投影剖面（**有意偏离**） | `make-icon.py:221-235` 正态 CDF，A=0.18/dy=8.5/σ=15 | 稿子：y18/blur40/45%；`1010_01` §9 记录改用 CDF。**按记录保留** |

---

## 8. 稿子自相矛盾处（并说明实现跟了哪一版）

| # | 稿子内部冲突 | 实现跟了哪一版 |
|---|---|---|
| 1 | **空态 3 有没有「刷新」按钮**：§4 样张（`icon-system.html:843`）画了灰色「刷新」按钮；§4.1 规格表（`:882`）与 §5 C（`:990`）写「默认不放按钮 / 可选」。 | 跟了 §4.1 / §5 C（**无按钮**，`PaneEmptyState.swift:42-50`）。判定：一致。 |
| 2 | **空态 4 按钮文案**：§4.1 表（`:888`）写「清除筛选条件」；§5 C（`:993`）写「清除搜索词 / 清除类型筛选 / 全部清除（按当前生效的筛选项切换）」；§4 sec-sub 要点 2（`:898`）同 §5 C 要求自适应。 | 两边都只取一半：`PaneEmptyState.swift:59` 用了 §5 C 的首项「清除搜索词」，但**未做自适应**（既非 §4.1 的固定「清除筛选条件」）。判定：未实现（A9）。 |
| 3 | **空态 2 的引号层级**：§4.1 表用 `可在『系统设置 › …』`（`:877`），§5 C 用 `可在「系统设置 › …」`（`:985`）；§4.1 空态 1 用 `『传输文件』`（`:871`），§5 C 用 `「传输文件」`（`:981`）。 | 跟了 §5 C 的 `「」`（`PhotoSourceView.swift:188`、`MainView.swift:623`）。不影响判定。 |
| 4 | **空态 2 文字链**：稿子 §4 样张 / §5 C 写「稍后再说」；`DESIGN.md` §5.4 规则 3 明确否决并改成「先用 Finder 位置」。 | 跟了 `DESIGN.md`（`PhotoSourceView.swift:190`）。判定：偏离（有意）。 |
| 5 | **rtf 归属**：稿子 §1.2 表与 §5 A 代码都把 `rtf` 放 `doc.text`；`DESIGN.md` §3.3 把 `rtf` 放 `doc.richtext`。 | 跟了 `DESIGN.md`（`FileTypeIcon.swift:54`）。判定：偏离。 |
| 6 | **空态图标尺寸**：稿子 §4 sec-sub 写 48pt `.regular`；`DESIGN.md` §4 写「系统 `ContentUnavailableView` 默认尺寸」。 | 跟了 `DESIGN.md`（系统默认）。判定：未实现（相对稿子）。 |
| 7 | **品牌主色是否进界面**：稿子 `app-icon-directions.html` 色板段让 `#ED8725` 同时用于 App 图标与界面方向标识；`DESIGN.md` §1 主动否决（与警示色 `.orange` 撞车）。 | 跟了 `DESIGN.md`（`DesignTokens.swift:21` 注释「界面里不要用它」）。判定：一致（相对 `DESIGN.md`）。 |

---

## 9. 实现超出稿子（稿子标为「可选」或完全未提，而实现做了）

| # | 实现内容 | file:line | 稿子对应 |
|---|---|---|---|
| 1 | `svg` 并入 `photo` | `FileTypeIcon.swift:50` | §1.2 / §5 A 图片位图与 RAW 列表**均未列 `svg`** |
| 2 | `wma` 并入 `waveform` | `FileTypeIcon.swift:53` | §1.2 / §5 A 音频列表未列 `wma`（DESIGN.md §3.3 有） |
| 3 | `log` 并入 `doc.text` | `FileTypeIcon.swift:56` | §1.2 / §5 A 未列 `log`（DESIGN.md §3.3 有） |
| 4 | `bz2` `xz` 并入 `doc.zipper` | `FileTypeIcon.swift:57` | §1.2 / §5 A 压缩包列表未列（DESIGN.md §3.3 有） |
| 5 | `tsx` 并入代码符号 | `FileTypeIcon.swift:62` | §1.2 / §5 A 代码列表未列 `tsx`（DESIGN.md §3.3 有） |
| 6 | 「三星」「华为 / 荣耀」两个品牌家族 | `AndroidDevice.swift:76-77, 85-86, 95-96, 109-112` | §3.3 品牌变体表只有 小米 / OPPO / vivo / 弹窗不再出现 |
| 7 | 无线重新激活引导卡片（`wifi.slash` + 插图版） | `MainView.swift:598-617`；`DeviceGuideCard.swift:73-89` | 稿子 §3 只覆盖「USB 未授权」一种；`DESIGN.md` §5.3 才含第三类 |
| 8 | 额外空态：`打不开这个位置`、`读不到这个相簿`、`正在载入照片…`、`找不到 sidecar`、`app 包内缺少 adb` | `PaneEmptyState.swift:63-70`；`PhotoSourceView.swift:218-231`；`MainView.swift:548-559` | 稿子 §4 只给四类空态 |
| 9 | 照片未授权 `promptView`（`photo.on.rectangle.angled` + 「授权访问」） | `PhotoSourceView.swift:195-205` | 稿子 §4 只给「权限被拒」，未给「尚未授权」 |
| 10 | 「连接不上？」排查清单以 popover 承载（4 条 `usbTroubleshooting`） | `PaneEmptyState.swift:136-142, 148-171`；`MainView.swift:629-640` | 稿子 §4 空态 1 只有文字链「连接不上？」，未规定 popover 与清单内容 |
| 11 | `PhotoSourceView.promptView` 次级按钮「先用 Finder 位置」 | `PhotoSourceView.swift:202` | 稿子未给该空态，故无基线 |

---

## 10. 汇总计数

| 主题 | 一致 | 偏离 | 未实现 | 小计 |
|---|---|---|---|---|
| ① 文件类型符号映射 | 17 | 1 | 0 | 18 |
| ② 四类空态 | 15 | 2 | 2 | 19 |
| ③ USB 引导卡片 | 9 | 3 | 3 | 15 |
| ④ 品牌变体文案 | 0 | 4 | 2 | 6 |
| ⑤ 颜色 / 尺寸令牌 | 4 | 2 | 2 | 8 |
| ⑥ App 图标几何 | 8 | 3 | 0 | 11 |
| **合计** | **53** | **16** | **9** | **78** |

**偏离 16 条中，`1010_01` / `DESIGN.md` 已明示的「有意偏离」6 条（② 空态 2 文字链、③ 品牌检测方式、⑤ 选中行填充、⑤ 焦点环、⑥ 16pt 几何、⑥ 投影剖面）；其余 10 条属可修的实质差异。**

**未实现 9 条**（② 空态 2 色、② 空态 4 按钮自适应、③ 卡片头图标、③ 默认品牌文案、③ 主按钮高度、④ 默认品牌文案、④「弹窗不再出现」、⑤ 选中行白字、⑤ 48pt 空态图标）。

---

## 11. 对「有意偏离」的执行核对（`1010_01` §9 三处）

| 记录项 | 记录的说法 | 实测实现 | 是否按记录执行 |
|---|---|---|---|
| 16pt 档几何 | 「反向操作：间隙**拉大**到 1.1px 以上、栏加宽、箭头换实心三角」 | `make-icon.py:83-87` `SMALL_PANELS` 栏更宽、`SMALL_ARROW_TRIANGLE` 实心三角；注释 `:73-82` 记明反向理由 | ✅ 是 |
| 投影剖面 | 「**正态 CDF**（`Φ(z)`），不是高斯本身」 | `make-icon.py:235` `SHADOW_ALPHA * 0.5 * (1.0 + math.erf(z / √2))`，即正态 CDF | ✅ 是 |
| 降采样 | 「**自研 2×2 面积平均**（预乘空间，逐级折半）」 | `make-icon.py:360-396` `downsample_half`，预乘 alpha 加权平均；`:404-408` 逐级折半；`:414-416` 16pt 档原生渲染 | ✅ 是 |
| 品牌橙不上界面 | `DESIGN.md` §1 主动否决 | `DesignTokens.swift:21` `brandPrimary` 注释「界面里不要用它」；界面无引用 | ✅ 是 |

---

## 12. 方法（可复核）

| 手段 | 位置 |
|---|---|
| 稿件逐节精读 | `docs/design/2026-10-10-ui-icons/icon-system.html`（§1.2 / §3.2-3.3 / §4 / §4.1 / §5 A-C）、`app-icon-directions.html`（规范 / 母版 / verdict / 色板） |
| 实现逐文件通读 | `Support/FileTypeIcon.swift`、`Views/EntryIconView.swift`、`Views/DeviceGuideCard.swift`、`Views/PaneEmptyState.swift`、`Views/MainView.swift`、`Views/PhotoSourceView.swift`、`ADB/AndroidDevice.swift`、`Support/DesignTokens.swift`、`Views/EntryTable.swift`、`Views/EntryGrid.swift`、`Views/PreviewPane.swift`、`scripts/make-icon.py` |
| 分支依据核对 | `Support/BrowserEntry.swift:4-8`（`Origin.local/.remote/.photo`）、`Views/EntryIconView.swift:26`（唯一分支） |
| 符号匹配路径核对 | `Support/ByteFormat.swift:62` `pathExtensionLowercased`、`ADB/MediaScanner.swift:134-138` |
| 回归守卫 | `scripts/check-icon-mapping.swift`（29 条断言，两栏一致性） |

> 本审计**未改动任何源码**；产出仅本文件。
