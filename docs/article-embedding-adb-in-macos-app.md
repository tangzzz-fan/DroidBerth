# 把 ADB 装进 macOS app

## 一次 Rust sidecar + 无线调试的技术验证

---

## 摘要

我们想做一个 macOS 应用，让用户插上 Android 手机就能用，**不需要自己装 ADB**。做法是把 ADB 二进制作为 sidecar 打进 app bundle。

在 macOS 上，这件事的难点不在功能，而在**分发**：一个 app 由多个可执行文件组成，而 macOS 的信任体系要求每一个都被正确签名。任何一个环节缺失，整条信任链断裂 —— 而且失败往往是**静默的**。

这篇文章记录这次验证中实际踩到的坑、排查过程和解决方案，最后归纳出问题的本质。

验证项目的名字是 **DroidBerth**，核心是一个自检命令 `doctor`：它检查自己所在的 bundle，输出 14 项结构化结论。所有判断都基于它的输出，不靠人工记忆。

---

## 一、要解决什么问题

### 1.1 为什么要内嵌 ADB

目标用户是普通 Mac 用户，他们手上有 Android 手机，但：

- 不会装 Android SDK，也不知道 `platform-tools` 是什么
- 就算装了，`adb` 也可能不在 `PATH` 里
- 就算在 `PATH` 里，版本可能和 app 期望的不一致

所以"让用户自己装 ADB"会直接毁掉产品的核心卖点。唯一的选择是**把 ADB 打进 app**。

### 1.2 为什么这在 macOS 上比在 Linux/Windows 上难得多

Linux 上，把二进制放进 app 目录就完事了。Windows 上，最多签个名。

macOS 上，你要同时满足：

| 要求 | 说明 |
|---|---|
| 每个可执行文件都要签名 | 不只是外层 app |
| 签名要带 hardened runtime | `--options=runtime` |
| hardened runtime 的签名要带安全时间戳 | 否则新版系统拒绝 |
| 所有嵌套二进制的 TeamID 要一致 | 一个外来签名会让整个 bundle 被拒 |
| 签名要覆盖每一个嵌套层级 | 顺序错了签名链就断 |
| 最后还要通过公证和 Gatekeeper | 这是另一套检查 |

**而这几件事的失败模式不是"报错"，是"静默地不生效"。** 这是整篇文章的核心线索。

### 1.3 本质问题（先说结论）

验证做完之后回头看，真正的难点可以归纳成三句话：

1. **macOS 的信任链是多层的，而各层独立校验、互不覆盖。** "公证通过"推不出"Gatekeeper 接受"。
2. **很多行为是"上下文依赖的默认值"。** 默认值依赖什么，必须问清楚；在一种条件下测出的结论，不能外推到另一种条件。
3. **中间环节返回成功，不等于目标达成。** 成功信号必须是端到端的。

后面每一个坑，都是这三条的具体表现。

---

## 二、技术方案与设计

### 2.1 结构

```
DroidBerth.app
└── Contents/
    ├── MacOS/
    │   ├── droidberth          ← Tauri 主二进制
    │   └── droidberth-adb      ← Rust sidecar（内含或调用 ADB）
    ├── Resources/
    └── Info.plist
```

Tauri v2 的 `externalBin` 机制负责把 sidecar 放进 `Contents/MacOS/`：

```json
{
  "bundle": {
    "externalBin": ["binaries/droidberth-adb"],
    "macOS": {
      "hardenedRuntime": true,
      "entitlements": "entitlements.plist"
    }
  }
}
```

### 2.2 sidecar 为什么用 Rust

- **零依赖**：只用 `std`，没有第三方 crate。产物是一个独立的 Mach-O，不引入额外的 dylib，也就不引入额外的签名对象。
- **体积**：`opt-level="z"` + `lto` + `panic="abort"` + `strip`，成品 432 KB。
- **可控的失败面**：依赖越少，签名链上可能出问题的环节越少。

