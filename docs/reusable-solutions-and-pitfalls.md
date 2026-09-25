# 从验证 demo 到正式产品：可复用方案与避坑清单

> 这份文档的用途：把验证 demo 里**值得带走的东西**和**必须绕开的坑**分离出来，供正式开发直接取用。
>
> 阅读前提：demo 是**探针**，不是产品代码。它为了"可观测"做了很多在产品里不合适的取舍。所以下面所有内容分三档：**直接复用** / **改造后复用** / **不要带过去**。

---

## 〇、一句话结论

**可直接带走的，是"分发流水线 + 自检机制 + 凭据管理"这三块；其余都需要按产品要求重做。**

因为这三块解决的问题（macOS 信任链、状态可观测、凭据可信）在正式产品里**一模一样**，而 demo 里为验证目的做的取舍（无构建链、诊断优先的 UI、SDK adb 直用）都不该进产品。

---

## 一、可直接复用的方案

### 1.1 分发流水线（价值最高的一块）

**三段分工，不要合并：**

| 脚本 | 职责 | 为什么独立 |
|---|---|---|
| `scripts/build.sh` | 构建 + 签名 | 签名失败 = 代码问题，应该立刻失败 |
| `scripts/notarize.sh` | 公证 app → staple → 建并签 DMG → 公证 → staple | 公证依赖网络和外部凭据，不应阻塞本地构建 |
| `scripts/verify-clean.sh` | 挂载 DMG、签名清单、spctl、可选安装 | 验证必须能对**已发布产物**做，而不是对构建目录 |

**关键设计：`build.sh` 在调用构建工具前剥离公证凭据。**

```bash
for v in APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID \
         APPLE_API_KEY APPLE_API_ISSUER APPLE_API_KEY_PATH; do
  unset "$v"
done
```

实测发现：只要这几个环境变量存在，Tauri 就会自动触发公证，**凭据无效时整个构建失败**。而且它的自动公证只处理 `.app`，不碰 DMG，也不 staple。

带进产品的理由：**签名与公证是两个独立关注点。** 一个坏凭据不应该让开发者连本地构建都做不了。

**配套的共享函数（`scripts/env.sh`）：**

```bash
make_signed_dmg() {
  local app="$1" out="$2" identity
  identity="$(detect_identity)"
  rm -f "$out"
  hdiutil create -volname "$APP_NAME" -srcfolder "$app" -ov -format UDZO "$out" >/dev/null
  codesign --force --sign "$identity" --timestamp "$out"
}
```

**所有构建 DMG 的地方都必须调这个函数，不要手写 `hdiutil create`。** 理由见 §2.1。

---

### 1.2 `env.sh`：共享 shell 库

`scripts/env.sh` 里有四个函数值得整体带走：

| 函数 | 作用 | 为什么值得复用 |
|---|---|---|
| `load_env_file()` | 逐行解析 `.env` | **不能 `source`** —— 值里含空格和括号会炸。且环境变量优先于文件 |
| `detect_identity()` | 从钥匙串找可用签名身份，优先 Developer ID | 让脚本不依赖硬编码的身份字符串 |
| `identity_kind()` | 判定 `developer-id` / `apple-development` / `adhoc` | 在构建前就能给出"这个身份能不能公证"的结论 |
| `export_bundle_paths()` | 解析构建产物路径 | 见 §2.4 的路径陷阱 |

**`load_env_file` 的实现要点**（直接可抄）：

```bash
load_env_file() {
  local file="$1" line key value current
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    eval "current=\${$key:-}"
    [ -n "$current" ] && continue        # 环境变量优先
    export "$key=$value"
  done < "$file"
}
```

---

### 1.3 自检机制（第二有价值的一块）

**做法：让 sidecar 能检查它自己所在的 bundle。**

`doctor` 命令输出 14 项检查，每项带：

- `level`：`blocker` / `high` / `medium` / `low`
- `status`：`pass` / `fail` / `manual` / `skip`
- `evidence`：原始证据字符串（不是结论）

