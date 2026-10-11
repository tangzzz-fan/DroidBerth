#!/bin/bash
# 跑**全部**回归守卫。CI 与本地共用同一个入口 —— 这样「CI 绿了但本地是另一套检查」
# 这种最常见的失配从结构上不会发生。
#
# 三个守卫各有分工，**都不能省**：
#
# | 守卫 | 守什么 | 为什么编译器不管 |
# | --- | --- | --- |
# | `check-icon-mapping` | 同一扩展名在两栏（Mac / 设备）得到同一个符号 | 缺陷表现是「**静默分叉**」——两处 switch 各写一遍，`.apk` 在一边变通用文稿，没有任何编译错误 |
# | `check-transfer-semantics` | 折叠规则、冲突改名、名称校验、缩略图范围 | 全是纯函数判据；错的方向会让**用户手机上的文件被静默覆盖** |
# | `check-diagnostics-bundle` | 诊断包条目数 / 中文名编码 / 无隐私泄露 | 缺陷表现是「**产物打开来才发现**」——曾经产出过一个只有根目录的空包，不报任何错 |
#
# ⚠️ 本项目**没有测试 target**（`project.yml` 里没有 unit-test target）。这三个脚本目前
#    是这类「静默错」唯一的自动化防线，所以 CI 必须跑它们。
#
# 前置：先构建（`scripts/build.sh`）。第三个守卫会去跑 app 的导出命令。
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/env.sh"

SWIFT_SRC="$SWIFT_DIR/Sources/DroidBerth"
APP_BIN="$APP_PATH/Contents/MacOS/$APP_NAME"

# ── swiftc 的沙箱逃逸：只在本机受限沙箱里需要 ──────────────────────────
#
# 受限沙箱会挡住 swift-plugin-server，症状是宏（`@Observable` / `@State`）报
# `malformed response` —— 看着像代码错误，其实是环境。判据是那条探针的退出码：
# 71 = sandbox_apply 被拒。CI 与用户自己的终端都不需要这个参数，所以**自动判**。
sandbox_escape_args() {
  if ! command -v sandbox-exec >/dev/null 2>&1; then return 0; fi
  local code=0
  sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok >/dev/null 2>&1 || code=$?
  [ "$code" = "71" ] && printf '%s' "-Xfrontend -disable-sandbox"
  return 0
}

ESCAPE="$(sandbox_escape_args)"
# 变量后面紧跟中文标点必须写 ${} —— macOS 的 bash 3.2 会把全角括号的字节算进变量名，
# 于是 `$ESCAPE）` 变成变量 `ESCAPE）` 而报 unbound variable（本项目已栽过三次）。
[ -n "$ESCAPE" ] && echo "（检测到受限沙箱：给 swiftc 加 ${ESCAPE}）"
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

run_swift_check check-transfer-semantics \
  "$SWIFT_SRC/Support/NameComparison.swift" \
  "$SWIFT_SRC/Transfer/NameConflict.swift" \
  "$SWIFT_SRC/Support/DeviceNameRules.swift" \
  "$SWIFT_SRC/Support/ThumbnailPolicy.swift" \
  "$SWIFT_SRC/Support/ByteFormat.swift"

if [ ! -x "$APP_BIN" ]; then
  echo "找不到已构建的 app：$APP_BIN" >&2
  echo "先跑 scripts/build.sh —— 诊断包守卫要驱动 app 自己的导出命令。" >&2
  exit 1
fi

echo "── check-diagnostics-bundle"
"${PYTHON:-/usr/bin/python3}" "$ROOT/scripts/check-diagnostics-bundle.py" "$APP_BIN"
echo
echo "全部回归守卫通过。"
