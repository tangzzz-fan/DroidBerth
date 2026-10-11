#!/usr/bin/env python3
"""设备端语义的实测（PRD 附录 B #2 / #4，§12.2 / §16 / §19 / §20）。

覆盖：
  A. 文件名合法字符集（§16）—— `mv`（重命名走的路径）与 `adb push`（上传走的路径）分别测
  B. Android/data 与 Android/obb 的写权限边界（§12.2）
  C. 存储卷枚举与可用空间解析（§12.2 / §20，顺带验证 DeviceShell.availableBytes 的字段取法）
  D. 大小写与 Unicode 归一化（§16 的「同名」语义，验证代码里的假设）
  E. 媒体入库三态与 app 的 where 子句（§19）
"""
import os
import shlex
import subprocess
import sys

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
PROBE = "/sdcard/Download/DroidBerthProbe"
DCIM = "/sdcard/DCIM/DroidBerthProbe"
LOCAL = "/tmp/probe/media"


def serial():
    out = subprocess.run([ADB, "devices"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.endswith("\tdevice"):
            return line.split("\t")[0]
    return None


S = serial()
if not S:
    print("!! 没有在线设备")
    sys.exit(1)


def sh(cmd, timeout=30):
    """在设备上跑一条 shell 命令。返回 (code, stdout)。"""
    r = subprocess.run([ADB, "-s", S, "shell", cmd],
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.replace("\r\n", "\n").strip()


def push(local, remote, timeout=60):
    """adb push：远端路径是 argv，不经 shell ⇒ 引号语义与 shell 不同，这本身就是要测的。"""
    r = subprocess.run([ADB, "-s", S, "push", local, remote],
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else ""


def hdr(t):
    print()
    print("=" * 78)
    print(t)
    print("=" * 78)


hdr(f"A. 文件名合法字符集（§16）—— 设备：{S}")
sh(f"mkdir -p {shlex.quote(PROBE)}")

# FAT32 明令禁止的字符 + 一堆在 macOS 上合法、在 Windows/FAT32 上敏感的东西
NAMES = [
    ("a:b.txt",      "冒号（FAT32 禁止）"),
    ("a*b.txt",      "星号（FAT32 禁止）"),
    ("a?b.txt",      "问号（FAT32 禁止）"),
    ('a"b.txt',      "双引号（FAT32 禁止）"),
    ("a<b.txt",      "小于号（FAT32 禁止）"),
    ("a>b.txt",      "大于号（FAT32 禁止）"),
    ("a|b.txt",      "竖线（FAT32 禁止）"),
    ("a\\b.txt",     "反斜杠"),
    ("a'b.txt",      "单引号"),
    ("a`b.txt",      "反引号（shell 元字符）"),
    ("a$b.txt",      "美元号（shell 元字符）"),
    ("a;b.txt",      "分号（shell 元字符）"),
    ("a&b.txt",      "与号（shell 元字符）"),
    ("a b.txt",      "空格"),
    ("a\tb.txt",     "制表符"),
    ("中文名.txt",    "中日韩字符"),
    ("😀emoji.txt",  "emoji（代理对）"),
    (".hidden.txt",  "点前缀（隐藏）"),
    ("-dash.txt",    "前导减号（易被当参数）"),
    ("~tilde.txt",   "波浪号"),
    ("#hash.txt",    "井号"),
    ("%pct.txt",     "百分号"),
    ("(paren).txt",  "圆括号"),
    ("[brack].txt",  "方括号"),
    ("{brace}.txt",  "花括号"),
    ("ABC.TXT",      "全大写扩展名"),
    ("x" * 255 + ".txt", "长度 259（超 255）"),
    ("trailingspace .txt", "扩展名前有空格"),
    ("enddot..txt",  "连续点"),
]

print(f"{'名称':<22} {'说明':<26} {'touch(设备端 mkdir/touch)':<28} {'adb push'}")
print("-" * 110)
rows_a = []
for name, note in NAMES:
    # 设备端建文件：走 mv/重命名同一条 shell 通道
    code, out = sh(f"touch {shlex.quote(PROBE + '/' + name)} 2>&1; echo RC=$?")
    rc_touch = out.split("RC=")[-1].strip() if "RC=" in out else "?"
    # 上传通道：adb push（argv，不经 shell）
    local = f"/tmp/probe/one.txt"
    if not os.path.exists(local):
        open(local, "w").write("x")
    code2, msg = push(local, f"{PROBE}/{name}")
    ok_push = "OK" if code2 == 0 else f"FAIL({code2})"
    rows_a.append((name, rc_touch, ok_push))
    shown = name if len(name) <= 20 else name[:17] + "..."
    print(f"{shown:<22} {note:<26} {('成功 RC=' + rc_touch) if rc_touch == '0' else ('失败 RC=' + rc_touch):<28} {ok_push}")

# 真在设备上列一遍，确认文件确实存在（touch 的 RC=0 不等于文件真有）
code, out = sh(f"find {shlex.quote(PROBE)} -mindepth 1 -maxdepth 1 | wc -l")
print()
print(f"设备端实际文件数：{out}（用 find 独立复核；`ls -a` 的行数在 pty 下不可靠，别拿它数）")
print()
print("被 app 的 validateRemoteName 放行、但设备端实际建不出来的名称：")
sh_ok = {n for n, rc, _ in rows_a if rc == "0"}
push_ok = {n for n, _, p in rows_a if p == "OK"}
blocked = [n for n, _, _ in rows_a if n not in sh_ok]
print(f"  shell(touch/mv) 被拒：{blocked if blocked else '（无）'}")
print(f"  adb push 被拒：{[n for n,_,p in rows_a if p != 'OK'] or '（无）'}")
print(f"  两者不一致的：{sorted(sh_ok ^ push_ok) or '（无）'}")

hdr("B. Android/data 与 Android/obb 的写权限边界（§12.2）")
for path, note in [
    ("/sdcard/Android/data",            "Android/data 根"),
    ("/sdcard/Android/data/com.android.settings", "别人的应用目录"),
    ("/sdcard/Android/obb",             "Android/obb 根"),
    ("/sdcard/Android/media",           "Android/media（共享媒体目录）"),
]:
    code, out = sh(f"ls -d {shlex.quote(path)} 2>&1 | head -1")
    code2, out2 = sh(f"touch {shlex.quote(path + '/probe.tmp')} 2>&1; echo RC=$?")
    code3, out3 = sh(f"rm -f {shlex.quote(path + '/probe.tmp')} 2>/dev/null; echo done")
    writable = "可写 ✓" if out2.endswith("RC=0") else "不可写 ✗"
    print(f"{path:<46} {note:<24} {writable}")
    if not out2.endswith("RC=0"):
        print(f"    错误原文：{out2.splitlines()[0][:90] if out2 else out}")
print()
print(f"shell 用户的补充组：{sh('id')[1].split('=')[-1][:120]}")

hdr("C. 存储卷与可用空间（§12.2 / §20）")
print("--- ls /storage ---")
print(sh("ls -la /storage")[1])
print("--- ls /storage/emulated ---")
print(sh("ls -la /storage/emulated")[1])
print("--- df -h ---")
print(sh("df -h | head -12")[1])
print()
print("--- DeviceShell.availableBytes 解析的就是这条（df -k <path>）---")
raw = sh(f"df -k {shlex.quote('/sdcard')}")[1]
print(raw)
print()
lines = raw.splitlines()
fields = lines[1].split() if len(lines) > 1 else []
print(f"fields = {fields}")
if len(fields) >= 4:
    try:
        avail = int(fields[3]) * 1024
        print(f"app 取 fields[3] = {fields[3]} → {avail:,} 字节 = {avail/1024**3:.2f} GiB  ← 解析正确")
    except ValueError:
        print(f"!! fields[3] = {fields[3]!r} 不是整数 ⇒ app 的 availableBytes 会返回 nil")
else:
    print(f"!! 字段数只有 {len(fields)} ⇒ app 的 availableBytes 会返回 nil（df 换行了？）")
print(f"--- 另一条路径 df -h /sdcard（verify-clean 那类脚本可能用它）---")
print(sh("df -h /sdcard")[1])

hdr("D. 大小写与 Unicode 归一化（§16 的「同名」语义）")
sh(f"mkdir -p {shlex.quote(PROBE)}")
sh(f"rm -f {shlex.quote(PROBE + '/Case*.txt')} {shlex.quote(PROBE + '/nfc*.txt')}")
sh(f"touch {shlex.quote(PROBE + '/Case.txt')}")
code, out = sh(f"test -f {shlex.quote(PROBE + '/case.txt')} && echo 'FOUND' || echo 'NOTFOUND'")
print(f"建了 Case.txt，测 case.txt 是否存在 → {out}   "
      f"（{'不区分大小写（与 macOS 默认卷相同）' if out == 'FOUND' else '区分大小写（ext4/f2fs 语义，与 macOS 默认卷相反）'}）")
# NFC vs NFD：é 的两种编码
nfc = "caf\u00e9.txt"                    # é 单码点
nfd = "cafe\u0301.txt"                   # e + 组合重音
sh(f"touch {shlex.quote(PROBE + '/' + nfc)}")
sh(f"touch {shlex.quote(PROBE + '/' + nfd)}")
code, out = sh(f"ls -1 {shlex.quote(PROBE)} | grep -c '^caf'")
print(f"分别建 NFC 与 NFD 两个 café.txt → 匹配 ^caf 的条数 {out}   "
      f"（{'两个不同文件 ⇒ 设备端不归一化' if out == '2' else '只有一个 ⇒ 被归一化/覆盖，详见 test-semantics2.py 的复核 6'}）")

hdr("E. 媒体入库三态与 app 的 where 子句（§19）")
print(f"--- cmd -l 里的扫描服务（MediaScanner.command 就在这里挑）---")
code, out = sh("cmd -l")
svc = set(out.split())
for cand in ("media_scanner", "media.scan"):
    print(f"  {cand:<16} {'存在 ✓' if cand in svc else '不存在 ✗'}  ⇒ "
          f"{'走 cmd ' + cand if cand in svc else '不采用'}")
print(f"  结论：app 会选 {'scanFile' if 'media_scanner' in svc else ('mediaScan' if 'media.scan' in svc else 'broadcast（兜底）')}")
print(f"  cmd -l 服务总数：{len(svc)}")

for name, dest, note in [
    ("photo.jpg", DCIM, "相机目录（应入库）"),
    ("note.txt",  DCIM, "非媒体（应沉默）"),
    ("photo.png", "/sdcard/Download/DroidBerthProbe", "Download（标准媒体目录）"),
    ("photo.heic", "/sdcard/DroidBerthProbeNoScan", "自建目录（非标准）"),
]:
    sh(f"mkdir -p {shlex.quote(dest)}")
    local = os.path.join(LOCAL, name)
    if name == "note.txt":
        local = "/tmp/probe/one.txt"
        sh(f"printf 'hello' > {shlex.quote(dest + '/' + name)}")
    else:
        push(local, f"{dest}/{name}")
    full = dest + "/" + name

    # 复刻 MediaScanner 的判定：先挑表，再查
    table = {"jpg": "images", "png": "images", "heic": "images"}.get(name.rsplit(".", 1)[-1], None)
    if table is None:
        print(f"{full:<52} {note:<20} 表=nil ⇒ 非媒体（app 保持沉默）")
        continue

    where = f"_data LIKE '%/{name}'"
    cmd = (f"content query --uri content://media/external/{table}/media "
           f"--projection _id:_data --where {shlex.quote(where)}")
    code, out = sh(cmd)
    hit = "查到 ✓ 已入库" if "_data=" in out else "查不到 ✗ 未入库"
    print(f"{full:<52} {note:<20} 表={table} {hit}")

# SQLite 的 LIKE 对 ASCII 不区分大小写 —— 验证 app 的 basename 复核是否真的必要
print()
print("--- LIKE 的大小写语义（决定 app 的「basename 复核」是不是必需品）---")
sh(f"rm -f {shlex.quote(DCIM + '/CaseProbe.jpg')}")
push(os.path.join(LOCAL, "photo.jpg"), f"{DCIM}/CaseProbe.jpg")
sh("sleep 2")
lower_where = "_data LIKE '%/caseprobe.jpg'"
cmd = ("content query --uri content://media/external/images/media --projection _id:_data "
       "--where " + shlex.quote(lower_where))
code, out = sh(cmd)
print(f"设备上只有 CaseProbe.jpg，用小写 caseprobe.jpg 去查（app 的 where 原样）")
print(f"  → {'竟然命中了（LIKE 不区分大小写）⇒ 不做 basename 复核就会张冠李戴' if '_data=' in out else '未命中（LIKE 区分大小写）⇒ 复核是双保险'}")
if "_data=" in out:
    for line in out.splitlines()[:3]:
        print(f"    {line[:100]}")

hdr("清理")
for d in (PROBE, DCIM, "/sdcard/DroidBerthProbeNoScan"):
    sh(f"rm -rf {shlex.quote(d)}")
    code, out = sh(f"ls -d {shlex.quote(d)} 2>/dev/null || echo GONE")
    print(f"{d:<40} {out}")