两种输出格式：`--table`（人读）和默认（JSON，机器读）。

**为什么这个设计值得进产品：**

1. **把"用户报告问题"变成"用户贴一份报告"。** 签名类问题的排查全靠环境细节，让用户描述是低效的。
2. **`manual` 状态是一等公民。** 有些检查必须人工确认（真实设备、干净机器），把它显式建模出来，比含糊地标 pass 诚实得多。
3. **判据机器可读 → 可以进 CI。** 把 `doctor` 挂在发布流水线的最后一步，`blocker` 项非 pass 就阻断发布。

**产品化时需要的改造**：把 14 项按"终端用户可见"和"仅开发/CI 可见"分层，前者做成设置页里的"诊断"，后者只进日志。

---

### 1.4 Rust sidecar 的工程配置

`sidecar/droidock-adb/Cargo.toml`：

```toml
[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
panic = "abort"
strip = true
```

**成品 432 KB，零第三方依赖（纯 `std`）。**

带进产品的理由不只是体积 —— **依赖越少，签名链上可能出问题的环节越少**。每引入一个 dylib，就多一个需要正确签名、且 TeamID 必须一致的对象。

如果正式产品确实需要第三方 crate，优先选纯 Rust 的（不引入 C 依赖），并在每次加依赖后重跑签名检查。

---

### 1.5 ADB 的解析链与调用封装

**`adb::resolve()` 的六级搜索链**（顺序不要改）：

| 优先级 | 来源 | 用途 |
|---|---|---|
| 1 | 环境变量 `DROIDDOCK_ADB` | 开发/测试时覆盖 |
| 2 | `Contents/MacOS/adb` | 产品内置 |
| 3 | `Contents/Resources/adb` | 内置（备选位置） |
| 4 | `Contents/Resources/binaries/adb` | 内置（备选位置） |
| 5 | `Contents/Resources/platform-tools/adb` | 内置（备选位置） |
| 6 | `PATH` → Android SDK（`ANDROID_HOME` / `ANDROID_SDK_ROOT` / `~/Library/Android/sdk`） | 开发者机器上的回退 |

**返回值带 `probes` 列表** —— 每个尝试过的路径和是否存在。这样"找不到 adb"这个错误能直接告诉用户**找过哪里**，而不是只说"没找到"。

**`proc::run(program, args, timeout: Duration)`** 值得整体带走：

- 超时控制
- **非阻塞地同时抽干 stdout 和 stderr** —— 这是子进程封装的经典坑：如果只读一路，另一路的管道缓冲区写满会导致子进程阻塞，表现为"命令卡死"。
- `run_simple(program, args, timeout_secs)` 是它的简化封装
- `which(name)` 自己实现 PATH 查找

**`adb_port_status()` 的四态判定**值得单独说：

`adb` 客户端会复用任何已经在 5037 端口上的 server。所以"端口被占用"有四种完全不同的含义：

| 状态 | 判定方式 | 处理 |
|---|---|---|
| 空闲 | `lsof` 无结果 | 正常 |
| **是我们自己的 adb** | `lsof -p PID -Fn` 的完整路径 == 我们的 adb 的规范化路径 | 正常 |
| 是**别的** adb | `ps -o comm=` 或路径以 `/adb` 结尾 | 提示用户，版本不一致会静默改变行为 |
| 是非 adb 进程 | 以上都不是 | 报错 |

**关键实现细节**：不能用 `lsof -p PID -a -d txt -Fn` —— 它返回的是 `IOUSBLib` / `dyld` 之类的加载项，不是可执行文件路径。必须用 `lsof -p PID -Fn` 然后过滤以 `n` 开头且是绝对路径的行。

---

### 1.6 无线调试的技术选型

**结论：用 `adb tcpip 5555`，不要依赖 Android 11+ 的"无线调试"。**

| 方案 | 端口行为 | 能否做"记住上次的设备" |
|---|---|---|
| Android 11+ 无线调试 | **随机**（30000–49999），每次开关都变 | 不能 |
| `adb tcpip 5555` | 固定 5555，重启前不变 | **能** |

