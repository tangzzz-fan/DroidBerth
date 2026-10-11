#!/bin/bash
# 发布前闸门 —— 把 PRD §28 的「发布前检查清单」变成**可执行**的东西。
#
# 为什么需要它：清单写在文档里时，只有**认真读的人**才会执行；而发布是低频动作，
# 每次都是「上次怎么做的来着」。把机器能判的判据全部脚本化，剩下的（法务、真机验收）
# 就没法藏在「清单太长没看完」后面了。
#
#   ./scripts/check-release.sh            # 校验当前构建 + dist/（如果有）
#   ./scripts/check-release.sh 1.0.0      # 同时校验版本号是不是 1.0.0
#
# 三档结论，**含义不同，不要混**：
#   ✓  PASS  机器判过，达标
#   ✗  FAIL  机器判过，**不达标** —— 退出码 1，这就是「还不能发」
#   ⚠️  HUMAN 机器判不了（法务、真机、人工体验），只能人来给结论
#
# 用法上的约定：**FAIL 一律不可绕过**。想放行就先改到达标，或者明确地把它降级成
# HUMAN 并在文档里写清为什么 —— 不要注释掉检查。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
source "$ROOT/scripts/env.sh"

EXPECTED_VERSION="${1:-}"

FAILURES=0
WARNINGS=0
PASSES=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
human() { printf '  \033[33m⚠\033[0m %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
group() { printf '\n── %s\n' "$1"; }

# `plutil -extract … raw` 取单个键；缺失时报错而不是静默给空串。
plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

echo "══ 发布前闸门"
echo "   产物 : $APP_PATH"
[ -d "$APP_PATH" ] || { echo "   找不到已构建的 app —— 先跑 ./scripts/build.sh" >&2; exit 2; }
echo

# ─────────────────────────────────────────────────────────────
group "1. 信任链（prd §28：签名 / 公证 / 票据）"

if codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
  pass "codesign --verify --deep --strict 通过"
else
  fail "codesign 校验失败 —— 签名有问题，公证也不可能过"
fi

# 三个（且只有三个）可执行文件：app / sidecar / adb。多一个就是有东西混进来了。
BIN_DIR="$APP_PATH/Contents/MacOS"
BIN_COUNT=0
EXPECTED_BINARIES=0
for bin in "$BIN_DIR"/*; do
  [ -f "$bin" ] || continue
  BIN_COUNT=$((BIN_COUNT + 1))
done
[ "$BIN_COUNT" = "3" ] && pass "恰好三个可执行文件（app / sidecar / adb）" \
                        || fail "可执行文件数是 ${BIN_COUNT}，PRD §28 要求恰好 3 个"

# 每个 Mach-O：hardened runtime + 同一个 TeamID
TEAM_IDS=""
for bin in "$BIN_DIR"/*; do
  [ -f "$bin" ] || continue
  name="$(basename "$bin")"
  flags="$(codesign -dv "$bin" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\).*/\1/p')"
  team="$(codesign -dv "$bin" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  case "$flags" in
    *0x10000*) ;;
    *) fail "$name 没有 hardened runtime（flags=${flags}，应含 0x10000）" ;;
  esac
  if [ -n "$team" ]; then TEAM_IDS="$TEAM_IDS$team
"; fi
done
UNIQUE_TEAMS="$(printf '%s' "$TEAM_IDS" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
[ "$UNIQUE_TEAMS" = "1" ] && pass "三个 Mach-O 的 TeamIdentifier 一致（$(printf '%s' "$TEAM_IDS" | sed '/^$/d' | sort -u | head -1)）" \
                          || fail "三个 Mach-O 的 TeamIdentifier 不一致"

# entitlements：Release 必须**没有** get-task-allow（带它的包无法公证）
ENT="$(codesign -d --entitlements - "$APP_PATH" 2>/dev/null || true)"
if printf '%s' "$ENT" | grep -q "get-task-allow"; then
  fail "Release 包里带了 get-task-allow —— 带它的包无法公证（project.yml 按配置声明）"
else
  pass "Release 没有 get-task-allow"
fi

SPCTL_OUT="$(spctl -a -vvv "$APP_PATH" 2>&1 || true)"
case "$SPCTL_OUT" in
  *rejected*) fail "Gatekeeper 拒绝了 app：$(printf '%s' "$SPCTL_OUT" | head -2 | tr '\n' ' ')" ;;
  *Notarized*) pass "Gatekeeper：Notarized Developer ID" ;;
  *) human "Gatekeeper 的措辞不是预期的 'Notarized'，请人工看：$(printf '%s' "$SPCTL_OUT" | head -2 | tr '\n' ' ')" ;;
esac

if xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
  pass "app 的公证票据已 staple"
else
  fail "app 没有 staple 公证票据"
fi

# ─────────────────────────────────────────────────────────────
group "2. 构建形态（prd §28：架构 / 图标 / 随包声明）"

