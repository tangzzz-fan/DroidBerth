#!/bin/bash
# 远端缩略图成品率（PRD §13.3 的未验证项）
#
# 复刻 DeviceShell.fetchHeader + ThumbnailStore.startRemote 的真实路径：
#   adb -s <serial> exec-out "dd if='<远端路径>' bs=1024 count=64 2>/dev/null"
#   → 落成【原文件名】的本地临时文件 → QLThumbnailGenerator
# 对照组：同一个文件的【完整】拉取，用同一个 QL 探针判定。
#
# 判据：完整文件能出缩略图但 64 KB 头出不了 ⇒ 该类型的远端缩略图必然回退类型图标。
set -u

ADB=~/Library/Android/sdk/platform-tools/adb
MEDIA=/tmp/probe/media
HDR=/tmp/probe/headers
FULL=/tmp/probe/full
PROBE=/tmp/probe/qlprobe
REMOTE=/sdcard/DCIM/DroidBerthProbe

S=$("$ADB" devices | awk '/\tdevice$/{print $1; exit}')
[ -z "$S" ] && { echo "!! 没有在线设备"; exit 1; }
echo "设备：$S"
echo

rm -rf "$HDR" "$FULL"; mkdir -p "$HDR" "$FULL"

echo "=== 1. 建目录并推送素材 ==="
"$ADB" -s "$S" shell "mkdir -p $REMOTE" || exit 1
"$ADB" -s "$S" push "$MEDIA/." "$REMOTE/" 2>&1 | tail -2
echo
echo "远端实际内容："
"$ADB" -s "$S" shell "ls -l $REMOTE" | tail -12
echo

echo "=== 2. 逐文件：只取 64 KB 头 → QL 判定；再完整拉取做对照 ==="
printf "%-22s %10s %8s %9s  %-34s %s\n" "文件" "远端(B)" "取头(B)" "耗时(ms)" "64KB 头的结果" "完整文件的结果"
printf '%.0s-' {1..110}; echo

TOTAL=0; HDR_OK=0; FULL_OK=0
for f in "$MEDIA"/*; do
    name=$(basename "$f")

    remote_size=$("$ADB" -s "$S" shell "stat -c %s '$REMOTE/$name' 2>/dev/null" | tr -d '\r')
    [ -z "$remote_size" ] && remote_size=$("$ADB" -s "$S" shell "wc -c < '$REMOTE/$name'" | tr -d '\r ')

    t0=$(/usr/bin/python3 -c 'import time;print(int(time.time()*1000))')
    "$ADB" -s "$S" exec-out "dd if='$REMOTE/$name' bs=1024 count=64 2>/dev/null" > "$HDR/$name" 2>/dev/null
    t1=$(/usr/bin/python3 -c 'import time;print(int(time.time()*1000))')

    "$ADB" -s "$S" pull "$REMOTE/$name" "$FULL/$name" >/dev/null 2>&1

    hdr_size=$(stat -f %z "$HDR/$name" 2>/dev/null || echo 0)
    hdr_res=$("$PROBE" "$HDR/$name" 2>&1 | head -1)
    full_res=$("$PROBE" "$FULL/$name" 2>&1 | head -1)

    TOTAL=$((TOTAL+1))
    case "$hdr_res"  in OK*) HDR_OK=$((HDR_OK+1));;  esac
    case "$full_res" in OK*) FULL_OK=$((FULL_OK+1));; esac

    printf "%-22s %10s %8s %9s  %-34s %s\n" "$name" "$remote_size" "$hdr_size" "$((t1-t0))" \
        "$(echo "$hdr_res" | cut -c1-34)" "$(echo "$full_res" | cut -c1-34)"
done

echo
echo "=== 3. 结论 ==="
echo "远端缩略图成品率 = $HDR_OK / $TOTAL"
echo "（对照：完整文件成品率 = $FULL_OK / $TOTAL —— 若这条不是满分，说明失败与截断无关，要另查）"
echo
echo "=== 4. 清理设备上的测试素材 ==="
"$ADB" -s "$S" shell "rm -rf $REMOTE && echo removed" | tr -d '\r'
"$ADB" -s "$S" shell "ls -d $REMOTE 2>/dev/null || echo '(已删除)'" | tr -d '\r'