**产品上必须处理的引导问题**：`tcpip 5555` 需要先用 USB 连接一次来激活。这个"第一次必须插线"的约束必须在 UI 上讲清楚，否则用户会以为无线功能坏了。

实测数据（华为 Android 10，同网段）：

| 项 | 结果 |
|---|---|
| 断开 → 重连 | 3/3 成功 |
| 纯无线（USB 已拔）下息屏 40 秒 | 连接未断，命令仍成功 |
| 延迟 TCP / USB | 41 ms/次 vs 34 ms/次 |

---

### 1.7 凭据管理

**两层：**

1. `.env`（权限 `0600`，且在 `.gitignore` 里）—— 供脚本读取
2. keychain profile（`xcrun notarytool store-credentials`）—— 供公证使用，避免密码出现在命令行

**必须遵守的一条规则：配置凭据的唯一可信成功信号，是拿它真的做一次认证。**

```bash
if xcrun notarytool store-credentials "$PROFILE" ... \
   && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  write_env NOTARY_PROFILE "$PROFILE"
else
  drop_env NOTARY_PROFILE        # 删掉陈旧值，否则继续误导下游
  SKIPPED+=("notarytool credentials")
fi
```

**`notarytool history` 返回 `No submission history.` 是成功**，不是错误 —— 它表示认证通过了，只是这个账号没有历史提交。这一点很容易误判。

---

## 二、必须避开的坑

### 2.1 签名与分发

#### 坑：`hdiutil create` 出来的 DMG 没有任何签名

**症状**：同一个流程产出的两个文件，app 被 `spctl` 接受，DMG 被拒：

```
DroidBerth.dmg: rejected
source=no usable signature
```

但 DMG 的公证**通过了**，`stapler validate` 也**通过了**。

**根因**：三个环节检查的东西完全不同。

| 环节 | 检查什么 | 对"DMG 无签名"的反应 |
|---|---|---|
| `notarytool submit` | 提交**内容**（app 的签名链） | 通过 —— 不关心外层 DMG |
| `stapler staple/validate` | **ticket** 是否贴上/可验证 | 通过 —— ticket 与签名是两回事 |
| `spctl --assess` | 该文件**自身**的签名 | **拒绝** |

**正确顺序：create → sign → notarize → staple。**

**防线**：
- 统一用 `make_signed_dmg()`，禁止在脚本里手写 `hdiutil create`
- 验证时对 **app 和 DMG 都**跑 `spctl` 和 `stapler validate`
- 加一条断言：`codesign -dv <dmg>` 不得报 `code object is not signed at all`

---

#### 坑：用开发证书验证签名，结论不能外推

**症状**：用 Apple Development 证书做受控实验（同一二进制、唯一变量是 `--timestamp`），得出"不传参数就没有时间戳"。

**错在哪**：`codesign` 在不给 `--timestamp` / `--timestamp=none` 时走"系统默认行为"，而**该默认依赖证书类型**：

| 证书 | 不传参数时的默认 |
|---|---|
| Apple Development | **不加**时间戳 |
| Developer ID | **自动加** |

同一个"不传参数"的形状，两种证书下结果相反。

**防线**：
- **签名相关的验证必须用发布证书做。** 用开发证书验证会得到假阴性，然后围绕不存在的问题写一堆 workaround
- 看到"默认行为"，先问它依赖什么

---

#### 坑：逐层签名的顺序与一致性

**必须满足：**

- 每个嵌套可执行文件都有 `flags=0x10000(runtime)`
- 每个嵌套可执行文件都有 `Timestamp=`
- **所有嵌套二进制的 TeamID 与外层一致** —— 一个外来签名会让整个 bundle 被拒
- 签名顺序：最深层 → 外层（sidecar → 嵌套 dylib/framework → 主二进制 → app）

**检查命令**：