### 2.3 把"自检"做进 sidecar

这是整个验证里最有价值的一个设计决定。

sidecar 带一个 `doctor` 子命令。它检查**自己所在的 bundle**：逐个二进制读签名、解析 Mach-O 依赖、检查嵌套签名一致性、评估 Gatekeeper 结论，输出 14 项结构化结果：

```
  #   LEVEL    STATUS  CHECK
  1   blocker  PASS    Gatekeeper accepts the signed bundle
                        accepted source=Notarized Developer ID
  2   blocker  PASS    Sidecar signature carries hardened runtime
                        flags=0x10000 names=[runtime]
  3   high     PASS    Sidecar signature carries a secure timestamp
                        Timestamp=Sep 26, 2026 at 05:49:40
  ...
  verdict   FAIL   (9 pass / 1 fail / 3 manual / 1 skip of 14)
```

每项带**级别**（blocker / high / medium / low）、**状态**（pass / fail / manual / skip）和**证据**。

这个设计的价值在后面会反复体现：**当排查陷入猜测时，"把当前状态打印出来"永远比"我觉得应该是这样"有效。** 而且它可以反复重跑、逐项对照 —— 改一个变量，看哪几项翻转。

### 2.4 一个刻意的设计：sidecar 不预签名

构建脚本把 Rust 产物复制到 `src-tauri/binaries/`，然后**不做任何签名**。

这样做的目的是：bundle 里那个 sidecar 的签名**只能**来自 Tauri 的签名步骤。任何"签名参数对不对"的问题，都只可能出在一个地方。

**把变量隔离出来，是排查一切签名问题的前提。**

---

## 三、坑一：时间戳 —— 一个"设计上无缺陷"的实验，得出了错误结论

### 3.1 现象

构建完成后检查 sidecar 签名，发现**没有** `Timestamp=` 字段：

```
$ codesign -dvvv DroidBerth.app/Contents/MacOS/droidberth-adb
CodeDirectory v=20500 size=1208 flags=0x10000(runtime) hashes=27+7 location=embedded
Authority=Apple Development: ...
TeamIdentifier=7H6TJ2PN25
                                          ← 没有 Timestamp=
```

hardened runtime 有（`0x10000`），但安全时间戳没有。而新版 macOS 会拒绝"带 hardened runtime 但没有安全时间戳"的签名。

### 3.2 一次看起来无懈可击的实验

为了确定原因，做了受控实验：**同一份二进制、同一张证书，唯一变量是那个参数。**

| 调用形状 | Timestamp |
|---|---|
| `codesign --force -s <id> --options runtime` | **无** |
| `codesign --force -s <id> --options runtime --timestamp` | 有 |

结论似乎很清楚：**时间戳的有无取决于是否显式传 `--timestamp`，与证书类型无关。**

这个实验在设计上没有问题 —— 单一变量、对照清晰、可复现。

### 3.3 结论是错的

后来拿到发布证书（Developer ID），重做同一个实验：

| 调用形状 | Timestamp |
|---|---|
| `codesign --force -s <id> --options runtime`（不传参数） | **有** |
| `codesign --force -s <id> --options runtime --timestamp` | 有 |
| `codesign --force -s <id> --options runtime --timestamp=none` | **无** |

**同一个"不传参数"的形状，在开发证书下没有时间戳，在发布证书下有。**

### 3.4 根因：默认行为是上下文依赖的

回头去读手册：

```
$ man codesign
...
--timestamp=none
    ...
    If neither --timestamp nor --timestamp=none is specified,
    a system-specific default behavior is invoked. It may result in
    some but not all code signatures being timestamped.
```

"系统默认行为"、"some but not all" —— 它其实写清楚了：**默认行为依赖上下文**。而这里的上下文就是证书类型：

- 开发证书（Apple Development）→ 默认**不**加时间戳
- 发布证书（Developer ID）→ 默认**加**

