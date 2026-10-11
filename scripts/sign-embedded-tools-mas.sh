#!/bin/bash
# MAS 版的内嵌可执行文件重签 —— PRD §4 E4。
#
# 为什么需要单独一个脚本：`project.yml` 里 `Sidecar/*` 的两个文件带 `CodeSignOnCopy`，
# Xcode 会用 **app 的 identity** 签它们，但**不带任何 entitlements**（这个是实测确认的：
# 沙盒版包里的 `droidberth-adb` / `adb` 各 0 条）。而 App Review 要求**每一个 main
# executable** 都带 `com.apple.security.app-sandbox`，于是那两个必须由这里补签一次。
#
# 签名顺序**必须由内向外**（helper → app）：外层 app 的签名封装覆盖内层文件的内容与签名，
# 反过来做，最后签 helper 会把 app 已经打好的封装弄坏，`codesign --verify` 才会报出来。
#
# 用法：
#   ./scripts/sign-embedded-tools-mas.sh                    # 签 $APP_PATH（看 CONFIGURATION）
#   CONFIGURATION=Release-MAS ./scripts/sign-embedded-tools-mas.sh
#   ./scripts/sign-embedded-tools-mas.sh <path/to/DroidBerth.app>
#
# ⚠️ 本脚本**不检查**签名身份是不是 Apple Distribution（那是 `check-mas-readiness.sh` 的事）。
#    身份缺失时它会退到 ad-hoc 并**大声说明** —— 这样在没有证书的机器上也能把
#    「顺序对不对、entitlements 落没落上」验掉，而不必先办证书。
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

APP="${1:-$APP_PATH}"
APP_ENTITLEMENTS="$ROOT/macos/Resources/DroidBerth-MAS.entitlements"
HELPER_ENTITLEMENTS="$ROOT/macos/Resources/Helper-MAS.entitlements"
# 内嵌的两个 helper。**成对地与 `project.yml` 的 `Sidecar/*` 保持一致** ——
# 这里少写一个，那个文件就会被静默地按「无 entitlements」留在包里。
HELPERS=("$SIDECAR_NAME" "adb")

if [ ! -d "$APP" ]; then
  echo "找不到 app bundle：$APP" >&2
  echo "  先构建：CONFIGURATION=Release-MAS ./scripts/build.sh" >&2
  exit 1
fi
for plist_file in "$APP_ENTITLEMENTS" "$HELPER_ENTITLEMENTS"; do
  [ -f "$plist_file" ] || { echo "缺少 ${plist_file}" >&2; exit 1; }
  plutil -lint "$plist_file" >/dev/null || { echo "${plist_file} 不是合法 plist" >&2; exit 1; }
done

IDENTITY="$(detect_mas_identity)"
IDENTITY_KIND="$(identity_kind "$IDENTITY")"
export APPLE_SIGNING_IDENTITY="$IDENTITY"

echo "══ MAS 版内嵌工具重签"
echo "   app          : $APP"
echo "   身份         : $IDENTITY  ($IDENTITY_KIND)"
echo "   app 权限     : ${APP_ENTITLEMENTS#"$ROOT"/}"
echo "   helper 权限  : ${HELPER_ENTITLEMENTS#"$ROOT"/}"
echo

if [ "$IDENTITY_KIND" = "adhoc" ]; then
  echo "⚠️  没有找到 'Apple Distribution' 证书，本次用 **ad-hoc** 签名。"
  echo "    这样的包**只能本机自测** —— 不能上架、也不该分发。"
  echo "    （本脚本仍会把顺序与 entitlements 落位验清楚，这部分与真身份无关。）"
  echo
fi