```bash
# 列出 bundle 内所有 Mach-O 及其签名
find "$APP" -type f -print0 | xargs -0 file | grep 'Mach-O' | cut -d: -f1 | while read -r f; do
  printf '%s\n' "${f#"$APP"/}"
  codesign -dvvv "$f" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)'
done
```

---

#### 坑：把公证从构建里剥离后，别忘了产物目录里有两个 DMG

构建工具自己产出的 DMG（`AppName_0.1.0_aarch64.dmg`）**只签名、不公证**。公证脚本产出的那个才是可分发的。

**防线**：产品化时统一产物命名，或让构建只出 `app` target，DMG 一律由公证脚本产出。

---

### 2.2 shell 脚本（macOS 自带 bash 3.2）

macOS 的 `/bin/bash` 是 **3.2**（GPLv2 的最后一个版本）。以下写法会挂：

| 不能用 | 替代 |
|---|---|
| `mapfile` / `readarray` | `while IFS= read -r` 循环 |
| `set -u` 下展开空数组 `"${ARR[@]}"` | 先判 `[ "${#ARR[@]}" -gt 0 ]` |
| `declare -A`（关联数组） | 用普通变量或 `awk` |

**另一个坑：路径排序时不要用空格做分隔符。**

```bash
# 错：路径含空格会被切坏
awk '{ n=gsub(/\//,"/"); print n " " $0 }' | sort -rn | cut -d' ' -f2-

# 对：用 tab
awk '{ n=gsub(/\//,"/"); print n "\t" $0 }' | sort -rn | cut -f2-
```

**还有：`.env` 不能 `source`。** 值里含空格和括号会直接报错或产生错误结果。用 §1.2 的逐行解析。

---

### 2.3 工具输出解析

#### 坑：`otool -L` 对 universal 二进制按架构各打一次头部

```
vendor/platform-tools/adb (architecture x86_64):
	/usr/lib/libSystem.B.dylib ...
vendor/platform-tools/adb (architecture arm64):      ← 第二个头部
	/usr/lib/libSystem.B.dylib ...
```

`tail -n +2` 只跳过第一个，第二个会被当成依赖项。

**正确做法**：只接受以 **tab 或空格**开头的行，并去重。

```bash
otool -L "$BIN" | grep -E '^[[:space:]]' | awk '{print $1}' | sort -u
```

**这个坑在同一个项目里出现了两次** —— 一次在 Rust 解析器、一次在 shell 脚本。因为两边用了同一个错误假设："第一行是文件名，跳过它就行"。

**一般化的教训：从一次观测归纳格式契约，是这类 bug 的共同来源。** 样例恰好只有一个架构时，代码看起来是对的。

---

#### 坑：`spctl` 的拒绝理由要看 `source=`

`spctl --assess` 的 `rejected` 有三种完全不同的原因，必须加 `-vvv` 看 `source=`：

| `source=` | 含义 |
|---|---|
| `no usable signature` | 文件根本没签名（或签名无效） |
| `Unnotarized Developer ID` | 签名合法，但没公证 —— **这是公证前的正确状态** |
| 其它 | 证书类型/信任链问题 |

**只看 `rejected` 会把三种问题混为一谈。** 同一项检查在三个阶段会给出三种不同的 `rejected`，读结论时必须区分。

---

### 2.4 构建与工具链

#### 坑：`tauri build --target <triple>` 的产物路径

产物在 **`src-tauri/target/<triple>/release/bundle/`**，不是 `target/release/bundle/`。

**防线**：写一个 `detect_bundle_dir()`，显式传 triple 时直接采用、不检查存在性（因为构建前也要能算出路径）。

---

#### 坑：`hdiutil` 的临时镜像自毒化

构建工具生成的打包脚本里有 `DMG_TEMP_NAME="$DMG_DIR/rw.$$.${DMG_NAME}"`，而 `DMG_DIR` **就是被镜像的源目录**。于是：

**失败一次 → 在源目录留下一个 33 MB 的 `rw.*.dmg` → 下次把这些垃圾也打进镜像 → 又失败。**

