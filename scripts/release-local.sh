#!/bin/bash
# 本机发版：构建 → 签名 → 公证 → 打包 → 建 GitHub Release。
#
#   ./scripts/release-local.sh 0.1.0              # 干跑：构建 + 公证 + 打包，**不碰 GitHub**
#   ./scripts/release-local.sh 0.1.0 --publish    # 真发版：打 tag、推 tag、建 Release（会二次确认）
#
# ## 为什么签名不走 CI
#
# Developer ID 私钥一旦放进 GitHub，就是一份**你无法收回的副本** —— 而它能做的不是「读你的数据」，
# 而是**以你的名义签发任何 macOS 都信任的软件**。这个仓库是 public 的，能推 workflow 的人就能把它
# 打出来（Actions 日志也是公开的，secret 掩码只在原样出现时生效，base64 一下就绕过）。
#
# 而本机本来就有全套凭据（证书在钥匙串、公证 profile 或 `.env` 三件套），一条命令 4 分钟跑完。
# **所以签名与公证的凭据一步都不离开这台机器。** CI 只负责验证（`ci.yml`）。
#
# 若将来确实要 CI 签名，加固清单见 README「CI 与发布」一节。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
source "$ROOT/scripts/env.sh"

VERSION=""
PUBLISH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
    -*) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
    *) VERSION="${1#v}"; shift ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "用法：$(basename "${BASH_SOURCE[0]:-$0}") <版本号> [--publish]" >&2
  echo "  例：$(basename "${BASH_SOURCE[0]:-$0}") 0.1.0 --publish" >&2
  exit 2
fi

TAG="v$VERSION"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

# ── 前置检查 ────────────────────────────────────────────────────
require_developer_id || {
  echo
  echo "发版必须用 Developer ID 证书签名 —— Apple Development 只能本机跑，公证会被拒。"
  exit 2
}

if [ "$PUBLISH" = "1" ]; then
  command -v gh >/dev/null 2>&1 || { echo "没有 gh。装一个：brew install gh" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "gh 未登录。先跑：gh auth login" >&2; exit 1; }

  if [ "$(git -C "$ROOT" branch --show-current)" != "main" ]; then
    echo "当前不在 main 上（$(git -C "$ROOT" branch --show-current)）—— 发版请从 main 走。" >&2
    exit 1
  fi
  if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "工作区不干净 —— 先提交，发版要能与 tag 一一对应：" >&2
    git -C "$ROOT" status --short >&2
    exit 1
  fi
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "tag $TAG 已存在。版本号要往前推，别复用一个已经发过的号。" >&2
    exit 1
  fi
  if [ "$(git -C "$ROOT" rev-list --count "origin/main..main" 2>/dev/null || echo 0)" != "0" ]; then
    echo "本地 main 还没推上去 —— 先把提交推了，否则 tag 指向的提交不在远端。" >&2
    exit 1
  fi
fi

echo
echo "版本      : $VERSION"
echo "tag       : $TAG"
echo "build     : $BUILD_NUMBER"
echo "签名身份  : $(detect_identity)"
echo "发布      : $([ "$PUBLISH" = "1" ] && echo '是（会建 GitHub Release）' || echo '否（干跑）')"
echo

# ── 1/5 构建（版本号通过命令行 build setting 注入）─────────────────
# ⚠️ 必须走 XCODEBUILD_ARGS 而**不是**环境变量：实测 xcodebuild 不把环境变量当 build setting，
#    `MARKETING_VERSION=9.9.9 xcodebuild …` 产出的 Info.plist 仍是 project.yml 里的值。
echo "==> 1/6 构建"
XCODEBUILD_ARGS="MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
  "$ROOT/scripts/build.sh"

# ── 2/5 回归守卫（发版前的最低门槛）───────────────────────────────
echo
echo "==> 2/6 回归守卫"
"$ROOT/scripts/check-all.sh"

# ── 3/5 公证 ────────────────────────────────────────────────────
echo
echo "==> 3/6 公证（app + DMG）"
"$ROOT/scripts/notarize.sh"

# ── 4/5 验证票据与 Gatekeeper ────────────────────────────────────
echo
echo "==> 4/6 验证"
xcrun stapler validate "$APP_PATH"
xcrun stapler validate "$DMG_DIR/$APP_NAME.dmg"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "── 嵌套二进制的身份与 hardened runtime ──"
for bin in "$APP_PATH/Contents/MacOS"/*; do
  [ -f "$bin" ] || continue
  printf '  %-18s ' "$(basename "$bin")"
  codesign -dv "$bin" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\).*/\1/p' | tr -d '\n'
  printf '  '
  codesign -dv "$bin" 2>&1 | sed -n 's/^TeamIdentifier=//p'
done
# 权威判据是 `spctl -a -vvv`；`--assess -t open`（不带 --context）会误报 Insufficient Context。
SPCTL="$(spctl -a -vvv "$APP_PATH" 2>&1 || true)"
echo "── Gatekeeper ──"
echo "$SPCTL" | sed 's/^/  /'
case "$SPCTL" in
  *rejected*) echo "Gatekeeper 拒绝了产物，停止。" >&2; exit 1 ;;
  *Notarized*) ;;
  *) echo "warn: spctl 的措辞不是预期的 'Notarized'，请人工看上面的输出" >&2 ;;
esac
# 版本号真的进去了吗（防止 App 里显示的还是 project.yml 的默认值）
echo "── 版本号 ──"
printf '  CFBundleShortVersionString = %s\n' \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"

# ── 5/5 打包 ────────────────────────────────────────────────────
echo
echo "==> 5/6 打包"
"$ROOT/scripts/package-release.sh" "$VERSION"

# ── 6/6 发布前闸门（PRD §28 的可执行版本）─────────────────────────
# 放在打包**之后**：它要连 dist/ 里的附件（校验和、票据、zip 里的垃圾项）一起判。
# FAIL 就打住 —— 交到用户手上的东西不该带着已知不达标项。
echo
echo "==> 6/6 发布前闸门"
"$ROOT/scripts/check-release.sh" "$VERSION"

if [ "$PUBLISH" != "1" ]; then
  echo
  echo "干跑完成（没有碰 GitHub）。产物在 $ROOT/dist/。"
  echo "确认无误后加 --publish 真发版。"
  exit 0
fi

# ── 发布（不可逆，二次确认）──────────────────────────────────────
echo
echo "即将执行（这一步是对外动作，删掉 Release 也不能保证没人下载过）："
echo "  git tag $TAG && git push origin $TAG"
echo "  gh release create $TAG --title \"DroidBerth $TAG\" --notes-file dist/RELEASE-NOTES.md --generate-notes dist/*"
echo
printf '继续？输入 yes 确认：'
read -r reply
[ "$reply" = "yes" ] || { echo "已取消。产物仍在 $ROOT/dist/。"; exit 0; }

git -C "$ROOT" tag "$TAG"
git -C "$ROOT" push origin "$TAG"

# 说明文字写在自动生成的变更清单**之前**（REST API 的 body + generate_release_notes 就是这个语义）。
gh release create "$TAG" \
  --title "DroidBerth $TAG" \
  --notes-file "$ROOT/dist/RELEASE-NOTES.md" \
  --generate-notes \
  --verify-tag \
  "$ROOT"/dist/*

echo
echo "已发布：$(gh release view "$TAG" --json url --jq .url 2>/dev/null || echo "https://github.com/tangzzz-fan/DroidBerth/releases/tag/$TAG")"