# ── 内嵌可执行文件必须**恰好**是这两个 ────────────────────────────────────
# 不写成「遍历 Contents/MacOS 全签一遍」：那样多出来的第三个可执行文件会被
# 悄悄签成不带 entitlements 的样子，然后只在审核时暴露。这里宁可先数清楚。
BIN_DIR="$APP/Contents/MacOS"
EXPECTED=$(( ${#HELPERS[@]} + 1 ))   # +1 = app 自己
ACTUAL=0
for entry in "$BIN_DIR"/*; do
  [ -f "$entry" ] || continue
  ACTUAL=$((ACTUAL + 1))
done
if [ "$ACTUAL" -ne "$EXPECTED" ]; then
  echo "Contents/MacOS 下有 ${ACTUAL} 个文件，预期 ${EXPECTED} 个（app 自己 + ${#HELPERS[@]} 个 helper）。" >&2
  echo "多出来的那个会被按「无 entitlements」留在包里，审核会因此打回。" >&2
  ls -1 "$BIN_DIR" | sed 's/^/    /' >&2
  exit 1
fi
if [ ! -f "$BIN_DIR/$APP_NAME" ]; then
  echo "Contents/MacOS 里没有主可执行文件 $APP_NAME —— 这个 bundle 不完整" >&2
  exit 1
fi
# 嵌套 bundle 也一起数一下：现在一个都没有，将来若加了（比如一个 .app 插件），
# 它们同样需要各自的 entitlements，而本脚本并不处理 —— 宁可在这里停住。
NESTED="$(find "$APP/Contents" \( -name '*.app' -o -name '*.framework' \) 2>/dev/null || true)"
if [ -n "$NESTED" ]; then
  echo "包里出现了嵌套 bundle，本脚本不处理它们的 entitlements：" >&2
  printf '%s\n' "$NESTED" | sed 's/^/    /' >&2
  exit 1
fi

# ad-hoc 身份没有时间戳服务器可问 —— `--timestamp` 会卡住/失败，所以按身份决定加不加。
# 展开空数组必须写成 `"${ARR[@]+"${ARR[@]}"}"`：bash 3.2 在 `set -u` 下会把
# 空数组的 `"${ARR[@]}"` 判为 unbound variable（本项目已栽过一次，见 build.sh）。
TIMESTAMP_ARGS=(--timestamp)
[ "$IDENTITY" = "-" ] && TIMESTAMP_ARGS=()

sign() {
  local target="$1" entitlements="$2"
  codesign --force --options=runtime \
    "${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"}" \
    --entitlements "$entitlements" \
    --sign "$IDENTITY" "$target"
}

echo "==> 1) helper（各带 app-sandbox + inherit）"
for helper in "${HELPERS[@]}"; do
  path="$BIN_DIR/$helper"
  if [ ! -f "$path" ]; then
    echo "  找不到内嵌的 ${helper} —— 先跑 ./scripts/build.sh（它负责暂存 sidecar）" >&2
    exit 1
  fi
  sign "$path" "$HELPER_ENTITLEMENTS"
  printf '  %s\n' "$helper"
done

echo
echo "==> 2) 外层 app（带沙盒权限集）"
sign "$APP" "$APP_ENTITLEMENTS"
printf '  %s\n' "$APP_NAME"

echo
echo "==> 3) codesign --verify --deep --strict"
if codesign --verify --deep --strict --verbose=2 "$APP"; then
  echo "    OK"
else
  echo "    失败 —— 多半是签名顺序或 entitlements 出了岔子" >&2
  exit 1
fi

echo
echo "==> 4) 落位复核（每个 Mach-O 的 entitlements）"
for helper in "${HELPERS[@]}"; do
  count="$(codesign -d --entitlements - "$BIN_DIR/$helper" 2>/dev/null \
    | grep -c 'com.apple.security' || true)"
  printf '  %-16s %s 条 com.apple.security\n' "$helper" "$count"
done
app_count="$(codesign -d --entitlements - "$APP" 2>/dev/null \
  | grep -c 'com.apple.security' || true)"
printf '  %-16s %s 条 com.apple.security\n' "$APP_NAME" "$app_count"

echo
echo "next: CONFIGURATION=Release-MAS ./scripts/check-mas-readiness.sh"