ARCHS="$(lipo -archs "$BIN_DIR/$APP_NAME" 2>/dev/null || echo '?')"
[ "$ARCHS" = "arm64" ] && pass "ARCHS = arm64（PRD §5.1 只发 Apple Silicon）" \
                       || fail "ARCHS = ${ARCHS}，期望只有 arm64"

# 图标十档：解析 .icns 容器里**图像块**的个数。
#
# 两个坑都踩过，别再改回去：
#   · 每个块的布局是 `4 字节 type + 4 字节 size`，**先 type 后 size**。
#     把前 4 字节当 size 读，会把 type（比如 `ic09`）当成一个巨大的长度，循环立刻结束 ——
#     现象是「档数 = 1」，看着像图标真的只有一档。
#   · 容器里除了图像还有**元数据块**（`info` 目录、`TOC `、`icnV`、`sbtp` …），它们不算档位。
#     所以按**已知的十个图像类型**判，而不是数所有块。
ICNS="$APP_PATH/Contents/Resources/$(plist_get "$APP_PATH/Contents/Info.plist" CFBundleIconFile)"
case "$ICNS" in *.icns) ;; *) ICNS="$ICNS.icns" ;; esac
# ic04=16 ic11=16@2x · ic05=32 ic12=32@2x · ic07=128 ic13=128@2x · ic08=256 ic14=256@2x · ic09=512 ic10=512@2x
EXPECTED_ICON_TYPES="ic04 ic05 ic07 ic08 ic09 ic10 ic11 ic12 ic13 ic14"
if [ -f "$ICNS" ]; then
  FOUND_ICON_TYPES="$("${PYTHON:-/usr/bin/python3}" - "$ICNS" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
if data[:4] != b"icns":
    print("BADMAGIC"); raise SystemExit
offset, types = 8, []
while offset + 8 <= len(data):
    kind = data[offset:offset + 4]
    size = struct.unpack(">I", data[offset + 4:offset + 8])[0]
    if size < 8:
        break
    types.append(kind.decode("ascii", "replace"))
    offset += size
print(" ".join(t for t in types if t.startswith("ic") and t[2:].isdigit()))
PY
)"
  MISSING_ICON_TYPES=""
  for want in $EXPECTED_ICON_TYPES; do
    case " $FOUND_ICON_TYPES " in
      *" $want "*) ;;
      *) MISSING_ICON_TYPES="$MISSING_ICON_TYPES $want" ;;
    esac
  done
  if [ -z "$MISSING_ICON_TYPES" ]; then
    pass "icon.icns 含全部十档（16/32/128/256/512 各含 @2x）"
  else
    fail "icon.icns 缺少档位：${MISSING_ICON_TYPES# }（现有：${FOUND_ICON_TYPES}）"
  fi
else
  fail "Info.plist 指向的图标不在包里（${ICNS}）"
fi

if [ -s "$APP_PATH/Contents/Resources/NOTICE.txt" ]; then
  pass "NOTICE.txt 随包（PRD §28 / adb 的 Apache-2.0 声明）"
else
  fail "包里没有 NOTICE.txt —— 许可声明缺失，不能公开分发"
fi

CATEGORY="$(plist_get "$APP_PATH/Contents/Info.plist" LSApplicationCategoryType)"
[ -n "$CATEGORY" ] && pass "LSApplicationCategoryType = $CATEGORY" \
                   || fail "缺 LSApplicationCategoryType（App Store 也要求这一项）"

COPYRIGHT="$(plist_get "$APP_PATH/Contents/Info.plist" NSHumanReadableCopyright)"
[ -n "$COPYRIGHT" ] && pass "NSHumanReadableCopyright = $COPYRIGHT" \
                    || fail "NSHumanReadableCopyright 是空的 —— 发布产物里应有版权声明"

