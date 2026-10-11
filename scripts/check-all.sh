#!/bin/bash
# 跑**全部**回归守卫。CI 与本地共用同一个入口 —— 这样「CI 绿了但本地是另一套检查」
# 这种最常见的失配从结构上不会发生。
#
# 守卫各有分工，**都不能省**：
#
# | 守卫 | 守什么 | 为什么编译器不管 |
# | --- | --- | --- |
# | shell 静态检查 | `$VAR` 后面紧跟非 ASCII 字符 | bash 3.2 会把全角标点**算进变量名** ⇒ 运行时才 unbound。本项目脚本全中文，天天会撞 |
# | `check-icon-mapping` | 同一扩展名在两栏（Mac / 设备）得到同一个符号 | 缺陷表现是「**静默分叉**」——两处 switch 各写一遍，`.apk` 在一边变通用文稿，没有任何编译错误 |
# | `check-grid-navigation` | 网格的顺序 / 列数 / 方向键落点 / 字母跳转 | 视图排一次序、键盘再排一次，误差不报错也不崩，只会**让 ↓ 跳到肉眼看不见的地方** |
# | `check-transfer-semantics` | 折叠规则、冲突改名、名称校验、缩略图范围 | 全是纯函数判据；错的方向会让**用户手机上的文件被静默覆盖** |
# | `check-diagnostics-bundle` | 诊断包条目数 / 中文名编码 / 无真实用户名泄露 | 缺陷表现是「**产物打开来才发现**」——曾经产出过一个只有根目录的空包，不报任何错 |
# | `check-local-place-policy` | 沙盒版「固定位置」该不该显示（容器外 + 真的能列） | 这条分支**只在沙盒下才有区别** ⇒ 侧载版跑一百遍都走「都放行」那一路，编译、肉眼、手跑全都没有反馈；错了的后果是用户点开「文稿」看到**空文件夹**，以为文件丢了 |
#
# ⚠️ 本项目**没有测试 target**（`project.yml` 里没有 unit-test target）。这几道检查目前
#    是这类「静默错」唯一的自动化防线，所以 CI 必须跑它们。
#
# 前置：先构建（`scripts/build.sh`）。最后一道（诊断包）会去驱动 app 的导出命令。
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/env.sh"

SWIFT_SRC="$SWIFT_DIR/Sources/DroidBerth"
APP_BIN="$APP_PATH/Contents/MacOS/$APP_NAME"

# ── swiftc 的沙箱逃逸：**必要性已证实，而且它随时会需要** ────────────────────
#
# 起因：受限沙箱挡住 swift-plugin-server，症状是宏（`@Observable` / `@State`）报
# `malformed response` —— 看着像代码错误，其实是环境。
#
# ⚠️ 这条机制一度被判为「必要性未被证实」，因为 2026-10-12 早上（06:20 前后）不带参数
#    也构建得过。**同一天 07:08 又需要了** —— 实录：
#
#      sandbox-exec: sandbox_apply: Operation not permitted
#      error: ... 'ObservationMacros.ObservableMacro' could not be found ... produced malformed response
#
#    中间**没有任何人改过配置**，只是会话的沙盒策略翻了回去。⇒ 结论不是「需不需要」，
#    而是「**它随时可能在两种状态之间切换**」，所以自动判断这件事本身是承重的：
#    常量加、常量不加，都会在某一半时间里是错的。
#
# 判据（`sandbox_escape_args`）：**能跑起来的最小放开集** —— profile 要带
# `allow process-exec`、程序用 `/usr/bin/true`（macOS 没有 `/bin/true`）。实测它与真实需求同步：
# 判据返回 71 的那些时刻，上面那段 `malformed response` 必然出现。
sandbox_escape_args() {
  if ! command -v sandbox-exec >/dev/null 2>&1; then return 0; fi
  local code=0
  sandbox-exec -p '(version 1)(deny default)(allow file-read*)(allow process-exec)' /usr/bin/true >/dev/null 2>&1 || code=$?
  [ "$code" != "0" ] && printf '%s' "-Xfrontend -disable-sandbox"
  return 0
}

