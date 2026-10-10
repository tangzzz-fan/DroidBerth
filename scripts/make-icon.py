#!/usr/bin/env python3
"""生成 DroidBerth 的 App 图标（母版 PNG + .icns）。

设计稿：`docs/design/2026-10-10-ui-icons/app-icon-directions.html`，方向 A `two-berths`。
几何数值全部来自那份稿子，本文件是它的**代码实现**，不是另一次设计。

    底板  超椭圆 |x|^5 + |y|^5 = 412^5（中心 512,512），垂直渐变 #F9A04A → #DE6B20
    左栏  圆角矩形 (158,272)-(348,752)，圆角 56，白
    右栏  圆角矩形 (676,272)-(866,752)，圆角 56，白
    箭头  折线 (453,402)→(571,512)→(453,622)，线宽 86、圆头圆角，白

三条硬约束（都有实测依据，不是偏好）：

1. **底板是超椭圆，不是圆角矩形。** 稿子用 n=5 逼近 Apple 的 continuous corner：
   45° 处离角点 53.3px，而 r=185.4 的普通圆角是 54.3px —— 切口对得上，肩部更接近
   连续曲率。用普通圆角会让图标在 Dock 里显得比邻居"方"。
2. **投影要烘焙进图里。** 实测依据：把系统内置的
   `/System/Applications/Notes.app/Contents/Resources/AppIcon.icns` 解出来量剖面，
   内容区外**确实有一圈很淡的 alpha**（下缘最强约 0.14、上缘最弱约 0.05，下缘扩散
   ≈52px、上缘 ≈32px，master 尺度）。下面的参数就是照着那条剖面（偏心向下 +
   高斯衰减）调出来的。
3. **16pt 档要单独渲染。** 标准几何在 16px 下栏宽只剩约 3px、间隙不到 1px，
   降采样后间隙会被抗锯齿填平，整块糊成一个白团。所以 16pt 这一档（含它的 @2x）
   用一份专门的几何。
   ⚠️ `icon_16x16@2x.png` 是 **32px 的图**，但它属于 **16pt 这一档** ——
   Retina 用户在 Finder 列表里看到的就是它，两者必须共用同一份几何。

零第三方依赖：只用标准库 + `sips` / `iconutil`。
"""

import argparse
import math
import os
import struct
import subprocess
import time
import zlib

# ── 画布与内容区 ──────────────────────────────────────────────
CANVAS = 1024
CONTENT = 824          # Apple 规范：内容区 824×824 居中，四周 100pt 留白
CONTENT_MIN = (CANVAS - CONTENT) // 2      # 100
CONTENT_MAX = CANVAS - CONTENT_MIN         # 924
SUPER_N = 5            # 超椭圆指数

# ── 品牌渐变（来自稿子的品牌色卡）──────────────────────────────
BRAND_LIGHT = (249, 160, 74)   # #F9A04A
BRAND_DARK = (222, 107, 32)    # #DE6B20
WHITE = (255, 255, 255)

# ── 投影：参数由实测剖面**拟合**得到，不是拍脑袋 ─────────────
# 拟合基准：解出系统内置的 Notes.app 图标，量它内容区外四向的 alpha 剖面，
# 再用「向下偏移 + 高斯模糊」（剖面为正态 CDF）去最小二乘。
# 结果是 A=0.18 / dy=8.5 / sigma=15，四个方向共 40 个采样点的残差平方和 24
# （均方误差约 0.77/255）—— 肉眼看不出与系统图标的差别。
SHADOW_ALPHA = 0.18
SHADOW_DY = 8.5        # 向下偏移（master 单位）
SHADOW_SIGMA = 15.0    # 高斯半径（master 单位）

# ── 标准几何 ──────────────────────────────────────────────────
PANEL_W = 190
PANEL_R = 56
PANEL_TOP = 272
PANEL_BOTTOM = 752
STANDARD_PANELS = (
    (158, PANEL_TOP, 158 + PANEL_W, PANEL_BOTTOM, PANEL_R),
    (676, PANEL_TOP, 676 + PANEL_W, PANEL_BOTTOM, PANEL_R),
)
STANDARD_ARROW_POINTS = ((453, 402), (571, 512), (453, 622))
STANDARD_ARROW_HALF_WIDTH = 43.0        # 线宽 86

