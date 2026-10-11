#!/usr/bin/env python3
"""把「名字在设备端会不会被折叠成同一个」这件事挖到底。

已经证实：大小写折叠 + NFC 归一化。但 FAT 兼容层还可能做别的折叠：
  · 尾随空格 / 尾随点（FAT 会剥离）
  · 全角 ↔ 半角（NFKC 类折叠）
  · 连字 ﬁ ↔ fi
这些都是**同一个形状**的静默覆盖来源，而 macOS 允许这些名字，所以真的会发生。
"""
import os
import shlex
import subprocess
import sys

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
D = "/sdcard/Download/DroidBerthNameFold"


def serial():
    out = subprocess.run([ADB, "devices"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.endswith("\tdevice"):
            return line.split("\t")[0]
    return None


S = serial()
if not S:
    sys.exit("!! 没有在线设备")


def sh(cmd):
    r = subprocess.run([ADB, "-s", S, "shell", cmd], capture_output=True, text=True, timeout=30)
    return r.returncode, r.stdout.replace("\r\n", "\n").strip(), r.stderr.replace("\r\n", "\n").strip()


def push(local, remote):
    r = subprocess.run([ADB, "-s", S, "push", local, remote], capture_output=True, text=True, timeout=60)
    return r.returncode


def probe(pairs, title):
    """pairs: [(a, b, 说明)]。先建 a、再建 b，看目录里有几个、叫什么。"""
    print()
    print("=" * 78)
    print(title)
    print("=" * 78)
    for a, b, note in pairs:
        sh(f"rm -rf {shlex.quote(D)}")
        sh(f"mkdir -p {shlex.quote(D)}")
        ra, _, ea = sh(f"touch {shlex.quote(D + '/' + a)}")
        rb, _, eb = sh(f"touch {shlex.quote(D + '/' + b)}")
        code, out, err = sh(f"find {shlex.quote(D)} -mindepth 1 | wc -l")
        code, listing, err = sh(f"find {shlex.quote(D)} -mindepth 1 | LC_ALL=C /system/bin/od -c | head -8")
        # 用 od 看真实字节，避免 pty 的转义干扰判读
        cnt = out.strip()
        verdict = "**折叠成同一个**（第二个命中了第一个）" if cnt == "1" else f"两个不同文件（{cnt} 个）"
        print(f"{note}")
        print(f"  建 {a!r} rc={ra}  建 {b!r} rc={rb}  ⇒ 目录里 {cnt} 个条目：{verdict}")
        if rb != 0:
            print(f"    第二个被拒：{(eb.splitlines() or [''])[0][:70]}")
        print(f"    od 原始字节：")
        for line in listing.splitlines()[:4]:
            print(f"      {line}")


sh(f"mkdir -p {shlex.quote(D)}")
open("/tmp/probe/one.txt", "w").write("ORIG")

# ── 1. 尾随空格 / 尾随点（FAT 兼容层会剥离）──────────────────────────
probe([
    ("space.txt",  "space.txt ", "尾随空格：`a.txt ` 会不会落到 `a.txt`"),
    ("dot.txt",    "dot.txt.",   "尾随点：  `a.txt.` 会不会落到 `a.txt`"),
    ("plain",      "plain.  ",   "两者都带：`plain.  ` 与 `plain`"),
], "1. 尾随空格 / 尾随点")

# ── 2. 全角 ↔ 半角（NFKC 类折叠）────────────────────────────────────
probe([
    ("A.txt",  "Ａ.txt", "全角 A ↔ 半角 A"),
    ("1.txt",  "１.txt", "全角 1 ↔ 半角 1"),
    ("ab.txt", "ａｂ.txt", "全角 ab ↔ 半角 ab"),
], "2. 全角 ↔ 半角")

# ── 3. 连字与兼容字符（NFKC 会折叠）──────────────────────────────────
probe([
    ("fi.txt",  "ﬁ.txt",  "连字 ﬁ ↔ fi"),
    ("ss.txt",  "ß.txt",  "ß ↔ ss"),
    ("o.txt",   "ⓞ.txt",  "带圈 o ↔ o"),
], "3. 兼容字符")

# ── 4. 前导/中间空格的差别（应当不折叠，作为阴性对照）────────────────
probe([
    ("a b.txt", "a  b.txt", "单空格 ↔ 双空格（阴性对照，**应当**是两个文件）"),
    ("x.txt",   " x.txt",   "前导空格（阴性对照）"),
], "4. 空格的差别（阴性对照）")

# ── 5. adb push 通道复核：尾随空格是否也折叠 ─────────────────────────
print()
print("=" * 78)
print("5. 用 adb push 复核（上传真正走的通道）—— 尾随空格与全角")
print("=" * 78)
for a, b, note in [("pushspace.txt", "pushspace.txt ", "尾随空格"),
                   ("pushA.txt", "pushＡ.txt", "全角 A")]:
    sh(f"rm -rf {shlex.quote(D)}")
    sh(f"mkdir -p {shlex.quote(D)}")
    r1 = push("/tmp/probe/one.txt", f"{D}/{a}")
    r2 = push("/tmp/probe/one.txt", f"{D}/{b}")
    code, out, err = sh(f"find {shlex.quote(D)} -mindepth 1 | wc -l")
    code, names, err = sh(f"find {shlex.quote(D)} -mindepth 1")
    print(f"{note}：push {a!r} rc={r1} / push {b!r} rc={r2} ⇒ {out.strip()} 个条目")
    print(f"  实际名字：{names.splitlines()}")

sh(f"rm -rf {shlex.quote(D)}")
print()
print("(已清理)")