症状是 `hdiutil` 报"设备上无剩余空间"，而 `df` 显示还有 124 GB 空闲。

**防线**：构建前清理源目录里的 `rw.*.dmg` 和误落的 `*.dmg`。**并且不要相信 `hdiutil` 的 ENOSPC，先看源目录里有什么。**

---

#### 坑：从 AOSP 构建 adb 没有 CMake 路径

AOSP 的 `platform_system_core` 使用 **Soong（`Android.bp`）**，上游**不存在任何 `CMakeLists.txt`**。网上流传的 `cmake ..` 构建方式在这份源码上不成立。

**如果确实需要自己构建 adb**：要么用 Soong（需要完整 AOSP 环境），要么找社区维护的独立构建方案（注意其对当前 adb 版本的支持情况）。

**一般化的教训：上游的命令要自己核实。** 一条抄来的命令，成本是半小时排错；如果它"看起来跑起来了"，成本可能是几天的错误方向。

---

#### 坑：把"不是静态链接"当成"依赖有问题"

SDK 里预编译的 adb **不是静态链接的**，但它的依赖**全部是系统库**：

```
/usr/lib/libSystem.B.dylib
/usr/lib/libobjc.A.dylib
/System/Library/Frameworks/CoreFoundation.framework/...
/System/Library/Frameworks/IOKit.framework/...
/System/Library/Frameworks/Security.framework/...
```

**非系统路径依赖：0 个。** 这完全满足公证要求。

**动态链接到系统库不构成公证障碍** —— 系统库由 OS 提供，既不需要打包也不需要签名。真正需要处理的是**非系统路径**的 dylib。

**"不是 X" 不等于 "是 Y"。**

---

### 2.5 设备与运行时

#### 现象：App Translocation 会让运行路径变掉

已公证、已 staple 的 app，在带 `com.apple.quarantine` 属性时启动，运行路径会被随机化到：

```
/private/var/folders/.../AppTranslocation/<uuid>/d/AppName.app/...
```

受控实验（同一二进制、同一证书，唯一变量是 quarantine 属性）：

| 条件 | 运行路径 |
|---|---|
| 无 quarantine | 原地运行 |
| 有 quarantine | 被随机化 |

**推断**：触发的是 quarantine 标志，而非公证状态。

**对产品的影响**：translocation 的副本是**只读**的。会破坏两类实现：

- 往 bundle 内写文件（配置、缓存、日志）
- 依赖 bundle 的**绝对路径**去定位资源或兄弟进程

**防线**：
- 所有可写数据放到 `$HOME/Library/Application Support/<app>/`，不要放 bundle 内
- sidecar 定位用**相对自身可执行文件**的路径，不要用安装路径拼接
- 如果产品需要访问 bundle 外的资源，测试时**必须带 quarantine 属性跑一遍**

**顺带一个操作细节**：bundle 首次启动后会带上受保护的 `com.apple.provenance`，导致其 xattr 不可修改。`xattr -c`（清全部）会因为连它一起清而失败；**删单个属性必须用 `xattr -d`，且必须在首次启动之前。**

---

#### 坑：5037 端口的四种占用状态

见 §1.5 的表格。**产品化时必须处理**：如果用户机器上已经有一个不同版本的 adb server 在跑，我们的 app 会静默地复用它，行为可能与预期不符。至少要检测并提示。

---

## 三、不要带进产品的部分

| 项 | 原因 |
|---|---|
| `scripts/use-sdk-adb.sh` + `vendor/platform-tools/` | **许可风险。** SDK 的条款限制再分发；虽然 `platform-tools` 的 NOTICE 声明整体为 Apache-2.0 且对开源组件有豁免，但正式分发前应让法务确认。**这不是法律意见。** |
| `scripts/build-adb.sh` | 它是**可行性探针**，不是构建脚本。产品若需自建 adb，要另写正式的构建流水线 |
| `src/` 的前端 | 无构建链（`withGlobalTauri` + 纯 HTML/JS），只为验证时改代码即时生效。产品需要正常的构建链 |
| 诊断优先的 UI 结构 | demo 的四个 tab 是围绕"观测"设计的，不是围绕用户任务 |
| `scripts/resign.sh` | 它的理由是"补 `--timestamp`"，而 Developer ID 证书下构建工具自己就加。只剩换 entitlements 做实验这一个用途 |
| 预置的 `src-tauri/binaries/adb-*` | 同上，许可问题；且它们是 18 MB 的 universal 二进制 |

