#!/bin/bash
# 把**已构建 + 已签名 + 已公证**的产物收成一个可直接发布的 dist/。
#
#   ./scripts/package-release.sh 0.1.0 [输出目录]
#
# 本机发版（scripts/release-local.sh）与 CI（.github/workflows/release.yml）**共用这一份** ——
# 打包规则与 Release 说明只写一遍，否则两条路产出的附件迟早会不一样。
#
# 产出：
#   DroidBerth-<版本>.dmg      已签名 + 已公证 + 已 staple（内含 /Applications 软链）
#   DroidBerth-<版本>.zip      同一份 app
#   NOTICE.txt                adb 的 Apache-2.0 声明（PRD §28 要求随包分发）
#   SHA256SUMS.txt            上面几个的校验和（**裸文件名**，下载后可直接 -c）
#   RELEASE-NOTES.md           Release 说明（下载 / 安装 / 校验），供 gh --notes-file 用
#
# 源码快照（zip / tar.gz）不在这里 —— GitHub 对每个 Release **自动附带**。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
source "$ROOT/scripts/env.sh"

VERSION="${1:-${APP_VERSION:-}}"
OUT="${2:-$ROOT/dist}"

if [ -z "$VERSION" ]; then
  echo "用法：$(basename "${BASH_SOURCE[0]:-$0}") <版本号> [输出目录]" >&2
  exit 2
fi
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac

[ -d "$APP_PATH" ] || { echo "没有 app 产物：$APP_PATH" >&2; echo "先跑 ./scripts/build.sh" >&2; exit 1; }
DMG="$DMG_DIR/$APP_NAME.dmg"
[ -f "$DMG" ] || { echo "没有 DMG：$DMG" >&2; echo "先跑 ./scripts/notarize.sh" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> DMG"
cp "$DMG" "$OUT/$APP_NAME-$VERSION.dmg"
printf '    %s  (%s)\n' "$APP_NAME-$VERSION.dmg" "$(du -h "$OUT/$APP_NAME-$VERSION.dmg" | cut -f1)"

echo "==> app zip"
# 用 `zip -X -y` 而**不是** Apple 文档推荐的 `ditto -c -k`：源文件带 `com.apple.provenance` 时
# ditto 会给每个成员写一个同目录的 `._<名字>` AppleDouble 边车（实测现成的 app 里 13 个，
# 连 `._CodeResources` 都有，在 Windows / Linux 上解压就是一堆垃圾）；`--norsrc --noextattr`
# 也拦不住，先 `xattr -cr` 更拦不住（ditto 自己会再打上 provenance）。`zip -X` 得到 0 个。
# `-y` 让软链仍以软链存储。去扩展属性**不破坏签名**：实测解压后
# `codesign --verify --deep --strict` / `stapler validate` / `spctl -a -vvv` 三项全过。
( cd "$(dirname "$APP_PATH")" && /usr/bin/zip -q -r -X -y "$OUT/$APP_NAME-$VERSION.zip" "$(basename "$APP_PATH")" )
printf '    %s  (%s)\n' "$APP_NAME-$VERSION.zip" "$(du -h "$OUT/$APP_NAME-$VERSION.zip" | cut -f1)"

echo "==> NOTICE.txt"
# adb（Android platform-tools）的 Apache-2.0 声明。它本来就在 app 包里
# （`Contents/Resources/NOTICE.txt`），这里再单独挂一份 —— 免得要先下 DMG 才看得到许可。
NOTICE="${DROIDBERTH_NOTICE:-}"
[ -n "$NOTICE" ] && [ -f "$NOTICE" ] || {
  for candidate in "$ROOT/vendor/platform-tools/NOTICE.txt" "$SWIFT_DIR/Resources/NOTICE.txt"; do
    if [ -f "$candidate" ]; then NOTICE="$candidate"; break; fi
  done
}
if [ -n "$NOTICE" ]; then
  cp "$NOTICE" "$OUT/NOTICE.txt"
  echo "    NOTICE.txt  ← ${NOTICE#"$ROOT"/}"
else
  echo "    warn: 找不到 NOTICE.txt —— PRD §28 要求随包分发，请先跑 ./scripts/fetch-adb.sh" >&2
fi

echo "==> 仓库自身的许可 / 变更记录（有就一起挂）"
# ⚠️ 逐个 if 而不是 `[ -f x ] && cp` —— 后者在 `set -e` 下测试为假会让整步非零退出。
# 也刻意**不**把 NOTICE 放进这个列表：上面那份就是 NOTICE.txt，会互相覆盖。
for extra in LICENSE LICENSE.txt CHANGELOG.md; do
  if [ -f "$ROOT/$extra" ]; then
    cp "$ROOT/$extra" "$OUT/"
    echo "    $extra"
  fi
done

echo "==> 校验和"
# 用**裸文件名**（在 OUT 里生成），这样用户下载后直接 `shasum -a 256 -c SHA256SUMS.txt` 就能验，
# 不必假设任何目录结构。未命中的通配符会原样传给 shasum 并报错，所以先逐个筛。
(
  cd "$OUT"
  files=()
  for f in ./*.dmg ./*.zip ./NOTICE.txt ./LICENSE ./LICENSE.txt ./CHANGELOG.md; do
    if [ -f "$f" ]; then files+=("$f"); fi
  done
  shasum -a 256 "${files[@]}" > SHA256SUMS.txt
)

echo "==> Release 说明"
cat > "$OUT/RELEASE-NOTES.md" <<'TPL'
## 下载

| 文件 | 说明 |
| --- | --- |
| **`DroidBerth-__VERSION__.dmg`** | **推荐**。已签名 + 已公证 + 已 staple。打开后把 DroidBerth 拖进左边的「应用程序」即可 |
| `DroidBerth-__VERSION__.zip` | 同一份 app 的压缩包；习惯直接拖 app 的人用这个 |
| `NOTICE.txt` | `adb`（Android platform-tools）的 Apache-2.0 声明。它也在 app 包内（`Contents/Resources/NOTICE.txt`） |
| `SHA256SUMS.txt` | 上面各文件的 SHA-256 |
| Source code (zip / tar.gz) | GitHub 自动附带的源码快照 |

**需要 Apple Silicon（M 系列）**，macOS 14 或更高。本项目不发 Intel 版本。

## 安装

1. 打开 `DroidBerth-__VERSION__.dmg`
2. 把 **DroidBerth** 拖到左边的 **Applications**
3. 直接打开即可 —— 包已公证，不需要「右键 → 打开」绕过 Gatekeeper

## 校验（可选）

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## 内容
TPL
# 说明文字用引号 heredoc（不展开），否则 markdown 的反引号会被当成命令替换；版本号用占位符代进去。
sed "s/__VERSION__/$VERSION/g" "$OUT/RELEASE-NOTES.md" > "$OUT/RELEASE-NOTES.md.tmp"
mv "$OUT/RELEASE-NOTES.md.tmp" "$OUT/RELEASE-NOTES.md"

echo
ls -lh "$OUT" | tail -n +2
echo
cat "$OUT/SHA256SUMS.txt"
