#!/bin/bash
# UI 树报告 —— 见 `scripts/ui-report.swift` 顶部注释（为什么需要、要什么权限）。
#
# 用法：
#   ./scripts/ui-report.sh                      # 默认 DroidBerth，打骨架
#   ./scripts/ui-report.sh DroidBerth texts     # 只打有文字的节点
#   ./scripts/ui-report.sh DroidBerth press 位置 # 按一下「位置」按钮（弹层会跟着打出来）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TARGET="${1:-DroidBerth}"
MODE="${2:-tree}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/ui-report" \
  -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 6 \
  "$ROOT/scripts/ui-report.swift"

case "$MODE" in
  texts) exec "$WORK/ui-report" "$TARGET" --texts ;;
  press) exec "$WORK/ui-report" "$TARGET" --press "${3:?用法: ui-report.sh <app> press <文字>}" ;;
  *)     exec "$WORK/ui-report" "$TARGET" ;;
esac