---

## 四、正式开发前还需要补的验证

| # | 项 | 为什么 demo 没做 |
|---|---|---|
| 1 | 干净的 macOS 15+ 虚拟机复验 | 开发机已运行过该 app，Gatekeeper 结论不具决定性 |
| 2 | Universal 构建（arm64 + x86_64） | demo 只验了 arm64 |
| 3 | 设备矩阵 | 只测了一台华为 Android 10；未覆盖小米/OPPO/三星与 Android 11+ |
| 4 | 长时间 Doze | 只测了息屏 40 秒，没测几小时 |
| 5 | 切换 WiFi 网络后重连 | 需人工切网 |
| 6 | 手机重启后端口状态 | 已知限制：端口失效，需重新 USB 激活。产品必须提供引导 |
| 7 | 多设备并发 | demo 只连了一台 |
| 8 | 5037 冲突的产品化处理 | demo 只做了检测，没做处理策略 |
| 9 | 许可合规确认 | 需要法务意见 |

---

## 五、落地检查清单

### 构建阶段

- [ ] 嵌套二进制的签名隔离：sidecar **故意不预签名**，让构建工具的签名行为成为唯一变量
- [ ] 每个 Mach-O 检查 `flags=0x10000(runtime)`
- [ ] 每个 Mach-O 检查 `Timestamp=` 存在（**用发布证书验证**）
- [ ] 所有嵌套二进制的 TeamID 与外层一致
- [ ] entitlements 按预期传播到每个签名目标
- [ ] 构建产物路径用 `detect_bundle_dir()` 解析，不硬编码

### 打包阶段

- [ ] **DMG 自己也要签名** —— `hdiutil create` 不产生签名
- [ ] 顺序正确：create → sign → notarize → staple
- [ ] `codesign -dv <dmg>` 不报 `code object is not signed at all`
- [ ] 构建前清理源目录里的 `rw.*.dmg`

### 验证阶段

- [ ] `spctl --assess -t open --context context:primary-signature` 对 **app 和 DMG 都**跑
- [ ] `xcrun stapler validate` 对 **app 和 DMG 都**跑
- [ ] 用 `spctl -vvv` 看 `source=` 区分三种 `rejected`
- [ ] 在 `/Applications` 里、带 `com.apple.quarantine` 属性测一次
- [ ] 在**从未运行过该 app** 的机器上测一次

### 凭据与 CI

- [ ] `.env` 权限 `0600` 且在 `.gitignore` 里
- [ ] 提交前扫描密钥是否泄漏到其它文件
- [ ] 凭据配置成功后，用 `notarytool history` 真的认证一次再记录
- [ ] `build.sh` 剥离公证凭据
- [ ] `doctor` 的 `blocker` 项挂进 CI，非 pass 阻断发布

### 代码约定

- [ ] 可写数据放 `$HOME/Library/Application Support/`，不放 bundle 内
- [ ] sidecar 定位用相对自身可执行文件的路径
- [ ] 子进程封装要**同时**抽干 stdout 和 stderr，并带超时
- [ ] 外部工具输出解析前，先确认它的**格式契约**（尤其对多架构/多条目输出）
- [ ] shell 脚本遵守 bash 3.2 限制

### 排查习惯

- [ ] 用 `codesign -dvvv` 读真实字节，不靠推理
- [ ] 修一个形状时，**数一遍它在仓库里出现几次**
- [ ] 任何"默认行为"，先问它依赖什么
- [ ] 转述的状态要去核实（"设备已断开"可能只是 USB 断了，无线还在）