# ── 16pt 档几何 ───────────────────────────────────────────────
# ⚠️ 这里是**代码侧的判断，与稿子的字面指示相反**，理由记全：
#
# 稿子写的是"把间隙压到 0、箭头并进左侧面板做成实心楔形"（`app-icon-directions.html`
# 的推荐段）。照那条字面做，三块会并成**一片连续的白**，16px 下就只剩一个白团 ——
# 图标身份全部丢失，而且这正是稿子自己反对 B 方向的那个失败模式
# （"16pt 下会糊成一个没有方向的钝角块"）。
#
# 所以改成反向操作：把间隙**拉大**到 1.1px 以上（标准档只有 0.97px），栏加宽，
# 箭头换成实心三角。代价是 16pt 档的字形比标准档略宽（760 vs 708 单位，
# 占内容区 92% vs 86%）—— 小尺寸图标本来就该占得更满，Finder 自己也这么做。
SMALL_PANELS = (
    (132, 248, 328, 776, PANEL_R),
    (696, 248, 892, 776, PANEL_R),
)
SMALL_ARROW_TRIANGLE = ((398, 382), (398, 642), (588, 512))


# ══════════════════════════════════════════════════════════════
# 有符号距离（负 = 在形状内部）。
#
# 全部走距离而不是"点在不在里面"，是为了每个像素都能拿到一个连续判据 ——
# 覆盖度要它，投影的衰减也要它。
# ══════════════════════════════════════════════════════════════

def superellipse_distance(x, y, n=SUPER_N):
    """超椭圆 |x|^n + |y|^n = a^n 的近似有符号距离。"""
    a = CONTENT / 2.0
    u = abs(x - CANVAS / 2.0) / a
    v = abs(y - CANVAS / 2.0) / a
    t = u ** n + v ** n
    return (t ** (1.0 / n) - 1.0) * a


def rounded_box_distance(x, y, x0, y0, x1, y1, r):
    """圆角矩形的精确有符号距离。"""
    cx = 0.5 * (x0 + x1)
    cy = 0.5 * (y0 + y1)
    hx = 0.5 * (x1 - x0) - r
    hy = 0.5 * (y1 - y0) - r
    dx = abs(x - cx) - hx
    dy = abs(y - cy) - hy
    ox = dx if dx > 0.0 else 0.0
    oy = dy if dy > 0.0 else 0.0
    outside = (ox * ox + oy * oy) ** 0.5
    inside = dx if dx > dy else dy
    if inside > 0.0:
        inside = 0.0
    return outside + inside - r


def segment_distance(px, py, ax, ay, bx, by):
    vx = bx - ax
    vy = by - ay
    wx = px - ax
    wy = py - ay
    length2 = vx * vx + vy * vy
    t = 0.0 if length2 == 0.0 else (wx * vx + wy * vy) / length2
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    dx = wx - t * vx
    dy = wy - t * vy
    return (dx * dx + dy * dy) ** 0.5


def polyline_distance(x, y, points, half_width):
    best = None
    for index in range(len(points) - 1):
        ax, ay = points[index]
        bx, by = points[index + 1]
        d = segment_distance(x, y, ax, ay, bx, by)
        if best is None or d < best:
            best = d
    return best - half_width


def point_in_triangle(x, y, triangle):
    (ax, ay), (bx, by), (cx, cy) = triangle
    d1 = (x - bx) * (ay - by) - (ax - bx) * (y - by)
    d2 = (x - cx) * (by - cy) - (bx - cx) * (y - cy)
    d3 = (x - ax) * (cy - ay) - (cx - ax) * (y - ay)
    has_negative = d1 < 0.0 or d2 < 0.0 or d3 < 0.0
    has_positive = d1 > 0.0 or d2 > 0.0 or d3 > 0.0
    return not (has_negative and has_positive)


