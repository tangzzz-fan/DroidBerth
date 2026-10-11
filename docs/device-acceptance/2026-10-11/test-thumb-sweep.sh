#!/bin/bash
# 远端缩略图的「取头大小 → 成功率」曲线。
#
# 目的：把失败机制分离清楚。
#   - 若 faststart mp4（moov 在头）在更大取头量下**成功**，说明失败的真因是
#     「mdat 字节数不足」，而不是「moov 位置」—— PRD §13.3 的预言只对了一半。
#   - 若始终失败，说明 QL 对截断的 ISO-BMFF 一律拒绝，加字节数没用。
set -u

ADB=~/Library/Android/sdk/platform-tools/adb
MEDIA=/tmp/probe/media
PROBE=/tmp/probe/qlprobe
REMOTE=/sdcard/DCIM/DroidBerthProbeSweep
TMP=/tmp/probe/sweep

S=$("$ADB" devices | awk '/\tdevice$/{print $1; exit}')
[ -z "$S" ] && { echo "!! 没有在线设备"; exit 1; }
rm -rf "$TMP"; mkdir -p "$TMP"

"$ADB" -s "$S" shell "mkdir -p $REMOTE"
"$ADB" -s "$S" push "$MEDIA/." "$REMOTE/" >/dev/null 2>&1

SIZES="64 128 256 512 1024 4096"
FILES="photo.jpg photo.png photo.heic photo.gif photo.tiff video-faststart.mp4 video-moovlast.mp4 video.mov"

echo "设备：$S   远端目录：$REMOTE"
echo
echo "注意：每个变体存在各自的子目录里，文件名**保持原扩展名** ——"
echo "QLThumbnailGenerator 是按扩展名挑缩略图器的，改成 .64k 之类的后缀它直接放弃"
echo "（这个坑我踩了一次，也正是 app 的 makeThumbnailScratchFile 保留原名的原因）。"
echo
printf "%-22s" "文件"
for kb in $SIZES; do printf "%10s" "${kb}KB"; done
printf "%10s\n" "完整"
printf '%.0s-' {1..100}; echo

for f in $FILES; do
    printf "%-22s" "$f"
    for kb in $SIZES; do
        mkdir -p "$TMP/s$kb"
        out="$TMP/s$kb/$f"
        "$ADB" -s "$S" exec-out "dd if='$REMOTE/$f' bs=1024 count=$kb 2>/dev/null" > "$out" 2>/dev/null
        if "$PROBE" "$out" >/dev/null 2>&1; then printf "%10s" "OK"; else printf "%10s" "—"; fi
    done
    mkdir -p "$TMP/full"
    full="$TMP/full/$f"
    "$ADB" -s "$S" pull "$REMOTE/$f" "$full" >/dev/null 2>&1
    if "$PROBE" "$full" >/dev/null 2>&1; then printf "%10s\n" "OK"; else printf "%10s\n" "—"; fi
done

echo
echo "OK = QLThumbnailGenerator 能出图；— = 出不了（app 会回退类型图标）"
echo
echo "=== 对照：完整文件一律 OK ⇒ 失败必然与「取回来的字节数」有关 ==="
echo
echo "=== 远端文件大小（判读用）==="
"$ADB" -s "$S" shell "ls -l $REMOTE" | awk 'NR>1{printf "  %-24s %s\n", $NF, $5}'

"$ADB" -s "$S" shell "rm -rf $REMOTE" >/dev/null 2>&1
echo "(已清理远端)"