ESCAPE="$(sandbox_escape_args)"
# 变量后面紧跟中文标点必须写 ${} —— macOS 的 bash 3.2 会把全角括号的字节算进变量名，
# 于是 `$ESCAPE）` 变成变量 `ESCAPE）` 而报 unbound variable（本项目已栽过三次）。
[ -n "$ESCAPE" ] && echo "（检测到受限沙箱：给 swiftc 加 ${ESCAPE}）"
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 第 0 道守卫：shell 的 `${VAR}` 陷阱 ────────────────────────────────
#
# macOS 自带的 bash 是 **3.2**，它会把 `"$VAR，"` 里的**全角标点算进变量名** ——
# 运行时才报 `VAR，: unbound variable`，而代码看起来完全正常。
# 这一条在本项目已经栽过四次（最近两次都在同一天、同一个新脚本里），
# 因为本项目所有脚本的注释与输出都是中文，天天会撞。
#
# 判据一眼可查、零成本，所以直接进守卫，不再靠「记得」。
echo "── shell：\$VAR 后面紧跟非 ASCII 字符"
SHELL_TRAP="$(grep -rnE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' \
  "$ROOT"/scripts/*.sh "$ROOT"/macos/Scripts/*.sh 2>/dev/null \
  | grep -vE ':[0-9]+: *#' || true)"
if [ -n "$SHELL_TRAP" ]; then
  echo "FAIL —— 这些写法在 bash 3.2 下会变成「变量名里带全角标点」："
  printf '%s\n' "$SHELL_TRAP"
  echo "改法：写成 \${VAR}，或把标点挪出引号。"
  exit 1
fi
echo "   OK"
echo

SDK="$(xcrun --show-sdk-path --sdk macosx)"
# shellcheck disable=SC2206
BASE_FLAGS=(-target arm64-apple-macos14.0 -sdk "$SDK" -swift-version 6 -strict-concurrency=complete)
[ -n "$ESCAPE" ] && BASE_FLAGS+=(-Xfrontend -disable-sandbox)

run_swift_check() {
  local name="$1"; shift
  local dir="$WORK/$name"
  mkdir -p "$dir"
  # 必须叫 main.swift —— 顶层代码只允许出现在这个文件名里。
  cp "$ROOT/scripts/$name.swift" "$dir/main.swift"
  echo "── $name"
  swiftc -O -o "$dir/run" "${BASE_FLAGS[@]}" "$@" "$dir/main.swift"
  "$dir/run"
  echo
}

run_swift_check check-icon-mapping \
  "$SWIFT_SRC/Support/FileTypeIcon.swift" \
  "$SWIFT_SRC/Support/ByteFormat.swift"

# ⚠️ 下面每个 `run_swift_check` 的文件清单是**手写的**：给某个源文件新增一条引用，
#    就要把被引用的那个文件也加进对应清单，否则**编译直接失败**（不是静默出错 —— 这点还好）。
#    2026-10-12 一天里因此断了两次（`LocalFileSystem.swift` 先后新增了对
#    `LocalPlacePolicy` 与被 `AppLog` 的引用）。
run_swift_check check-grid-navigation \
  "$SWIFT_SRC/Support/GridNavigation.swift" \
  "$SWIFT_SRC/Support/NameComparison.swift" \
  "$SWIFT_SRC/Support/BrowserEntry.swift" \
  "$SWIFT_SRC/ADB/RemoteEntry.swift" \
  "$SWIFT_SRC/Local/LocalFileSystem.swift" \
  "$SWIFT_SRC/Support/AppPaths.swift" \
  "$SWIFT_SRC/Support/LocalPlacePolicy.swift" \
  "$SWIFT_SRC/Support/AppLog.swift" \
  "$SWIFT_SRC/Support/FileTypeIcon.swift" \
  "$SWIFT_SRC/Support/ByteFormat.swift"

run_swift_check check-transfer-semantics \
  "$SWIFT_SRC/Support/NameComparison.swift" \
  "$SWIFT_SRC/Transfer/NameConflict.swift" \
  "$SWIFT_SRC/Support/DeviceNameRules.swift" \
  "$SWIFT_SRC/Support/ThumbnailPolicy.swift" \
  "$SWIFT_SRC/Support/ByteFormat.swift"

run_swift_check check-local-place-policy \
  "$SWIFT_SRC/Support/LocalPlacePolicy.swift"

if [ ! -x "$APP_BIN" ]; then
  echo "找不到已构建的 app：$APP_BIN" >&2
  echo "先跑 scripts/build.sh —— 诊断包守卫要驱动 app 自己的导出命令。" >&2
  exit 1
fi

echo "── check-diagnostics-bundle"
"${PYTHON:-/usr/bin/python3}" "$ROOT/scripts/check-diagnostics-bundle.py" "$APP_BIN"
echo
echo "全部回归守卫通过。"