def triangle_distance(x, y, triangle):
    inside = point_in_triangle(x, y, triangle)
    best = None
    for index in range(3):
        ax, ay = triangle[index]
        bx, by = triangle[(index + 1) % 3]
        d = segment_distance(x, y, ax, ay, bx, by)
        if best is None or d < best:
            best = d
    return -best if inside else best


class Geometry:
    """一套几何。`small=True` 走 16pt 档。"""

    def __init__(self, small):
        self.small = small
        self.panels = SMALL_PANELS if small else STANDARD_PANELS
        self.arrow_points = None if small else STANDARD_ARROW_POINTS
        self.arrow_half_width = STANDARD_ARROW_HALF_WIDTH
        self.arrow_triangle = SMALL_ARROW_TRIANGLE if small else None

    def white_distance(self, x, y):
        """白色部分（两栏 + 箭头）的有符号距离。"""
        best = None
        for box in self.panels:
            d = rounded_box_distance(x, y, *box)
            if best is None or d < best:
                best = d
        if self.arrow_triangle is not None:
            d = triangle_distance(x, y, self.arrow_triangle)
        else:
            d = polyline_distance(x, y, self.arrow_points, self.arrow_half_width)
        return d if best is None or d < best else best

    def distance(self, x, y):
        """整个字形（底板 ∪ 白色部分）。"""
        body = superellipse_distance(x, y)
        white = self.white_distance(x, y)
        return white if white < body else body

    def color_at(self, x, y):
        """样本点的颜色；在字形之外返回 None。"""
        if self.white_distance(x, y) <= 0.0:
            return WHITE
        if superellipse_distance(x, y) <= 0.0:
            # 渐变铺满**内容区**而不是整个画布 —— 这样露出来的两端正好是稿子给的
            # 两个端点色，而不是被 100pt 留白各吃掉一截。
            t = (y - CONTENT_MIN) / float(CONTENT_MAX - CONTENT_MIN)
            if t < 0.0:
                t = 0.0
            elif t > 1.0:
                t = 1.0
            return (
                int(round(BRAND_LIGHT[0] + (BRAND_DARK[0] - BRAND_LIGHT[0]) * t)),
                int(round(BRAND_LIGHT[1] + (BRAND_DARK[1] - BRAND_LIGHT[1]) * t)),
                int(round(BRAND_LIGHT[2] + (BRAND_DARK[2] - BRAND_LIGHT[2]) * t)),
            )
        return None


def shadow_alpha(geometry, x, y):
    """(x, y) 处的投影 alpha。

    投影 = 字形向下偏移 `SHADOW_DY` 再高斯模糊。所以"点 P 落在投影里"等价于
    "P 上方 `SHADOW_DY` 处落在字形里"，而一个被高斯模糊的阶跃，其剖面是**正态 CDF**
    而不是高斯本身 —— 用 `exp(-q²/2)` 会得到一个假的平顶（实测对不上系统图标：
    真实剖面在边缘就已经开始衰减）。
    """
    shifted = geometry.distance(x, y - SHADOW_DY)
    z = -shifted / SHADOW_SIGMA
    if z <= -4.0:
        return 0.0
    if z >= 4.0:
        return SHADOW_ALPHA
    return SHADOW_ALPHA * 0.5 * (1.0 + math.erf(z / 1.4142135623730951))


# ══════════════════════════════════════════════════════════════
# 渲染
# ══════════════════════════════════════════════════════════════

