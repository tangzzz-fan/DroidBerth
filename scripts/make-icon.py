#!/usr/bin/env python3
import os
import struct
import subprocess
import sys
import zlib

SIZE = 1024
MARGIN = 72
RADIUS = 210
SS = 2

BAR = (341, 258, 431, 766, 46)
BOWL_CX = 431
BOWL_CY = 512
BOWL_R = 254
COUNTER_CX = 558
COUNTER_CY = 512
COUNTER_R = 95

BG_A = (8, 145, 178)
BG_B = (34, 211, 238)
FG = (248, 250, 252)


def inside_round_rect(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = x0 + r if x < x0 + r else (x1 - r if x > x1 - r else x)
    cy = y0 + r if y < y0 + r else (y1 - r if y > y1 - r else y)
    dx = x - cx
    dy = y - cy
    return dx * dx + dy * dy <= r * r


def gradient(t):
    return tuple(round(BG_A[i] + (BG_B[i] - BG_A[i]) * t) for i in range(3))


def render():
    rect = (MARGIN, MARGIN, SIZE - MARGIN, SIZE - MARGIN, RADIUS)
    px = bytearray(SIZE * SIZE * 4)
    step = 1.0 / SS
    samples = SS * SS
    for py in range(SIZE):
        row = py * SIZE * 4
        for pxi in range(SIZE):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(SS):
                y = py + (sy + 0.5) * step
                for sx in range(SS):
                    x = pxi + (sx + 0.5) * step
                    if not inside_round_rect(x, y, *rect):
                        continue
                    t = ((x - MARGIN) + (y - MARGIN)) / (2.0 * (SIZE - 2 * MARGIN))
                    t = min(1.0, max(0.0, t))
                    r, g, b = gradient(t)
                    dy = y - BOWL_CY
                    in_glyph = inside_round_rect(x, y, *BAR)
                    if not in_glyph and x >= BOWL_CX:
                        in_glyph = (x - BOWL_CX) ** 2 + dy * dy <= BOWL_R * BOWL_R
                    if in_glyph:
                        cdx = x - COUNTER_CX
                        in_counter = cdx * cdx + dy * dy <= COUNTER_R * COUNTER_R
                        if not in_counter:
                            r, g, b = FG
                    acc[0] += r
                    acc[1] += g
                    acc[2] += b
                    acc[3] += 255
            off = row + pxi * 4
            if acc[3] == 0:
                px[off:off + 4] = b"\x00\x00\x00\x00"
            else:
                n = acc[3] / 255
                px[off] = round(acc[0] / n)
                px[off + 1] = round(acc[1] / n)
                px[off + 2] = round(acc[2] / n)
                px[off + 3] = round(acc[3] / samples)
    return px


def write_png(path, width, height, rgba):
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    blob = b"\x89PNG\r\n\x1a\n"
    blob += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    blob += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    blob += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(blob)


def build_icns(master, out_dir, iconset_dir, icns_path):
    specs = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    os.makedirs(iconset_dir, exist_ok=True)
    for size, name in specs:
        subprocess.run(
            ["/usr/bin/sips", "-z", str(size), str(size), master, "--out", os.path.join(iconset_dir, name)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    subprocess.run(
        ["/usr/bin/iconutil", "-c", "icns", iconset_dir, "-o", icns_path],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    for size, name in [(32, "32x32.png"), (128, "128x128.png"), (256, "128x128@2x.png")]:
        subprocess.run(
            ["/usr/bin/sips", "-z", str(size), str(size), master, "--out", os.path.join(out_dir, name)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "src-tauri/icons"
    os.makedirs(out_dir, exist_ok=True)
    master = os.path.join(out_dir, "icon.png")
    print(f"rendering {SIZE}x{SIZE} master with {SS}x{SS} supersampling...")
    write_png(master, SIZE, SIZE, render())
    build_icns(master, out_dir, os.path.join(out_dir, "icon.iconset"), os.path.join(out_dir, "icon.icns"))
    print(f"wrote {master} and icon.icns")
    for name in sorted(os.listdir(out_dir)):
        p = os.path.join(out_dir, name)
        if os.path.isfile(p):
            print(f"  {name}  {os.path.getsize(p)} bytes")


if __name__ == "__main__":
    main()
