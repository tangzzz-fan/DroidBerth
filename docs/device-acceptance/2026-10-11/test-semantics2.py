#!/usr/bin/env python3
"""对第一轮结果做聚焦复核 —— 只查「结论可能不成立」的那几处。

上一轮留下的三个疑点：
  1. 一批 FAT32 非法字符在设备端被拒 —— 但没拿到错误原文，无法区分
     「文件系统拒绝」还是「我的命令写错了」
  2. D 段的 NFC/NFD 用了错误的 grep 模式（grep -c cafe 恒为 0，因 café 里没有 "e"）
  3. B 段挑的 com.android.settings 外部目录根本不存在（错误是 No such file
     而不是 Permission denied）⇒ 那段结论不成立
"""
import os
import shlex
import subprocess
import sys

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
PROBE = "/sdcard/Download/DroidBerthProbe2"


def serial():
    out = subprocess.run([ADB, "devices"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.endswith("\tdevice"):
            return line.split("\t")[0]
    return None


S = serial()
if not S:
    sys.exit("!! 没有在线设备")


def sh(cmd, timeout=30):
    r = subprocess.run([ADB, "-s", S, "shell", cmd], capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.replace("\r\n", "\n").strip(), r.stderr.replace("\r\n", "\n").strip()


def push(local, remote):
    r = subprocess.run([ADB, "-s", S, "push", local, remote], capture_output=True, text=True, timeout=60)
    return r.returncode, (r.stdout + r.stderr).strip()


def hdr(t):
    print()
    print("=" * 78)
    print(t)
    print("=" * 78)


sh(f"mkdir -p {shlex.quote(PROBE)}")
open("/tmp/probe/one.txt", "w").write("x")
LOCAL_ONE = "/tmp/probe/one.txt"

hdr("复核 1：被拒名称的**错误原文**（区分文件系统拒绝 vs 命令写错）")
CASES = ["a:b.txt", "a*b.txt", "a?b.txt", 'a"b.txt', "a<b.txt", "a>b.txt",
         "a|b.txt", "a\\b.txt", "a\tb.txt"]
for name in CASES:
    target = PROBE + "/" + name
    # 设备端 touch：stderr 单独取，不吞
    rc, out, err = sh(f"touch {shlex.quote(target)}")
    exists = sh(f"test -e {shlex.quote(target)} && echo YES || echo NO")[1]
    # adb push：远端路径经 argv
    rc2, msg2 = push(LOCAL_ONE, target)
    exists2 = sh(f"test -e {shlex.quote(target)} && echo YES || echo NO")[1]
    errline = (err.strip().splitlines() or [out.strip().splitlines() or [""]])[0][:78]
    print(f"{name!r:<12} touch rc={rc} 存在={exists}  err={errline}")
    print(f"{'':<12} push  rc={rc2} 存在={exists2}  msg={msg2.splitlines()[-1][:78] if msg2 else ''}")

hdr("复核 2：上一轮「设备端实际文件数」对不上的 2 个文件是谁")
EXPECTED_REJECTED = {"a:b.txt", "a*b.txt", "a?b.txt", 'a"b.txt', "a<b.txt", "a>b.txt",
                     "a|b.txt", "a\\b.txt", "a\tb.txt", "x" * 255 + ".txt"}
ALL = ["a:b.txt", "a*b.txt", "a?b.txt", 'a"b.txt', "a<b.txt", "a>b.txt", "a|b.txt",
       "a\\b.txt", "a'b.txt", "a`b.txt", "a$b.txt", "a;b.txt", "a&b.txt", "a b.txt",
       "a\tb.txt", "中文名.txt", "😀emoji.txt", ".hidden.txt", "-dash.txt", "~tilde.txt",
       "#hash.txt", "%pct.txt", "(paren).txt", "[brack].txt", "{brace}.txt", "ABC.TXT",
       "x" * 255 + ".txt", "trailingspace .txt", "enddot..txt"]
print(f"预期被拒 {len(EXPECTED_REJECTED)} 个，预期成功 {len(ALL) - len(EXPECTED_REJECTED)} 个")
print()
for name in ALL:
    t = PROBE + "/" + name
    rc, out, err = sh(f"touch {shlex.quote(t)}")
    ok = sh(f"test -e {shlex.quote(t)} && echo YES || echo NO")[1]
    exp = "拒" if name in EXPECTED_REJECTED else "成"
    got = "存" if ok == "YES" else "无"
    flag = "" if (exp == "拒") == (got == "无") else "   <<< 与预期不符"
    if flag:
        print(f"  {name[:40]!r:<44} 预期={exp} 实际={got}{flag}")
print("（上面没输出 = 全部与预期一致）")
code, out, err = sh(f"ls -a {shlex.quote(PROBE)} | wc -l")
print(f"设备端条目数（含 . 与 ..）：{out}")

hdr("复核 3：字符数 vs 字节数（app 用 name.count 判 255，设备用字节）")
BYTE_CASES = [
    ("中" * 100 + ".txt", "100 个 CJK（300 字节）"),
    ("中" * 80 + ".txt",  "80 个 CJK（240 字节）"),
    ("😀" * 200 + ".txt", "200 个 emoji（800 字节）"),
    ("x" * 250 + ".txt",  "250 个 ASCII（254 字节）"),
]
print(f"{'说明':<28} {'app 判定(name.count≤255)':<24} {'设备端实际':<12} 错误原文")
print("-" * 100)
for name, note in BYTE_CASES:
    n_chars = len(name)
    app_ok = "放行" if n_chars <= 255 else "拒绝"
    t = PROBE + "/" + name
    rc, out, err = sh(f"touch {shlex.quote(t)}")
    exists = sh(f"test -e {shlex.quote(t)} && echo YES || echo NO")[1]
    errline = (err.strip().splitlines() or [""])[0][:44]
    print(f"{note:<28} {app_ok + f'（{n_chars} 字符）':<24} {'成功' if exists == 'YES' else '失败':<12} {errline}")

hdr("复核 4：Android/data 写入边界（换成真实存在的目录）")
code, out, err = sh("ls /sdcard/Android/data/")
dirs = [d for d in out.splitlines() if d.strip() and not d.startswith("total")]
print(f"设备上现有的应用外部目录（{len(dirs)} 个）：")
for d in dirs[:8]:
    print(f"  {d}")
targets = dirs[:2] + ["", ".."]
for d in targets:
    path = ("/sdcard/Android/data/" + d).rstrip("/")
    rc, out, err = sh(f"touch {shlex.quote(path + '/probe.tmp')}")
    exists = sh(f"test -e {shlex.quote(path + '/probe.tmp')} && echo YES || echo NO")[1]
    error = (err.strip().splitlines() or [""])[0][:60]
    print(f"{path:<56} {'可写 ✓' if exists == 'YES' else '不可写 ✗'}  {error}")
    sh(f"rm -f {shlex.quote(path + '/probe.tmp')}")

hdr("复核 5：/sdcard 的大小写语义（上一轮用 test -f 判的，这次用「能不能共存」判）")
sh(f"rm -f {shlex.quote(PROBE + '/Case.txt')} {shlex.quote(PROBE + '/case.txt')}")
sh(f"touch {shlex.quote(PROBE + '/Case.txt')}")
rc, out, err = sh(f"touch {shlex.quote(PROBE + '/case.txt')}")
err2 = (err.strip().splitlines() or [""])[0][:70]
print(f"先建 Case.txt，再建 case.txt：rc={rc}  err={err2}")
code, out, err = sh(f"ls -1 {shlex.quote(PROBE)} | grep -ci '^case.txt'")
print(f"目录里匹配 ^case.txt 的条数（不区分大小写地数）：{out}")
code, out, err = sh(f"ls -1 {shlex.quote(PROBE)}")
both = [l for l in out.splitlines() if l.lower() == "case.txt"]
print(f"实际名字：{both}  ⇒ {'两个名字共存 ⇒ 区分大小写' if len(both) == 2 else '只有一个 ⇒ 不区分大小写（Case.txt 与 case.txt 是同一个文件）'}")
print()
print("同一条路再验 adb push：")
push(LOCAL_ONE, f"{PROBE}/Case.txt")
push(LOCAL_ONE, f"{PROBE}/case.txt")
code, out, err = sh(f"ls -1 {shlex.quote(PROBE)} | grep -iv '^case'")[0:3]
code, out, err = sh(f"ls -1 {shlex.quote(PROBE)}")
print(f"  push Case.txt 与 case.txt 之后，目录里的 case 条目：{[l for l in out.splitlines() if l.lower()=='case.txt']}")

hdr("复核 6：NFC vs NFD（上一轮 grep 模式写错，恒为 0）")
sh(f"rm -f {shlex.quote(PROBE + '/caf*')}")
nfc = "caf\u00e9.txt"
nfd = "cafe\u0301.txt"
rc1, o1, e1 = sh(f"touch {shlex.quote(PROBE + '/' + nfc)}")
rc2, o2, e2 = sh(f"touch {shlex.quote(PROBE + '/' + nfd)}")
code, out, err = sh(f"ls -1 {shlex.quote(PROBE)} | grep -c '^caf'")
print(f"NFC('café' 单码点) rc={rc1} / NFD('cafe'+组合重音) rc={rc2}")
print(f"ls | grep -c '^caf' = {out}  ⇒ {'两个独立文件 ⇒ 设备端不做 Unicode 归一化' if out == '2' else '被归一化/覆盖 ⇒ 只留一个'}")
code, out, err = sh(f"ls -1 {shlex.quote(PROBE)} | grep '^caf' | /system/bin/od -c | head -6")
print(out[:400])

hdr("清理")
sh(f"rm -rf {shlex.quote(PROBE)}")
print(sh(f"ls -d {shlex.quote(PROBE)} 2>/dev/null || echo GONE")[1])