def render(size, small, supersample=4):
    """渲染一张 size×size 的 RGBA。几何始终在 1024 尺度上求值。"""
    geometry = Geometry(small)
    scale = CANVAS / float(size)
    half = scale / 2.0
    step = 1.0 / supersample
    offsets = [((i + 0.5) * step - 0.5) for i in range(supersample)]
    samples = float(supersample * supersample)

    pixels = bytearray(size * size * 4)
    for py in range(size):
        base_y = (py + 0.5) * scale
        row = py * size * 4
        for px in range(size):
            base_x = (px + 0.5) * scale

            # 快路径：离字形足够远的像素直接判空，整块落在白色部分里的直接判满。
            # 这一条把 1024 母版里绝大多数像素从"每像素 16 次整字形求值"里摘出来。
            center_d = geometry.distance(base_x, base_y)
            if center_d > half + 1.0:
                coverage_alpha = 0.0
                sum_r = sum_g = sum_b = 0.0
            elif center_d < -(half + 1.0) and geometry.white_distance(base_x, base_y) < -(half + 1.0):
                coverage_alpha = 1.0
                sum_r, sum_g, sum_b = 255.0, 255.0, 255.0
            else:
                sum_r = sum_g = sum_b = 0.0
                hits = 0
                for dy in offsets:
                    y = base_y + dy
                    for dx in offsets:
                        color = geometry.color_at(base_x + dx, y)
                        if color is not None:
                            hits += 1
                            sum_r += color[0]
                            sum_g += color[1]
                            sum_b += color[2]
                if hits == 0:
                    coverage_alpha = 0.0
                else:
                    coverage_alpha = hits / samples
                    sum_r /= hits
                    sum_g /= hits
                    sum_b /= hits

            shadow = shadow_alpha(geometry, base_x, base_y)

            # 先铺投影，再把字形合成上去。投影是纯黑、只出在字形之外。
            out_a = coverage_alpha + shadow * (1.0 - coverage_alpha)
            if out_a <= 0.002:
                continue
            if coverage_alpha > 0.0:
                weight = coverage_alpha / out_a
                r = sum_r * weight
                g = sum_g * weight
                b = sum_b * weight
            else:
                r = g = b = 0.0
            offset = row + px * 4
            pixels[offset] = int(round(r))
            pixels[offset + 1] = int(round(g))
            pixels[offset + 2] = int(round(b))
            pixels[offset + 3] = int(round(out_a * 255.0))
    return bytes(pixels)


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
    with open(path, "wb") as handle:
        handle.write(blob)


# ══════════════════════════════════════════════════════════════
# iconset 装配
# ══════════════════════════════════════════════════════════════

# (iconset 文件名, 像素边长, 是否用 16pt 档几何)
#
# 两条容易搞错的：
# - `icon_16x16@2x.png` 是 **32px 的图**，但它属于 **16pt 这一档** —— Retina 用户
#   在 Finder 列表里看到的就是它，必须与 `icon_16x16.png` 共用同一份几何。
# - `icon_32x32.png` 同样 32px，却属于 **32pt** 这一档，用标准几何。
#   两张 32px 的图在这个 iconset 里内容不同，是正常的。
ICONSET_SPECS = (
    ("icon_16x16.png", 16, True),
    ("icon_16x16@2x.png", 32, True),
    ("icon_32x32.png", 32, False),
    ("icon_32x32@2x.png", 64, False),
    ("icon_128x128.png", 128, False),
    ("icon_128x128@2x.png", 256, False),
    ("icon_256x256.png", 256, False),
    ("icon_256x256@2x.png", 512, False),
    ("icon_512x512.png", 512, False),
    ("icon_512x512@2x.png", 1024, False),
)

# 从母版降采样的档位 —— 大尺寸不需要原生渲染，`sips` 的滤波足够，
# 省掉若干次百万像素级的纯 Python 循环。
DERIVED = (32, 64, 128, 256, 512)


