#!/usr/bin/env python3
"""钉死设备端的折叠规则到底是哪一条。

已知：`ﬁ`↔`fi` 折叠、`ß`↔`ss` 折叠；但 `Ａ`↔`A` 不折叠、`ⓞ`↔`o` 不折叠。
这两个数据点指向 **Unicode 完整大小写折叠（CaseFolding.txt 的 C+F 映射）**，
而不是 NFKC 兼容分解。用只在该规则下才会折叠、其余规则都不折叠的字符来判：

  · U+212A KELVIN SIGN  → 完整折叠映射到 U+006B "k"
  · U+212B ANGSTROM SIGN → 完整折叠映射到 U+00E5 "å"
  · U+03C2 GREEK FINAL SIGMA → 折叠到 U+03C3 σ
  · U+0130 LATIN CAPITAL I WITH DOT ABOVE → 折叠到 i + U+0307

阴性对照（任何规则都不该折叠的）：é vs e（变音不折叠）、ﬁ vs f（长度不同）。
"""
import os
import shlex
import subprocess
import sys

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
D = "/sdcard/Download/DroidBerthFold2"

S = None
out = subprocess.run([ADB, "devices"], capture_output=True, text=True).stdout
for line in out.splitlines():
    if line.endswith("\tdevice"):
        S = line.split("\t")[0]
if not S:
    sys.exit("!! 没有在线设备")


def sh(cmd):
    r = subprocess.run([ADB, "-s", S, "shell", cmd], capture_output=True, text=True, timeout=30)
    return r.returncode, r.stdout.replace("\r\n", "\n").strip(), r.stderr.replace("\r\n", "\n").strip()


PAIRS = [
    ("kelvin", "kelvin", "U+212A KELVIN SIGN ↔ 普通 k（完整折叠才折叠）"),
    ("\u212bngstrom", "\u00c5ngstrom", "U+212B ANGSTROM ↔ U+00C5 Å（完整折叠才折叠）"),
    ("\u03c3igma", "\u03c2igma", "σ ↔ ς 希腊词尾 sigma（完整折叠才折叠）"),
    ("\u0130stanbul", "i\u0307stanbul", "U+0130 İ ↔ i+U+0307（完整折叠才折叠）"),
    ("caf\u00e9", "cafe", "é ↔ e ← **阴性对照**：变音不该被折叠"),
    ("\ufb01", "f", "连字 ﬁ ↔ 单个 f ← **阴性对照**：长度不同"),
]

print(f"设备：{S}")
print()
print(f"{'说明':<46} {'条目数':<8} 判定")
print("-" * 100)
for a, b, note in PAIRS:
    sh(f"rm -rf {shlex.quote(D)}")
    sh(f"mkdir -p {shlex.quote(D)}")
    ra, _, _ = sh(f"touch {shlex.quote(D + '/' + a + '.txt')}")
    rb, _, eb = sh(f"touch {shlex.quote(D + '/' + b + '.txt')}")
    _, cnt, _ = sh(f"find {shlex.quote(D)} -mindepth 1 | wc -l")
    folded = cnt.strip() == "1"
    print(f"{note:<46} {cnt.strip():<8} {'**折叠**' if folded else '不折叠'}")
    if rb != 0:
        print(f"    第二个被拒：{(eb.splitlines() or [''])[0][:60]}")

sh(f"rm -rf {shlex.quote(D)}")
print()
print("判读：若 Kelvin / Angstrom / 词尾 sigma / İ 都折叠，而 é↔e 不折叠，")
print("      则设备端的规则 = **Unicode 完整大小写折叠**（与 Swift 的 lowercased() 不同：")
print("      Swift 的 lowercased() 不把 ß 变成 ss、也不把 ﬁ 变成 fi）。")
