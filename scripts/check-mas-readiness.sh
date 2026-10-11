#!/bin/bash
# MAS 上架前自检 —— 对应 `check-release.sh`（那是**侧载**的闸门），PRD §4 E6。
#
# 为什么要有它：MAS 版与侧载版的差别**几乎全在看不见的地方**（签名身份、每个 Mach-O 的
# entitlements、有没有 embedded provisioning profile）。而这些差别有一个共同的性质 ——
# **本地怎么跑都正常**，只有提交之后才会以「被拒」的形式暴露。所以它们的判据必须机器来判。
#
# 用法：
#   CONFIGURATION=Release-MAS ./scripts/check-mas-readiness.sh
#   ./scripts/check-mas-readiness.sh <path/to/DroidBerth.app>
#   ./scripts/check-mas-readiness.sh <app> 1.2.0        # 顺便核对版本号
#
# 三档结论同 `check-release.sh`，含义不同不要混：
#   ✓  PASS  机器判过，达标
#   ✗  FAIL  机器判过，**不达标** ⇒ 退出码 1（上架前必须清零）
#   ⚠️  HUMAN 机器判不了（法务、资质、人眼体验），只能人来给结论
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
source "$ROOT/scripts/env.sh"

APP="${1:-$APP_PATH}"
EXPECTED_VERSION="${2:-}"

FAILURES=0
WARNINGS=0
PASSES=0
pass()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
human() { printf '  \033[33m⚠\033[0m %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
group() { printf '\n── %s\n' "$1"; }

PYTHON="${PYTHON:-/usr/bin/python3}"

# 取某个 Mach-O 的 entitlements 里**为 true** 的那些键，每行一个、已排序。
# 用 `:-`（不是 `-`）才拿到 XML plist —— 裸 `-` 输出的是给人看的符号格式，不好解析。
ent_keys() {
  codesign -d --entitlements :- "$1" 2>/dev/null | "$PYTHON" -c '
import plistlib, sys
raw = sys.stdin.buffer.read()
if not raw.strip():
    raise SystemExit(0)
try:
    data = plistlib.loads(raw)
except Exception:
    raise SystemExit(0)
if not isinstance(data, dict):
    raise SystemExit(0)
print("\n".join(sorted(k for k, v in data.items() if v is True)))
' || true
}

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# hardened runtime 是 CodeDirectory 的 **0x10000 这一位**。
# ⚠️ 必须按位判，**不能子串匹配**：ad-hoc 签名的构建是 `flags=0x10002(adhoc,runtime)`，
#    里面不含子串 `10000` —— 用 grep 找 `10000` 会把 ad-hoc 构建误报成「没开 hardened runtime」。
#    （这条在本脚本第一次跑就真的发生了：先是全 PASS，改成 ad-hoc 重签后同一个包变成 FAIL。）
has_runtime() {
  codesign -dvvv "$1" 2>&1 | "$PYTHON" -c '
import re, sys
m = re.search(r"flags=0x([0-9a-fA-F]+)", sys.stdin.read())
if m and (int(m.group(1), 16) & 0x10000):
    print("yes")
'
}

echo "══ MAS 上架前自检"
echo "   产物 : $APP"
if [ ! -d "$APP" ]; then
  echo
  echo "找不到 app bundle。" >&2
  echo "  MAS 版要先构建：CONFIGURATION=Release-MAS ./scripts/build.sh" >&2
  exit 2
fi
echo

BIN_DIR="$APP/Contents/MacOS"
MAIN_BIN="$BIN_DIR/$APP_NAME"
HELPERS=("$SIDECAR_NAME" "adb")

# app 要求的权限集（与 `macos/Resources/DroidBerth-MAS.entitlements` 一一对应）。
# 写成「必须都有」而不是「个数对就行」：漏一条的表现是某个功能在沙盒下**静默失效**。
APP_REQUIRED=(
  com.apple.security.app-sandbox
  com.apple.security.network.client
  com.apple.security.network.server
  com.apple.security.device.usb
  com.apple.security.files.user-selected.read-write
  com.apple.security.files.downloads.read-write
  com.apple.security.personal-information.photos-library
)
# 刻意不该出现的。前两条是 Apple 的态度问题（deprecated / 审核会问用途），
# 第三条是**功能性**的：带着它就无法公证（这条对 MAS 不致命，但说明构建配置串了）。
APP_FORBIDDEN=(
  com.apple.security.files.all
  com.apple.security.cs.disable-library-validation
  com.apple.security.get-task-allow
)

# ─────────────────────────────────────────────────────────────
group "1. 沙盒是不是真的在（MAS 的硬性要求）"

APP_KEYS="$(ent_keys "$APP")"
if printf '%s\n' "$APP_KEYS" | grep -qx "com.apple.security.app-sandbox"; then
  pass "app 带 com.apple.security.app-sandbox"
else
  fail "app **没有** app-sandbox —— 这不是 MAS 构建。用 CONFIGURATION=Release-MAS 重新构建"
fi

for key in "${APP_REQUIRED[@]}"; do
  [ "$key" = "com.apple.security.app-sandbox" ] && continue
  if printf '%s\n' "$APP_KEYS" | grep -qx "$key"; then
    pass "app 有 $key"
  else
    fail "app 缺 $key"
  fi
done

for key in "${APP_FORBIDDEN[@]}"; do
  if printf '%s\n' "$APP_KEYS" | grep -qx "$key"; then
    case "$key" in
      com.apple.security.get-task-allow)
        fail "app 带了 get-task-allow —— 这个包不是发布构建（没法公证，也不该上架）" ;;
      *)
        fail "app 带了不该有的 $key" ;;
    esac
  fi