### 3.5 怎么解决

**不需要解决 —— 这个"问题"根本不存在。**

用发布证书构建时，`codesign` 会自动给每一个二进制加时间戳，包括 sidecar。实测干净构建后三个二进制全部带 `Timestamp=`。

**但如果当时没拿到发布证书就交付结论**，会得出"必须手动补 `--timestamp`，否则公证会挂"，然后围绕一个不存在的问题写一堆 workaround —— 而那些 workaround 自己会引入新的签名风险。

### 3.6 教训

**受控实验的结论，不能外推到它没有覆盖的条件上。**

做实验时先问一句：**"我改变的那个变量，是不是恰好也是决定默认行为的那一个？"**

如果是，那么"不设这个变量"这一支的结果，就不能从另一种条件下的实验外推。我的第一个实验恰恰只覆盖了"默认不加"那一支。

---

## 四、坑二：DMG 没签名 —— "公证通过"不等于"Gatekeeper 接受"

### 4.1 现象：同一个流程出来的两个产物，一个通过一个被拒

```
$ spctl --assess -t open --context context:primary-signature DroidBerth.app
（无输出，退出码 0）              # 通过

$ spctl --assess -t open --context context:primary-signature DroidBerth.dmg
DroidBerth.dmg: rejected
source=no usable signature        # 退出码 3
```

而诡异的是，这个 DMG 的**公证通过了**，`stapler` 也**通过了**：

```
$ xcrun stapler validate DroidBerth.dmg
The validate action worked!
```

### 4.2 排查

第一个反应是怀疑 DMG 内容有问题。但检查签名本身：

```
$ codesign -dv DroidBerth.dmg
DroidBerth.dmg: code object is not signed at all
```

**DMG 根本没有签名。**

再对比构建工具自己产出的那个 DMG：

```
$ codesign -dv DroidBerth_0.1.0_aarch64.dmg
Authority=Developer ID Application: ...
Timestamp=Sep 26, 2026 at 05:50:02
```

构建工具是签的。问题出在我们的公证脚本 —— 它**重建**了一个 DMG 把原来的替换掉了，用的是裸的 `hdiutil create`，**从头到尾没有一次 `codesign`**。

### 4.3 为什么"公证通过 + staple 通过"还会被拒

这是这个坑最有价值的部分。三个环节各自检查的东西**完全不同**：

| 环节 | 检查什么 | 结果 |
|---|---|---|
| `notarytool submit` | 提交的**内容**（app 的签名链） | 通过 —— 它不关心外层 DMG 有没有签名 |
| `stapler staple` / `validate` | **ticket** 是否已贴上/可验证 | 通过 —— ticket 和签名是两回事 |
| `spctl --assess` | 该文件**自身**是否有可用签名 | **拒绝** |

于是产出了一个**"有 stapled ticket 但没有签名"的 DMG**：公证服务器收下了，ticket 也贴上了，但 Gatekeeper 一看没有可用签名就拒。

**正确顺序是 create → sign → notarize → staple。脚本漏了 sign。**

### 4.4 怎么解决

在公证前给 DMG 补上签名。更重要的是一并检查了**这个形状在仓库里出现过几次** —— 结果是 **2 次**（公证脚本和手动重签名脚本各一次，后者用同样的裸 `hdiutil create`）。

于是抽成共享函数，两处统一调用：

```bash
make_signed_dmg() {
  local app="$1" out="$2" identity
  identity="$(detect_identity)"
  rm -f "$out"
  hdiutil create -volname "$APP_NAME" -srcfolder "$app" -ov -format UDZO "$out" >/dev/null
  codesign --force --sign "$identity" --timestamp "$out"
}
```

修完重跑：

| 产物 | spctl 判定 |
|---|---|
| `DroidBerth.app` | `accepted source=Notarized Developer ID` |
| `DroidBerth.dmg` | `accepted source=Notarized Developer ID` |

