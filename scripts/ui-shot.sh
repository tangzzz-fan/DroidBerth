#!/bin/bash
# 给某个进程的窗口截图 —— 用于**自己看界面**，不需要人来点。
#
# 背景：本项目的 README 里长期写着「本机无法截图」，因此全部 UI 验收都挂在「等人眼过一遍」。
# 2026-10-12 实测这条**不成立**：`screencapture` 在（`/usr/sbin/screencapture`），
# 而且可以**只抓某个窗口**，不用抓整屏。
#
# 用法：
#   ./scripts/ui-shot.sh                      # 默认找 DroidBerth 的窗口
#   ./scripts/ui-shot.sh "<app 名片段>" <输出 png>
#
# 结果落在 `reports/`（不入库）。截图拿来看完之后建议删掉 —— 里面可能有你的文件名。
#
# ⚠️ 需要「屏幕录制」权限（系统设置 → 隐私与安全性 → 屏幕录制）。没给权限时
#    `screencapture` 仍会产出文件，只是**窗口内容不在里面**（或整张是壁纸）——
#    所以本脚本最后会把文件大小与像素尺寸打出来，**别只看退出码**。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TARGET="${1:-DroidBerth}"
OUT="${2:-$ROOT/reports/ui-shot-$(date +%Y%m%d-%H%M%S).png}"

mkdir -p "$(dirname "$OUT")"

# 编译定位工具（与 check-*.swift 同一套做法：源码在 scripts/，产物落临时目录）。
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/ui-shot" \
  -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 6 \
  "$ROOT/scripts/ui-shot.swift"

WINDOW_LINE="$("$WORK/ui-shot" "$TARGET")"
# 一个 app 可能不止一个主窗口，工具会**每个窗口打一行** —— 这里只取第一行。
# 少了这一步，下面那几个 `awk -F'\t'` 会对每一行都打一次，输出里多出几行光秃秃的坐标。
WINDOW_LINE="${WINDOW_LINE%%$'\n'*}"
WINDOW_ID="${WINDOW_LINE%%$'\t'*}"
BOUNDS="$(printf '%s' "$WINDOW_LINE" | awk -F'\t' '{print $3}')"
TITLE="$(printf '%s' "$WINDOW_LINE" | awk -F'\t' '{print $2}')"

echo "窗口    : id=${WINDOW_ID} title=「${TITLE}」 bounds=${BOUNDS}"

# `-l <id>` 只抓这个窗口；`-o` 不要投影（否则图里多一圈阴影，看边界时容易误判）；
# `-x` 不要快门声。
#
# ⚠️ 必须自己接住退出码：`set -e` 会在 screencapture 失败的那一刻**直接掐断脚本**，
#    下面那段「该开哪个权限」的提示就永远打不出来 —— 而它恰恰是失败时最该看到的东西。
set +e
screencapture -x -o -l "$WINDOW_ID" "$OUT"
SHOT_STATUS=$?
set -e
echo "screencapture 退出码: ${SHOT_STATUS}"

if [ ! -f "$OUT" ]; then
  cat >&2 <<'MSG'
截图没产出文件。

最常见的原因是**没有「屏幕录制」权限**（TCC），此时 screencapture 会报
`could not create image from display` / `could not create image from window`。
⚠️ 这和「沙箱」无关 —— 2026-10-12 实测：把外层沙箱整个摘掉，同样报这两句。

授权：系统设置 → 隐私与安全性 → 屏幕录制 → 勾上**运行本命令的那个 app**
（在 WorkBuddy 里跑就勾 WorkBuddy；在自己终端里跑就勾该终端），然后**重启那个 app**。

授权前的替代办法：本项目有 `--diagnose`（CLI，不需要任何权限），
以及 `lsof -p <pid>` 看 cwd 判断沙盒是否生效（工程笔记 §10.3）。
MSG
  exit 1
fi

echo "输出    : $OUT"
printf '大小    : %s 字节\n' "$(wc -c < "$OUT" | tr -d ' ')"
printf '像素    : %s\n' "$(/usr/bin/sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null \
  | awk -F': ' '/pixel/{printf "%s ", $2}')"
echo
echo "⚠️ 文件小不等于失败、大也不等于成功 —— **打开看一眼**再下结论。"
echo "   没有「屏幕录制」权限时，图里不会有窗口内容。"