done

# ─────────────────────────────────────────────────────────────
group "2. 内嵌可执行文件的 entitlements（审核最容易打回的一处）"
#
# 判据来自 Apple 开发者论坛（DTS）的说明：沙盒**功能上**由子进程自动继承，与它自己有没有
# entitlement 无关 —— 所以缺 `inherit` **本地怎么测都正常**，只在审核时被打回。
# 这一条正是「本地测不出来」的典型，所以必须机器判。

if [ ! -f "$MAIN_BIN" ]; then
  fail "Contents/MacOS 里没有主可执行文件 $APP_NAME —— bundle 不完整"
else
  count=0
  for entry in "$BIN_DIR"/*; do [ -f "$entry" ] && count=$((count + 1)); done
  expected=$(( ${#HELPERS[@]} + 1 ))
  if [ "$count" -eq "$expected" ]; then
    pass "Contents/MacOS 下恰好 ${count} 个可执行文件（app + ${#HELPERS[@]} 个 helper）"
  else
    fail "Contents/MacOS 下有 ${count} 个文件，预期 ${expected} —— 多出来的那个会被按「无 entitlements」留在包里"
  fi

  for helper in "${HELPERS[@]}"; do
    path="$BIN_DIR/$helper"
    if [ ! -f "$path" ]; then
      fail "内嵌的 ${helper} 不在包里"
      continue
    fi
    keys="$(ent_keys "$path")"
    if printf '%s\n' "$keys" | grep -qx "com.apple.security.app-sandbox"; then
      pass "${helper} 带 app-sandbox"
    else
      fail "${helper} 缺 app-sandbox（App Review 要求每个 main executable 都有）—— 跑 scripts/sign-embedded-tools-mas.sh"
    fi
    if printf '%s\n' "$keys" | grep -qx "com.apple.security.inherit"; then
      pass "${helper} 带 inherit"
    else
      fail "${helper} 缺 inherit —— 本地测不出来，只在审核时暴露"
    fi
    # helper 不该有**额外**权限：它继承父进程，自己再多要就是超范围。
    extra="$(printf '%s\n' "$keys" | grep -v '^com.apple.security.app-sandbox$' \
      | grep -v '^com.apple.security.inherit$' | grep -v '^$' || true)"
    if [ -z "$extra" ]; then
      pass "${helper} 没有多余的权限（只有 app-sandbox + inherit）"
    else
      fail "${helper} 多带了权限：$(printf '%s' "$extra" | tr '\n' ' ')"
    fi
  done
fi

# ─────────────────────────────────────────────────────────────
group "3. 签名身份与分发形态"

IDENTITY="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
IDENTITY="${IDENTITY:-"-"}"
KIND="$(identity_kind "$IDENTITY")"
printf '  身份：%s  (%s)\n' "$IDENTITY" "$KIND"
case "$KIND" in
  apple-distribution)
    pass "'Apple Distribution' 证书 —— 这是唯一能上架的那张" ;;
  developer-id)
    fail "用的是 Developer ID —— 它**能公证、能侧载、本机跑得起来，但上不了 App Store**。要出 MAS 包必须用 Apple Distribution" ;;
  adhoc)
    human "本机 ad-hoc 签名（没有 Apple Distribution 证书）。**只能自测**：顺序与 entitlements 的结论有效，但这个包不能提交" ;;
  *)
    fail "签名身份无法识别：${IDENTITY}" ;;
esac

PROFILE="$APP/Contents/embedded.provisionprofile"
if [ -f "$PROFILE" ]; then
  pass "有 embedded.provisionprofile"
  # 顺手把它的名字与团队打出来 —— 提交时对不上会很难查。
  NAME="$(security cms -D -i "$PROFILE" 2>/dev/null \
    | "$PYTHON" -c '
import plistlib, sys
try:
    d = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    raise SystemExit(0)
print(d.get("Name", ""), d.get("TeamIdentifier", [""])[0] if d.get("TeamIdentifier") else "")
' || true)"
  [ -n "${NAME// /}" ] && printf '      profile：%s\n' "$NAME"
else
  if [ "$KIND" = "apple-distribution" ]; then
    fail "缺 embedded.provisionprofile —— MAS 包必须内嵌 provisioning profile"
  else
    human "没有 embedded.provisionprofile（当前身份下预期如此；用 Apple Distribution 出包时会带上）"
  fi
fi

# ─────────────────────────────────────────────────────────────
group "4. Hardened Runtime 与 Info.plist"

for label in "$APP_NAME:DroidBerth" "$SIDECAR_NAME:$SIDECAR_NAME" "adb:adb"; do
  binary="${label%%:*}"; shown="${label##*:}"
  path="$BIN_DIR/$binary"
  [ -f "$path" ] || continue
  if [ "$(has_runtime "$path")" = "yes" ]; then
    pass "${shown} 带 hardened runtime（flags 的 0x10000 位）"
  else
    fail "${shown} 没有 hardened runtime —— App Store 要求所有可执行文件都开"
  fi
done

INFO="$APP/Contents/Info.plist"
if [ -f "$INFO" ]; then
  category="$(plist_get "$INFO" LSApplicationCategoryType)"
  if [ -n "$category" ]; then pass "LSApplicationCategoryType = ${category}"
  else fail "Info.plist 缺 LSApplicationCategoryType（App Store 要求）"; fi

  copyright="$(plist_get "$INFO" NSHumanReadableCopyright)"
  if [ -n "$copyright" ]; then pass "NSHumanReadableCopyright = ${copyright}"
  else fail "Info.plist 的 NSHumanReadableCopyright 是空的"; fi

  version="$(plist_get "$INFO" CFBundleShortVersionString)"
  if [ -n "$version" ]; then
    if [ -n "$EXPECTED_VERSION" ] && [ "$version" != "$EXPECTED_VERSION" ]; then
      fail "CFBundleShortVersionString = ${version}，与期望的 ${EXPECTED_VERSION} 不一致"
    else
      pass "CFBundleShortVersionString = ${version}"
    fi
  else
    fail "Info.plist 没有 CFBundleShortVersionString"
  fi

  bundle_id="$(plist_get "$INFO" CFBundleIdentifier)"
  printf '  bundle id：%s\n' "$bundle_id"
else
  fail "找不到 Contents/Info.plist"
fi

# ─────────────────────────────────────────────────────────────
group "5. 产物里不该有的东西"

# 绝对路径：本机的家目录一旦进了二进制，换台机器/换用户都可能出问题，而且审核不喜欢。
# 判据用**具体的家目录**（不是笼统的 `/Users/`）—— 后者会把无关字符串也判成问题，
# 而**持续误报等于没有判据**。
if [ -f "$MAIN_BIN" ]; then
  if strings -a "$MAIN_BIN" 2>/dev/null | grep -qF "$HOME"; then
    fail "主可执行文件里出现了本机家目录路径（${HOME}）"
  else
    pass "主可执行文件里没有本机家目录路径"
  fi
fi

# `Contents/Resources` 里不该混进源文件（entitlements / 源码 / 调试符号）。
STRAY="$(find "$APP/Contents/Resources" \( -name '*.entitlements' -o -name '*.swift' -o -name '*.plist' \) 2>/dev/null || true)"
if [ -z "$STRAY" ]; then
  pass "Contents/Resources 里没有误拷进来的源文件 / entitlements"
else
  fail "Contents/Resources 里有不该在的东西：$(printf '%s' "$STRAY" | tr '\n' ' ')"
fi

# ─────────────────────────────────────────────────────────────
group "6. 机器判不了的（这些必须你或法务给结论）"

human "NOTICE.txt 的 §3.5（对开源许可组件的豁免）是否适用 —— **法务**，不是工程"
human "中国大陆上架的额外资质（ICP / 备案等）—— 我没有可靠判据"
human "App Store Connect 元数据：名称 / 副标题 / 关键词 / 描述 / 分类 / 年龄分级"
human "App Store 截图（各尺寸）与审核备注 —— 备注要能解释「为什么一个文件传输 app 内嵌了命令行 adb」"
human "真实 **Android** 设备上的 USB 通路是否跑得通（S1-c）—— 见 docs/1011_04 §6"
human "沙盒下的**人工体验**：容器里 Desktop/Pictures 等读不动、Documents 打开是空的（docs/1011_04 §4.1）"

# ─────────────────────────────────────────────────────────────
printf '\n════ 结论\n'
printf '  PASS %d · FAIL %d · 人工项 %d\n' "$PASSES" "$FAILURES" "$WARNINGS"
if [ "$FAILURES" -gt 0 ]; then
  printf '  \033[31m还不能提交\033[0m —— 先把 FAIL 清零。\n'
  exit 1
fi
if [ "$KIND" != "apple-distribution" ]; then
  printf '  \033[33m结构性检查已过，但签名身份不是 Apple Distribution —— 这个包不能提交。\033[0m\n'
  exit 0
fi
printf '  \033[32m机器能判的都过了\033[0m —— 剩下的看第 6 组。\n'