### 4.5 教训

**修一个形状的时候，先数一遍它在仓库里出现几次。** 只修被踩到的那一处，等于留了一颗定时炸弹 —— 而且因为"刚修过"，下次更不容易被怀疑。

---

## 五、坑三：凭据配置的"假成功"

### 5.1 现象

我们写了一个交互式向导，引导开发者完成证书申请和公证凭据配置。用户跑完之后说"向导我已经完成了"。

核实一下：**证书那半是真的，凭据那半是假的。**

两个独立证据：

1. 钥匙串里根本没有那个 profile —— 配置命令从没成功过。
2. 配置文件里的密码是 **6 位纯数字**。合法的 app-specific password 形状是 `abcd-efgh-ijkl-mnop`（19 字符带 3 个连字符）。6 位数字不是任何一种合法凭据。

### 5.2 根因：把"记录一个意图"当成"记录一个结果"

看向导的代码：

```bash
if xcrun notarytool store-credentials "$PROFILE" ... ; then
  printf '  ✓ stored ...'
else
  warn "store-credentials failed"          # 只警告
fi
write_env NOTARY_PROFILE "$PROFILE"        # 但无论成败都写入
```

配置命令失败时它只打个警告，然后**照样**把 profile 名写进配置文件。于是后续的公证脚本看到这个变量非空，走 keychain 分支，最后报一个和真实原因无关的错。向导的收尾函数也**无条件**打印 `✓ Setup complete`。

**这个形状最危险的地方在于：它恰好让用户看到成功。** 用户据此判断"完成了"，而系统状态是坏的，且坏得很有迷惑性 —— 下一个环节会报错，但报的是别的原因。

### 5.3 怎么解决

只在配置命令成功**且**用该凭据真的做一次认证通过之后，才写入 profile 名；失败则把陈旧值**删掉**（否则残留的旧值继续误导下游），并计入"待办"清单，让收尾摘要列出来。

### 5.4 教训

**任何"配置某个外部凭据"的自动化，唯一可信的成功信号是拿这个凭据真的做一次认证。**

配置命令返回 0 不等于凭据可用 —— 它只表示"我把它存起来了"。

---

## 六、坑四：`otool -L` 在 universal 二进制上的解析陷阱

### 6.1 现象

写了个脚本，检查 ADB 是否只依赖系统库：

```bash
$ otool -L adb | tail -n +2 | awk '{print $1}' | grep -v '^/usr/lib/'
vendor/platform-tools/adb          ← 依赖里多出了"自己"
```

`adb` 依赖了 `adb` 自己？显然是解析错了。

### 6.2 根因

`otool -L` 对 **universal 二进制会按架构各打印一次头部行**：

```
vendor/platform-tools/adb (architecture x86_64):
	/usr/lib/libSystem.B.dylib ...
	...
vendor/platform-tools/adb (architecture arm64):      ← 第二个头部
	/usr/lib/libSystem.B.dylib ...
	...
```

`tail -n +2` 只跳过了第一个头部，第二个被当成了依赖项。

正确做法是**只接受以 tab 或空格开头的行**，并去重。

### 6.3 踩了两次

这个坑在同一个项目里出现了**两次** —— 一次在 Rust 写的解析器里，一次在 shell 脚本里。

因为脚本是照着 Rust 的逻辑重写的，而两边用了同样的错误假设："第一行是文件名，跳过它就行"。

### 6.4 教训

**解析工具输出时，要理解它的输出格式契约，而不是只看一次样例。**

样例恰好只有一个架构时，`tail -n +2` 是对的。**从一次观测归纳格式契约，是这类 bug 的共同来源。**

顺带：这也是"同一个形状在仓库里出现几次"的另一个例子 —— 但这次形状是**错误假设**，不是代码。

---

## 七、坑五：从 AOSP 构建 ADB —— 一条不存在的构建路径

