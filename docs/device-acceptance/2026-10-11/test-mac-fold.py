#!/usr/bin/env python3
"""macOS 侧的名字折叠语义（设备端那份的镜子测试）。

为什么值得量：`TransferPlanner.download` 的目标卷就是它。折叠得比卷的实际语义**少**
会漏判（丢数据），**多**只会多出一个 ` (1)`（碍眼但安全）。所以要把边界摸清，
才能说清「统一用完整大小写折叠」在下载方向是不是过度折叠。
"""
import os
import shutil
import subprocess

D = "/tmp/probe/macfold"

PAIRS = [
    ("IMG.JPG", "img.jpg", "大小写"),
    ("caf\u00e9.txt", "cafe\u0301.txt", "NFC ↔ NFD"),
    ("\u00df.txt", "ss.txt", "ß ↔ ss"),
    ("\ufb01le.txt", "file.txt", "连字 ﬁ ↔ fi"),
    ("\u212a.txt", "k.txt", "KELVIN U+212A ↔ k"),
    ("\u03c3.txt", "\u03c2.txt", "σ ↔ ς"),
    ("A.txt", "\uff21.txt", "A ↔ 全角Ａ"),
    ("o.txt", "\u24de.txt", "o ↔ ⓞ"),
    ("caf\u00e9.txt", "cafe.txt", "é ↔ e（阴性对照）"),
    ("a.txt", "a.txt ", "尾随空格（阴性对照）"),
    ("a.txt", "a.txt.", "尾随点（阴性对照）"),
]

print("macOS 侧（/tmp，APFS 默认卷）")
print()
print(f"{'说明':<32} {'条目数':<8} 判定")
print("-" * 76)
for a, b, note in PAIRS:
    shutil.rmtree(D, ignore_errors=True)
    os.makedirs(D, exist_ok=True)
    for name in (a, b):
        try:
            open(os.path.join(D, name), "w").close()
        except OSError:
            pass
    # 用字节级列举，避免 Unicode 比较把差异吃掉
    listed = os.listdir(D.encode())
    cnt = len(listed)
    print(f"{note:<32} {cnt:<8} {'**折叠**' if cnt == 1 else '不折叠'}   实际：{[x.decode('utf-8', 'replace') for x in listed]}")

shutil.rmtree(D, ignore_errors=True)

print()
print("--- 设备端（同一批，作为对照）---")
print("  大小写     折叠（Case.txt 与 case.txt 同一个）")
print("  NFC ↔ NFD  折叠")
print("  ß ↔ ss     **折叠**")
print("  ﬁ ↔ fi     **折叠**")
print("  KELVIN ↔ k **折叠**")
print("  σ ↔ ς      **折叠**")
print("  全角Ａ ↔ A  不折叠")
print("  ⓞ ↔ o      不折叠")
print("  é ↔ e      不折叠")
print("  尾随空格    不折叠")
print("  尾随点      不折叠")

# Swift 的 String == 是按**规范等价**比较的 —— 这决定了 NFC 那一维原本就不构成缺陷
print()
print("--- 顺带确认一条 Swift 语义（它决定 NFC 这一维要不要写代码）---")
print("  Swift 的 String == / Set.contains 按 Unicode **规范等价**比较：")
print("  NFC 与 NFD 的字面量 `==` 为真 —— 所以旧代码的 Set<String> 其实已经处理了 NFC，")
print("  真正漏掉的是**大小写**与**完整折叠**（ß/ﬁ/ς 与 NFC 无关，是两回事）。")
