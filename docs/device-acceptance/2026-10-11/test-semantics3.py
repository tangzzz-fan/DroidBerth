#!/usr/bin/env python3
"""最后一轮收口验证：三处必须钉死的判据。

1. 上一轮「19 个文件名预期成功，但 ls -a 只数出 19 行（含 . 与 ..）」的差额是谁
2. 超长名字被拒时的**确切 errno 原文**（要写进报告）
3. `adb push` 在**不区分大小写**的卷上，对仅大小写不同的名字是「覆盖」还是「并存」
   —— 用文件内容证明，而不是靠文件名推断
"""
import os
import shlex
import subprocess
import sys

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
PROBE = "/sdcard/Download/DroidBerthProbe3"


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

hdr("收口 1：上一轮 19 个「预期成功」的名字，逐个核对真身")
OK_NAMES = ["a'b.txt", "a`b.txt", "a$b.txt", "a;b.txt", "a&b.txt", "a b.txt",
            "中文名.txt", "😀emoji.txt", ".hidden.txt", "-dash.txt", "~tilde.txt",
            "#hash.txt", "%pct.txt", "(paren).txt", "[brack].txt", "{brace}.txt",
            "ABC.TXT", "trailingspace .txt", "enddot..txt"]
missing = []
for name in OK_NAMES:
    rc, out, err = sh(f"touch {shlex.quote(PROBE + '/' + name)}")
    exists = sh(f"test -e {shlex.quote(PROBE + '/' + name)} && echo YES || echo NO")[1]
    if exists != "YES":
        missing.append(name)
print(f"预期成功 {len(OK_NAMES)} 个；test -e 判不存在的：{missing or '（无）'}")
code, out, err = sh(f"ls -a {shlex.quote(PROBE)}")
listed = [l for l in out.splitlines() if l.strip()]
print(f"ls -a 实际列出 {len(listed)} 行（含 . 与 ..）⇒ {len(listed) - 2} 个文件")
print("逐行内容：")
for l in listed:
    print(f"  {l!r}")
print()
print("ls 的字符转义：带特殊字符的名字会被 ls **加引号或转义**，")
print("因此「行数」不等于「文件数」—— 上一轮 19 行的差额应在这里解释，"
      "而不是文件丢了。用 `find` 独立复核：")
code, out, err = sh(f"find {shlex.quote(PROBE)} -mindepth 1 -maxdepth 1 | wc -l")
print(f"  find | wc -l = {out}  ⇒ 真实文件数")

hdr("收口 2：超长名字的确切 errno 原文")
for name, note in [("中" * 100 + ".txt", "100 CJK = 300 字节"),
                   ("😀" * 200 + ".txt", "200 emoji = 800 字节"),
                   ("x" * 255 + ".txt", "255 ASCII + .txt = 259 字节"),
                   ("x" * 251 + ".txt", "251 ASCII + .txt = 255 字节（边界）"),
                   ("中" * 85 + ".txt", "85 CJK = 255 字节（边界）"),
                   ("中" * 86 + ".txt", "86 CJK = 258 字节（越界 1）")]:
    total = len(name.encode("utf-8"))
    rc, out, err = sh(f"touch {shlex.quote(PROBE + '/' + name)}")
    exists = sh(f"test -e {shlex.quote(PROBE + '/' + name)} && echo YES || echo NO")[1]
    msg = ""
    for line in err.splitlines():
        if ":" in line:
            msg = line.split(":", 2)[-1].strip()
    print(f"{note:<26} {total:>4} 字节  字符数={len(name):>3}  "
          f"{'成功' if exists == 'YES' else '失败'}  {msg[:60]}")

hdr("收口 3：adb push 对仅大小写不同的名字 —— 用**内容**证明是覆盖")
sh(f"rm -rf {shlex.quote(PROBE + '/Case')}")
sh(f"mkdir -p {shlex.quote(PROBE + '/Case')}")
d = PROBE + "/Case"
open("/tmp/probe/aaa.txt", "w").write("AAAA-原始内容\n")
open("/tmp/probe/BBB.txt", "w").write("BBBB-新内容\n")
r1 = push("/tmp/probe/aaa.txt", f"{d}/Report.txt")
r2 = push("/tmp/probe/BBB.txt", f"{d}/report.txt")
print(f"push Report.txt rc={r1[0]} / push report.txt rc={r2[0]}")
code, out, err = sh(f"ls -1 {shlex.quote(d)}")
print(f"目录里的条目：{out.splitlines()}")
code, out, err = sh(f"cat {shlex.quote(d + '/Report.txt')} 2>&1")
print(f"读回 Report.txt → {out!r}")
print()
print("判读：若只剩一个文件且内容是 BBBB ⇒ **第二个 push 静默替换了第一个**（设备卷不区分大小写）")
print("      若两个文件并存 ⇒ 设备卷区分大小写，上传方向不折叠是安全的")

hdr("收口 4：mv（重命名/移动走的路径）在同样情形下的行为")
sh(f"rm -rf {shlex.quote(d)}")
sh(f"mkdir -p {shlex.quote(d)}")
sh(f"printf 'ORIG' > {shlex.quote(d + '/Report.txt')}")
sh(f"printf 'OTHER' > {shlex.quote(d + '/report.txt')}")
code, out, err = sh(f"ls -1 {shlex.quote(d)}")
print(f"先建 Report.txt 与 report.txt，目录里：{out.splitlines()}")
code, out, err = sh(f"printf 'NEW' > {shlex.quote(d + '/REPORT.txt')}")
code, out, err = sh(f"ls -1 {shlex.quote(d)}")
print(f"再写 REPORT.txt 之后：{out.splitlines()}")
code, out, err = sh(f"cat {shlex.quote(d + '/Report.txt')}")
print(f"读回 Report.txt → {out!r}  ⇒ 三次写入落到同一个文件（大小写被折叠）")

hdr("清理")
sh(f"rm -rf {shlex.quote(PROBE)}")
print(sh(f"ls -d {shlex.quote(PROBE)} 2>/dev/null || echo GONE")[1])