### 7.1 现象

为了得到"静态链接、可自由分发"的 ADB，尝试从 AOSP 源码构建：

```bash
$ git clone https://github.com/aosp-mirror/platform_system_core.git
$ cd platform_system_core/adb
$ mkdir build && cd build
$ cmake .. -DCMAKE_BUILD_TYPE=Release
CMake Error: The source directory ... does not appear to contain CMakeLists.txt.
```

### 7.2 根因

用 `find` 全仓检索确认：**AOSP 的 `platform_system_core` 使用 Soong（`Android.bp`），上游不存在任何 `CMakeLists.txt`。**

那条 `cmake` 命令是照着某个来源抄的，没有先核实上游到底有没有那个文件。

### 7.3 怎么解决

把那个脚本从"构建脚本"改写成**可行性探针**：检查前置条件、报告缺什么、给出判定，而不是盲目执行一条未经验证的命令。

这也更符合它的实际角色 —— 验证阶段需要的是"这条路通不通"，不是"我要把它跑通"。

### 7.4 教训

**上游的命令要自己核实。** 一条抄来的命令，成本是半小时的排错；而如果它"看起来跑起来了"，成本可能是几天的错误方向。

---

## 八、坑六：ADB 的"动态链接"是个伪问题

### 8.1 现象

常见的说法是：Android SDK 里预编译的 ADB "不是静态链接的，依赖若干系统 dylib"，因此"在公证场景下会带来问题"。

### 8.2 实测

```
$ adb version
Android Debug Bridge version 1.0.41
Version 37.0.1-15733141

$ otool -L adb            # 过滤掉架构头部行后
  /usr/lib/libSystem.B.dylib
  /usr/lib/libobjc.A.dylib
  /System/Library/Frameworks/CoreFoundation.framework/.../CoreFoundation
  /System/Library/Frameworks/IOKit.framework/.../IOKit
  /System/Library/Frameworks/Security.framework/.../Security
```

**非系统路径依赖：0 个。**

### 8.3 概念混淆在哪

"不是静态链接"和"有需要处理的依赖"是两件事。

**动态链接到系统库不构成公证障碍** —— 系统库由操作系统提供，既不需要打包进 app，也不需要签名。

真正需要处理的是**非系统路径**的 dylib（比如自己编译的 `libcrypto.dylib`）。而 ADB 一个都没有。

### 8.4 教训

**"不是 X" 不等于 "是 Y"。** 把"非静态"直接等同于"依赖有问题"，跳过了一次本该做的实测 —— 而那次实测只需要一条命令。

---

## 九、adb + WiFi 的实际验证

前面都在讲分发。这一节讲功能本身。

### 9.1 两条技术路线

Android 的无线调试有两条路：

| 方案 | 机制 | 问题 |
|---|---|---|
| Android 11+ 的"无线调试" | 系统分配**随机端口**（30000–49999） | 每次开关都换端口，旧 `ip:port` 永久失效 |
| `adb tcpip 5555` | 把设备上的 adbd 重启为监听**固定端口** | 需要先用 USB 连接一次 |

**结论：App 应该走 `tcpip 5555`**，因为固定端口才可能被记忆和自动重连。随机端口方案没法做"记住上次的设备"。

代价是：用户必须先插一次 USB 来完成初始配置。这是个需要在产品上处理的引导问题。

### 9.2 实测数据

测试设备：HUAWEI DVC-AN20，Android 10（SDK 29）。Mac 与设备同一网段。

| 测试 | 结果 |
|---|---|
| 切到固定端口 | `adb tcpip 5555` → `restarting in TCP mode port: 5555` |
| WiFi 连接 | `adb connect <ip>:5555` → 成功 |
| 双通道并存 | USB 与 WiFi 同时为 `device` |
| **拔掉 USB 后** | 列表中只剩 WiFi 条目；USB 序列号报 `device not found` |
| **纯无线执行命令** | 正常返回设备型号与系统版本 |
| **断开 → 重连（3 次）** | **3/3 全部成功** |
| **纯无线下息屏 40 秒** | 连接未断，命令仍成功 |
| 延迟（TCP / USB） | 41 ms/次 vs 34 ms/次 |