# 产物里不该出现源码路径（改名 / 换目录后若嵌进去，会成为难以解释的痕迹）
LEAKS=0
for bin in "$BIN_DIR"/*; do
  [ -f "$bin" ] || continue
  if strings "$bin" 2>/dev/null | grep -q "Developments"; then LEAKS=$((LEAKS + 1)); fi
done
[ "$LEAKS" = "0" ] && pass "产物里没有源码绝对路径" \
                   || fail "$LEAKS 个 Mach-O 里嵌了本机源码路径"

# ─────────────────────────────────────────────────────────────
group "3. 版本号"

APP_VERSION="$(plist_get "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)"
BUILD_VERSION="$(plist_get "$APP_PATH/Contents/Info.plist" CFBundleVersion)"
pass "CFBundleShortVersionString = $APP_VERSION"
[ -n "$BUILD_VERSION" ] && pass "CFBundleVersion = $BUILD_VERSION" || fail "CFBundleVersion 为空"
if [ -n "$EXPECTED_VERSION" ]; then
  [ "$APP_VERSION" = "$EXPECTED_VERSION" ] && pass "版本号与期望的 $EXPECTED_VERSION 一致" \
                                           || fail "版本号是 ${APP_VERSION}，期望 $EXPECTED_VERSION"
fi

# ─────────────────────────────────────────────────────────────
group "4. dist/ 产物（若已打包）"

DIST="$ROOT/dist"
if [ -d "$DIST" ] && [ -n "$(ls -A "$DIST" 2>/dev/null)" ]; then
  V="${EXPECTED_VERSION:-$APP_VERSION}"
  [ -f "$DIST/$APP_NAME-$V.dmg" ] && pass "DMG：$APP_NAME-$V.dmg" || fail "缺 $APP_NAME-$V.dmg"
  [ -f "$DIST/$APP_NAME-$V.zip" ] && pass "zip：$APP_NAME-$V.zip" || fail "缺 $APP_NAME-$V.zip"
  [ -f "$DIST/NOTICE.txt" ] && pass "NOTICE.txt 已挂在 Release 附件里" || fail "dist 里没有 NOTICE.txt"
  [ -f "$DIST/SHA256SUMS.txt" ] && pass "SHA256SUMS.txt 存在" || fail "dist 里没有 SHA256SUMS.txt"

  if [ -f "$DIST/SHA256SUMS.txt" ]; then
    if (cd "$DIST" && shasum -a 256 -c SHA256SUMS.txt >/dev/null 2>&1); then
      pass "SHA256SUMS.txt 逐项校验通过（裸文件名）"
    else
      fail "SHA256SUMS.txt 校验不通过 —— 附件被改过或清单写错了"
    fi
  fi

  if [ -f "$DIST/RELEASE-NOTES.md" ]; then
    if grep -q '__VERSION__' "$DIST/RELEASE-NOTES.md"; then
      fail "RELEASE-NOTES.md 里还留着 __VERSION__ 占位符"
    else
      pass "RELEASE-NOTES.md 没有占位符残留"
    fi
  else
    fail "dist 里没有 RELEASE-NOTES.md"
  fi

  # DMG 自己的签名与票据
  if [ -f "$DIST/$APP_NAME-$V.dmg" ]; then
    if xcrun stapler validate "$DIST/$APP_NAME-$V.dmg" >/dev/null 2>&1; then
      pass "DMG 的公证票据已 staple"
    else
      fail "DMG 没有 staple 票据"
    fi
    # 评 DMG 必须带 --context context:primary-signature，否则会误报 Insufficient Context
    if spctl -a -t open --context context:primary-signature -v "$DIST/$APP_NAME-$V.dmg" >/dev/null 2>&1; then
      pass "Gatekeeper 接受这个 DMG"
    else
      fail "Gatekeeper 不接受这个 DMG（spctl -a -t open --context context:primary-signature）"
    fi
  fi

  # app zip 里不该有 AppleDouble 边车（ditto 会给每个成员写 ._ 名字）
  ZIP="$DIST/$APP_NAME-$V.zip"
  if [ -f "$ZIP" ]; then
    if unzip -l "$ZIP" 2>/dev/null | grep -q '__MACOSX\|/\._'; then
      fail "app zip 里有 AppleDouble 边车（应改用 zip -X -y，不是 ditto）"
    else
      pass "app zip 里没有 ._ 垃圾项"
    fi
  fi
else
  human "dist/ 还是空的 —— 打包之后再跑一次才能校验附件（./scripts/package-release.sh <版本>）"
fi

# ─────────────────────────────────────────────────────────────
group "5. 仓库级（公开分发的门槛）"

[ -f "$ROOT/LICENSE" ] && pass "仓库有 LICENSE" \
                       || fail "仓库没有 LICENSE —— 公开分发前必须选定并落盘（路线图 B1）"

[ -f "$ROOT/CHANGELOG.md" ] && pass "仓库有 CHANGELOG.md" \
                            || fail "仓库没有 CHANGELOG.md —— 1.0.0 应该有一份变更记录"

# ─────────────────────────────────────────────────────────────
group "6. 只能人工判的（机器给不了结论）"

human "法务对 NOTICE.txt §3.5 适用性的确认 —— 未确认前不要把构建当成「可公开分发的正式版」（路线图 B2）"
human "声明支持范围 Android 10–16 的实测覆盖 —— 目前只验过 Android 10 与范围外的 API 37（路线图 A1）"
human "交互层人工验收 —— 清单见 docs/1011_03_1.0-roadmap.md §8（路线图 A2）"
human "干净 VM 安装 / App Translocation / 性能基线（路线图 A3–A5）"

# ─────────────────────────────────────────────────────────────
echo
echo "════ 结论"
printf '  PASS %d · FAIL %d · 人工项 %d\n' "$PASSES" "$FAILURES" "$WARNINGS"
if [ "$FAILURES" -gt 0 ]; then
  echo
  echo "  **还不能发。** 上面 $FAILURES 条 FAIL 是机器判定的硬门槛，先改到达标。"
  echo "  （人工项那 $WARNINGS 条即使全绿也不构成「可以发」—— 它们只是没人给结论。）"
  exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
  echo
  echo "  机器能判的都过了。**但「可以发」还取决于上面 $WARNINGS 条人工项** ——"
  echo "  尤其是法务与声明范围的实测覆盖。"
else
  echo
  echo "  全部通过。"
fi
