#!/bin/bash
# 取 Android platform-tools 里的 adb：**钉版本 + 校验 sha256**。
#
# ## 为什么需要它
#
# `.gitignore` 里写明 `vendor/` **不随仓库分发**（体积大 + 许可待确认，PRD §28），
# 于是新克隆的仓库**没有任何获取 adb 的途径** —— 本地跑不起来，CI 更跑不起来。
# 这个脚本就是那条缺失的路径，本地与 CI 共用。
#
# ## 为什么钉版本，而不是用 `-latest`
#
# adb 的版本不一致会**静默改变行为**（`doctor` 的 `adb.port_5037` 那项就是为它存在的）。
# 项目里所有验证记录都对着 **37.0.1-15733141** 这一版做的，所以这里把它写死。
#
# ## 两道校验和分别防什么
#
# - **zip 的 sha256**：证明拿到的是**那一版**官方包，不是被替换/损坏的东西。
# - **解出来的 adb 的 sha256**：证明包里的可执行文件**就是我们测过的那一个**。
#   实测这两个值与我们本机已测的 adb 完全对得上（见下）。
#
# ⚠️ Google 若重新打包同一版本，zip 校验会失败并**明确报错**——那是**故意**的：
#    宁可让人来看一眼，也不要静默换掉一个我们没测过的 adb。更新 pin 前先跑一遍
#    设备端验收（`docs/1011_01_device-acceptance-report.md`）。
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/env.sh"

VERSION="37.0.1"
BUILD="15733141"
ZIP_URL="https://dl.google.com/android/repository/platform-tools_r${VERSION}-darwin.zip"
ZIP_SHA256="ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d"
ADB_SHA256="1811e253b21b12cbfda7201ebaf86c10e7ddcb5c606a7a81f7c82b4c429c2d3b"

DEST="$ROOT/vendor/platform-tools"

digest() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

# ── 已经就绪就直接返回（幂等：CI 缓存 / 重复调用都走这条） ──────────────
if [ -x "$DEST/adb" ] && [ "$(digest "$DEST/adb")" = "$ADB_SHA256" ]; then
  echo "adb 已就绪（version ${VERSION}-${BUILD}），跳过下载。"
  exit 0
fi

echo "==> 取 platform-tools r${VERSION}（Google 官方源）"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# `--fail` 很关键：不加的话 404 会安静地存下一个 HTML 错误页，后面才以「zip 坏了」的样子炸出来。
curl --fail --location --silent --show-error --retry 3 --retry-delay 2 --max-time 300 \
  -o "$WORK/platform-tools.zip" "$ZIP_URL"

actual_zip="$(digest "$WORK/platform-tools.zip")"
if [ "$actual_zip" != "$ZIP_SHA256" ]; then
  cat >&2 <<EOF

platform-tools 的 zip 校验和不符，**已中止**。

  期望（记录在脚本里）：$ZIP_SHA256
  实际（刚下载到的）  ：$actual_zip
  来源                ：$ZIP_URL

可能的原因与处置：
  1. Google 重新打包了同一版本 —— 先人工核对 `$ZIP_URL` 的内容，
     跑一遍设备端验收，确认无误后再更新本脚本里的 ZIP_SHA256 / ADB_SHA256。
  2. 下载被中间层改过 —— 换网络重试，**不要**直接改校验和放行。

EOF
  exit 1
fi

echo "    zip 校验通过"
unzip -q "$WORK/platform-tools.zip" -d "$WORK"

STAGED="$WORK/platform-tools"
[ -x "$STAGED/adb" ] || { echo "官方包里没有可执行的 adb（$STAGED/adb）" >&2; exit 1; }

actual_adb="$(digest "$STAGED/adb")"
if [ "$actual_adb" != "$ADB_SHA256" ]; then
  cat >&2 <<EOF

解出来的 adb 校验和不符，**已中止**。

  期望（本项目测过的那一份）：$ADB_SHA256
  实际                        ：$actual_adb

这意味着官方包换了 adb。本项目所有设备端验收结论都是对着旧那一份做的
（`docs/1011_01_device-acceptance-report.md`），换版本前需要重新验收。

EOF
  exit 1
fi

echo "    adb 校验通过"

# ── 落到 vendor/（保留 NOTICE.txt 与 source.properties：分发 adb 时的许可要求） ──
mkdir -p "$DEST"
for item in "$STAGED"/*; do
  name="$(basename "$item")"
  rm -rf "$DEST/$name"
  cp -R "$item" "$DEST/$name"
done

echo
echo "vendor/platform-tools/ 就绪："
echo "  adb            $("$DEST/adb" version 2>&1 | sed -n 2p)"
echo "  NOTICE.txt     $( [ -f "$DEST/NOTICE.txt" ] && echo 有 || echo '**缺失**（分发前要处理）' )"
echo
echo "注：vendor/ 被 .gitignore 排除是**刻意**的（体积 + 许可待确认，PRD §28），"
echo "    所以这一步不进版本库 —— CI 每次构建都重跑本脚本。"