息屏测试特别值得做 —— 因为手机进入低功耗状态时会限制后台网络活动，这是无线调试最常见的断连原因。40 秒不中断说明 adbd 的连接在息屏期间维持得住（但更长时间的 Doze 状态未测）。

TCP 比 USB 慢约 20%，对调试用途完全够用。

### 9.3 未验证的边界

- **手机重启后**：端口会失效，需要重新插 USB 激活。这是已知限制，App 必须提供引导。
- **切换 WiFi 网络**：预期是"IP 变化、端口保持"，未实测。
- **长时间 Doze**：只测了 40 秒，没测几小时。

---

## 十、核心是什么

把这次验证的结论收敛成三条。它们脱离 macOS 也成立。

### 10.1 信任链是多层的，各层独立校验、互不覆盖

macOS 分发的信任链大致是：

```
sidecar 签名 → 主二进制签名 → app bundle 签名 → DMG 签名
                                                    ↓
                          公证（检查内容）→ ticket → staple
                                                    ↓
                                    Gatekeeper（检查文件自身签名）
```

关键认识：**这些检查之间不互相保证。**

- 公证通过，不代表 Gatekeeper 接受（坑二：DMG 没签名照样能公证通过）
- ticket 贴上，不代表文件有签名（同上）
- 每一个嵌套二进制签好，不代表外层 app 签好（反过来也一样）

**推论**：验证必须**逐层、对每个产物**做，不能拿一个环节的成功去推断另一个环节。

### 10.2 默认行为是上下文依赖的，测一种条件不能推另一种

坑一是最典型的例子：`codesign` 不传 `--timestamp` 时走"系统默认"，而默认依赖证书类型。

这类问题的普遍形式是：**你以为在测"有参数 vs 没参数"，实际上"没参数"这一支的含义会随环境变化。**

**推论**：看到"默认行为"四个字，先问它依赖什么。如果依赖的那个东西恰好是你在不同场景下会换的，那你的实验就只覆盖了一半。

### 10.3 中间环节的成功不等于目标达成

坑三最直白：配置命令返回 0，只表示"存下来了"，不表示"能用"。

坑二是同一个道理的另一种形式：公证通过、staple 通过，两个"成功"，最终结果还是被拒。

**推论**：**成功信号必须是端到端的。** 配置完凭据，就用它真的做一次认证；打完包，就用 Gatekeeper 真的评估一次产物。中间环节的返回值只能用来定位问题，不能用来宣布完成。

### 10.4 一条方法论

**把状态做成可观测的，而不是靠推理。**

`doctor` 这个设计在整个过程中反复救场：当排查陷入"我觉得应该是这样"的时候，把当前状态打印出来永远更有效。而且它可重复 —— 改一个变量，看哪几项翻转。

这次验证里，几乎每一个坑的最后一步都是同一种动作：**去读真实的字节**（`codesign -dvvv` 的输出、`otool -L` 的原始文本、`spctl -vvv` 的拒绝理由），而不是继续推理。

---

## 十一、结论与遗留

### 结论

**技术路线可行。** 最关键的证据是一条端到端测试：

把已公证、已 staple 的 app 装进 `/Applications`，人为打上 `com.apple.quarantine` 属性（模拟"从浏览器下载"），然后评估 Gatekeeper：

```
$ xattr -p com.apple.quarantine /Applications/DroidBerth.app
0081;6ab6ef4c;DroidBerth;

$ spctl -vvv --assess -t open --context context:primary-signature /Applications/DroidBerth.app
/Applications/DroidBerth.app: accepted
source=Notarized Developer ID
```

