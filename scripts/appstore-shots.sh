#!/bin/bash
# 生成**可提交**的 App Store 截图。
#
# 与 `ui-shot.sh` 的分工：那个抓图给验收 / 诊断用，保留原始 PNG 原样；
# 这个在它之上做**提交所要求的处理**，因为 App Store Connect 会逐项校验：
#
#   1. **精确像素数**（不是只校验比例）—— 所以窗口本身就得是那个尺寸，**不能靠缩放**：
#      拉伸出来的图既是假的、也会被拒。
#   2. **不允许 alpha 通道** —— `screencapture` 的 PNG 带 alpha（实测 hasAlpha: yes），
#      哪怕里面没有透明像素也一样会被拒。用 `png-flatten.swift` 重绘掉。
#   3. **sRGB** —— Display P3 / Adobe RGB / CMYK 都会有色偏，ASC 只收 sRGB。
#   4. 单张 ≤ 10 MB、1–10 张、PNG 或 JPEG。
#
# App Store 接受的 Mac 尺寸（**16:10**，四选一）：1280×800 · 1440×900 · 2560×1600 · 2880×1800。
# 本机屏幕是 2560×1440（16:9），放不下 2880×1800 ⇒ 这里固定用 **1440×900**。
#
# 用法：
#     ./scripts/appstore-shots.sh resize             # 把 DroidBerth 窗口调成 1440×900
#     ./scripts/appstore-shots.sh shoot <输出目录> <名>   # 抓一张（去 alpha + 校验）
#     ./scripts/appstore-shots.sh verify <目录>       # 校验目录里所有 PNG
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PROCESS_NAME="DroidBerth"
TARGET_W=1440
TARGET_H=900
MAX_BYTES=$((10 * 1024 * 1024))

fail() { echo "   ✗ $1" >&2; exit 1; }
ok()   { echo "   ✓ $1"; }

# ── 编译 png-flatten（顶层代码必须落在 main.swift 里）─────────────────────
build_flatten() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$ROOT/scripts/png-flatten.swift" "$dir/main.swift"
  swiftc -O -o "$dir/png-flatten" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -swift-version 6 "$dir/main.swift" > "$dir/build.log" 2>&1 \
    || { tail -10 "$dir/build.log" >&2; fail "png-flatten 编译失败"; }
}

case "${1:-}" in
  resize)
    # 用 AX API 调窗口（`window-resize.swift`）。
    #
    # ⚠️ **不走 AppleScript**：`tell application "System Events"` 需要 **Automation** 权限，
    #    那是与「辅助功能」**不同的 TCC 类别**。2026-10-12 实测本机只给了辅助功能
    #    ⇒ osascript 报 `execution error: 发生权限违例 (-10004)`。
    #    AX API 只需要辅助功能，而 `ui-shot` / `ui-report` 用的就是它，已经授权。
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cp "$ROOT/scripts/window-resize.swift" "$WORK/main.swift"
    swiftc -O -o "$WORK/window-resize" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
      -swift-version 6 "$WORK/main.swift" > "$WORK/build.log" 2>&1 \
      || { tail -10 "$WORK/build.log" >&2; fail "window-resize 编译失败"; }
    "$WORK/window-resize" "$APP_PROCESS_NAME" "$TARGET_W" "$TARGET_H" 20 40 \
      || fail "调窗口失败（确认 DroidBerth 在运行，且「辅助功能」权限已给）"
    ;;

  shoot)
    OUT_DIR="${2:?用法: appstore-shots.sh shoot <输出目录> <名>}"
    NAME="${3:?缺名字}"
    OUT="$OUT_DIR/$NAME.png"
    mkdir -p "$OUT_DIR"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT

    # 1) 先用 ui-shot 抓原始窗口图（它负责找窗口、只抓那一个窗口）
    RAW="$WORK/raw.png"
    "$ROOT/scripts/ui-shot.sh" "$APP_PROCESS_NAME" "$RAW" > "$WORK/shot.log" 2>&1 \
      || { sed 's/^/   /' "$WORK/shot.log"; fail "抓图失败"; }

    # 2) 去 alpha + 强制 sRGB + **校验精确尺寸**（不符直接失败，不缩放）
    build_flatten "$WORK"
    "$WORK/png-flatten" "$RAW" "$OUT" "$TARGET_W" "$TARGET_H" \
      || fail "尺寸不是 ${TARGET_W}×${TARGET_H} —— 先跑 \`appstore-shots.sh resize\`，别改脚本去缩放"

    # 3) 复核成品（用 sips 独立验一遍，不信自己刚才写的）
    #
    # ⚠️ 不用 `local`：这一层是 `case` 顶层、不在函数里，`local` 会直接报错。
    #    而 `${VAR}` 的写法是必须的 —— 本项目脚本全中文，`$alpha）` 这种紧贴全角标点的
    #    写法在 bash 3.2 下会把标点算进变量名（`check-all.sh` 第 0 道守卫专拦这个，
    #    它当场就抓到了我这一段的 3 处）。
    space="$(sips -g space "$OUT" 2>/dev/null | awk -F': ' '/space/{print $2}')"
    alpha="$(sips -g hasAlpha "$OUT" 2>/dev/null | awk -F': ' '/hasAlpha/{print $2}')"
    [ "${alpha}" = "no" ] || fail "产物仍带 alpha（${alpha}）"
    case "${space}" in
      RGB|sRGB*) ok "${NAME}.png（${space}，无 alpha）" ;;
      *) fail "色彩空间是 ${space}，ASC 要 sRGB" ;;
    esac
    ;;

  verify)
    DIR="${2:?用法: appstore-shots.sh verify <目录>}"
    echo "── 校验 $DIR"
    count=0
    for f in "$DIR"/*.png; do
      [ -f "$f" ] || continue
      count=$((count + 1))
      w="$(sips -g pixelWidth  "$f" 2>/dev/null | awk -F': ' '/pixelWidth/{print $2}')"
      h="$(sips -g pixelHeight "$f" 2>/dev/null | awk -F': ' '/pixelHeight/{print $2}')"
      a="$(sips -g hasAlpha    "$f" 2>/dev/null | awk -F': ' '/hasAlpha/{print $2}')"
      s="$(sips -g space       "$f" 2>/dev/null | awk -F': ' '/space/{print $2}')"
      bytes="$(stat -f%z "$f")"
      problem=""
      [ "$w" = "$TARGET_W" ] && [ "$h" = "$TARGET_H" ] || problem="$problem 尺寸(${w}×${h})"
      [ "$a" = "no" ] || problem="$problem alpha"
      case "$s" in RGB|sRGB*) ;; *) problem="$problem 色彩空间($s)";; esac
      [ "$bytes" -le "$MAX_BYTES" ] || problem="$problem 超过10MB"
      if [ -z "$problem" ]; then
        ok "$(basename "$f")  ${w}×${h}  $((bytes / 1024)) KB"
      else
        echo "   ✗ $(basename "$f") ——$problem"
      fi
    done
    echo
    if [ "$count" -eq 0 ]; then fail "目录里没有 PNG"; fi
    if [ "$count" -gt 10 ]; then fail "有 $count 张，ASC 最多 10 张"; fi
    ok "共 $count 张（ASC 允许 1–10 张）"
    ;;

  *)
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