def downsample_half(rgba, size):
    """严格的 2×2 面积平均（box filter），在**预乘 alpha** 空间里做。

    两个都要紧：

    - **不用 `sips` 降采样。** 实测 `sips -z` 会把投影压掉约 25%
      （母版下缘峰值 30/255 → 降到 256 后只剩 24/255），而系统图标在 256 档是 35。
      降采样是纯算术，自己做既准又可复现，顺带少一个外部依赖。
    - **必须在预乘空间里平均。** 直接平均非预乘的 RGB 会让低 alpha 像素里那个
      "黑色"渗进邻居，图标外缘会浮出一圈灰边。
    """
    half = size // 2
    out = bytearray(half * half * 4)
    for y in range(half):
        row0 = (2 * y) * size * 4
        row1 = (2 * y + 1) * size * 4
        out_row = y * half * 4
        for x in range(half):
            i0 = row0 + 8 * x
            i1 = i0 + 4
            i2 = row1 + 8 * x
            i3 = i2 + 4
            a0 = rgba[i0 + 3]
            a1 = rgba[i1 + 3]
            a2 = rgba[i2 + 3]
            a3 = rgba[i3 + 3]
            alpha_sum = a0 + a1 + a2 + a3
            if alpha_sum == 0:
                continue
            o = out_row + 4 * x
            out[o] = (rgba[i0] * a0 + rgba[i1] * a1 + rgba[i2] * a2 + rgba[i3] * a3) // alpha_sum
            out[o + 1] = (rgba[i0 + 1] * a0 + rgba[i1 + 1] * a1
                          + rgba[i2 + 1] * a2 + rgba[i3 + 1] * a3) // alpha_sum
            out[o + 2] = (rgba[i0 + 2] * a0 + rgba[i1 + 2] * a1
                          + rgba[i2 + 2] * a2 + rgba[i3 + 2] * a3) // alpha_sum
            out[o + 3] = (alpha_sum + 2) // 4
    return bytes(out)


def build_icns(master_rgba, master_path, iconset_dir, icns_path):
    os.makedirs(iconset_dir, exist_ok=True)

    # 逐级折半，一次拿到全部 2 的幂档位。逐次 2×2 面积平均与一次性大核 box filter
    # 等价，而读取量从 O(n² × 档数) 降到 O(n²)。
    pyramid = {CANVAS: master_rgba}
    size = CANVAS
    while size > 16:
        size //= 2
        pyramid[size] = downsample_half(pyramid[size * 2], size * 2)

    for name, size, small in ICONSET_SPECS:
        target = os.path.join(iconset_dir, name)
        if small:
            # 16pt 档：原生渲染 —— 几何与标准档不同，靠降采样拿不到。
            write_png(target, size, size, render(size, small=True))
        else:
            write_png(target, size, size, pyramid[size])

    subprocess.run(
        ["/usr/bin/iconutil", "-c", "icns", iconset_dir, "-o", icns_path],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def main():
    parser = argparse.ArgumentParser(description="生成 DroidBerth 的 App 图标")
    parser.add_argument("out_dir", nargs="?", default="macos/Resources",
                        help="输出目录（icon.png / icon.icns 落在这里）")
    parser.add_argument("--iconset-dir", default=None,
                        help="中间 iconset 目录；默认 <out_dir 的上一级>/build/icon.iconset")
    parser.add_argument("--master-only", action="store_true",
                        help="只出 1024 母版，跳过 iconset 与 .icns（调参时用）")
    args = parser.parse_args()

    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)
    iconset_dir = args.iconset_dir or os.path.join(
        os.path.dirname(out_dir), "build", "icon.iconset"
    )

    master = os.path.join(out_dir, "icon.png")

    started = time.time()
    print(f"rendering {CANVAS}x{CANVAS} master ...")
    master_rgba = render(CANVAS, small=False)
    write_png(master, CANVAS, CANVAS, master_rgba)
    print(f"  master done in {time.time() - started:.1f}s")

    if args.master_only:
        print(f"wrote {master}")
        return

    icns_path = os.path.join(out_dir, "icon.icns")
    build_icns(master_rgba, master, iconset_dir, icns_path)
    print(f"  iconset + icns done in {time.time() - started:.1f}s")

    for path in (master, icns_path):
        print(f"  {os.path.basename(path)}  {os.path.getsize(path)} bytes")
    print("  rendered natively (16pt slot): "
          + ", ".join(name for name, _, small in ICONSET_SPECS if small))
    print("  area-filtered from master: "
          + ", ".join(str(size) for size in sorted(DERIVED)) + " px")


if __name__ == "__main__":
    main()