启动后进程正常拉起，系统日志无拒绝记录，**未出现"无法验证开发者"对话框**。

自动检查从最初的 `6 pass / 5 fail` 走到了 **`9 pass / 1 fail / 3 manual / 1 skip`**。

### 遗留

| 项 | 状态 |
|---|---|
| 干净的 macOS 15+ 虚拟机复验 | 未做。开发机已运行过该 app，Gatekeeper 结论不具决定性 |
| Universal 构建（arm64 + x86_64） | 未做，本轮只验 arm64 |
| 设备覆盖 | 只有一台华为 Android 10；未覆盖其他厂商与 Android 11+ |
| 切换 WiFi 网络后重连 | 未验证 |
| 手机重启后端口状态 | 未验证 |

### 一个附带发现：App Translocation

已公证的 app 在带 `com.apple.quarantine` 时启动，运行路径会被随机化到：

```
/private/var/folders/.../AppTranslocation/<uuid>/d/DroidBerth.app/...
```

受控实验（同一二进制、同一证书、同样已公证，唯一变量是 quarantine 属性）：

| 条件 | 运行路径 |
|---|---|
| 无 quarantine | 原地运行 |
| 有 quarantine | 被随机化 |

**推断**：触发的是 quarantine 标志，而非公证状态 —— 已公证的 app 只要带 quarantine 仍会被 translocation。

**对本 app 的影响：无。** translocation 的副本是只读的，会破坏"往 bundle 内写文件"或"依赖 bundle 绝对路径"的应用。逐项核对：sidecar 在副本中齐全且可执行；自检命令从副本路径运行正常；报告写入 `$HOME/` 下的目录，在 bundle 之外；不弹 Gatekeeper 对话框。

---

## 附录：可复用的检查清单

如果你也要把外部二进制嵌进 macOS app，这份清单可以省下上面几个坑：

**构建阶段**

- [ ] sidecar 二进制**故意不预签名**，让构建工具的签名行为成为唯一变量
- [ ] 构建产物中每个 Mach-O 都检查 `flags=0x10000(runtime)`
- [ ] 每个 Mach-O 都检查 `Timestamp=` 存在（用**发布证书**验证，不要用开发证书）
- [ ] 每个嵌套二进制的 TeamID 与外层一致
- [ ] entitlements 是否按预期传播到每个签名目标

**打包阶段**

- [ ] **DMG 自己也要签名** —— `hdiutil create` 不产生签名
- [ ] 顺序正确：create → sign → notarize → staple
- [ ] `codesign -dv <dmg>` 不报 `code object is not signed at all`

**验证阶段**

- [ ] `spctl --assess -t open --context context:primary-signature` 对 **app 和 DMG 都**跑
- [ ] `xcrun stapler validate` 对 **app 和 DMG 都**跑
- [ ] 在 `/Applications` 里、带 `com.apple.quarantine` 属性测一次
- [ ] 在从未运行过该 app 的机器上测一次

**排查阶段**

- [ ] 用 `codesign -dvvv` 读真实字节，不要靠推理
- [ ] 用 `spctl -vvv` 拿拒绝的具体理由（`source=` 后面的值才是关键）
- [ ] 修一个形状时，数一遍它在仓库里出现几次
- [ ] 任何"默认行为"，先问它依赖什么

---

## 附：这次验证留下的东西

| 产物 | 说明 |
|---|---|
| `doctor` 自检命令 | 14 项检查，`pass/fail/manual/skip` + 级别 + 证据，机器可读 |
| 构建脚本 | 构建 + 签名（剥离公证凭据，让构建不因凭据问题失败） |
| 公证脚本 | 公证 app → staple → 构建并**签名** DMG → 公证 → staple |
| 验证脚本 | 挂载 DMG、签名清单、spctl；可安装到 `/Applications` 并模拟下载 |
| 凭据向导 | 8 阶段交互式引导，失败不再被记录成成功 |
