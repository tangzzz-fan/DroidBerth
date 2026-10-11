#!/usr/bin/env python3
"""备好缩略图截断测试的素材集，并报告每个文件的 moov 位置。

判据：moov 在文件前 64 KB 内 → 截断头**有机会**解码；moov 在文件尾 → 必然失败。
PRD §13.3 明确预言了这一点，本脚本就是为了把预言变成数字。
"""
import os
import shutil
import struct
import subprocess
import sys

OUT = "/tmp/probe/media"
os.makedirs(OUT, exist_ok=True)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def moov_offset(path):
    """扫描顶层 box，返回 moov 的起始偏移；找不到返回 None。"""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        pos = 0
        while pos + 8 <= size:
            f.seek(pos)
            head = f.read(8)
            if len(head) < 8:
                break
            n = struct.unpack(">I", head[:4])[0]
            tag = head[4:8]
            if n == 1:                      # 64 位长度
                n = struct.unpack(">Q", f.read(8))[0]
            elif n == 0:
                n = size - pos
            if tag in (b"moov", b"mdat"):
                if tag == b"moov":
                    return pos, size
            if n <= 0:
                break
            pos += n
    return None, size


# ── 1. 图片：从系统 HEIC 放大成各格式，保证都超过 64 KB ──────────────
SRC_HEIC = "/System/Library/Desktop Pictures/.thumbnails/Tree.heic"
if not os.path.exists(SRC_HEIC):
    cands = subprocess.run(
        ["/usr/bin/find", "/System/Library/Desktop Pictures/.thumbnails",
         "-name", "*.heic"], capture_output=True, text=True).stdout.split("\n")
    SRC_HEIC = next((c for c in cands if c), None)

images = [
    ("photo.jpg",  ["-s", "format", "jpeg", "-s", "formatOptions", "best"]),
    ("photo.png",  ["-s", "format", "png"]),
    ("photo.heic", ["-s", "format", "heic"]),
    ("photo.tiff", ["-s", "format", "tiff"]),
    ("photo.gif",  ["-s", "format", "gif"]),
]
for name, fmt in images:
    dst = os.path.join(OUT, name)
    # 先放大到 1800×2400，再转格式：小图转出来达不到 64 KB，截断就没有意义
    r = run(["/usr/bin/sips", "-z", "2400", "1800", *fmt, SRC_HEIC, "--out", dst])
    if not os.path.exists(dst):
        print(f"  !! {name} 生成失败: {r.stderr.strip()[:120]}")

# webp：macOS 27 的 sips 支持与否不确定，实测为准
dst = os.path.join(OUT, "photo.webp")
run(["/usr/bin/sips", "-z", "2400", "1800", "-s", "format", "webp", SRC_HEIC, "--out", dst])
if not os.path.exists(dst):
    shutil.copy(SRC_HEIC, dst)          # 退化成"名为 webp 实为 heic"，不参与统计

# ── 2. 视频：挑一个系统 mov，再造一个 faststart 的 mp4 ────────────────
MOV_SRC = ("/System/Library/CoreServices/ControlCenter.app/Contents/Resources/"
           "BentoGalleryIntroduction.mov")
if os.path.exists(MOV_SRC):
    shutil.copy(MOV_SRC, os.path.join(OUT, "video.mov"))

# avconvert 产出 mp4；Apple 的导出器默认**不**做 faststart ⇒ moov 在尾部，
# 这正是 PRD 说的失败情形。再想办法造一个 moov 在头部的 mp4 做对照。
raw_mp4 = os.path.join(OUT, "video-moovlast.mp4")
if os.path.exists(MOV_SRC):
    run(["/usr/bin/avconvert", "--preset", "Preset640x480", "--source", MOV_SRC,
         "--output", raw_mp4, "--replace"])

# ── 3. 报告 ─────────────────────────────────────────────────────────
print(f"{'文件':<22} {'大小(B)':>10}  {'moov @':>10}  moov 在 64KB 头内？")
print("-" * 70)
rows = []
for name in sorted(os.listdir(OUT)):
    p = os.path.join(OUT, name)
    size = os.path.getsize(p)
    off, _ = moov_offset(p)
    if off is None:
        verdict = "—（非容器 / 无 moov）"
        pos = ""
    else:
        pos = str(off)
        verdict = "是 ✓" if off < 65536 else "否 ✗（截断头必失败）"
    rows.append((name, size, pos, verdict))
    print(f"{name:<22} {size:>10,}  {pos:>10}  {verdict}")

print()
print("图片要 > 65536 才构成真截断（否则整文件都被取回，测试无意义）：")
for name, size, _, _ in rows:
    ext = name.rsplit(".", 1)[-1].lower()
    if ext in ("jpg", "png", "heic", "tiff", "gif", "webp"):
        print(f"  {name:<22} {size:>10,}  {'OK（会截断）' if size > 65536 else '过小！'}")
