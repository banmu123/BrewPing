#!/usr/bin/env python3
"""从 logo/logo.png 生成 macOS 风格的应用图标。

背景：logo.png 是「透明底 + 悬浮咖啡杯」的抠图，直接塞进 .icns 会得到一个
没有底板、悬空的杯子，在 Dock 里与系统图标的圆角 squircle 外观不一致。
本脚本把杯子放到 macOS Big Sur+ 规范里的圆角 squircle 底板上，
再导出全套 iconset，供 iconutil 打成 AppIcon.icns。

用法:
    python3 tools/make-appicon.py                # 生成 build/appicon/AppIcon.iconset + logo/AppIcon-1024.png
    python3 tools/make-appicon.py --variant latte  # 换浅色米白底板
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys

import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_LOGO = os.path.join(ROOT, "logo", "logo.png")

# macOS Big Sur+ 图标网格：1024 画布里内容占 824，四周留 100 阴影安全区
CANVAS = 1024
PLATE = 824
MARGIN = (CANVAS - PLATE) // 2
SQUIRCLE_N = 5.0  # 超椭圆指数，n=5 与 Apple squircle 观感最接近

# 底板配色（v1 = 浓咖啡渐变，v2 = 与 Android 自适应图标一致的暖米色）
VARIANTS = {
    "espresso": {
        "from": (183, 129, 84),
        "to": (56, 31, 19),
        "highlight": 0.14,
    },
    "latte": {
        "from": (247, 238, 227),
        "to": (223, 199, 170),
        "highlight": 0.20,
    },
}

ICONSET_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


# --------------------------------------------------------------------------- #
# 杯子抠图：清掉抠图残留的白边/彩边
# --------------------------------------------------------------------------- #
def load_cup() -> Image.Image:
    img = Image.open(SRC_LOGO).convert("RGBA")
    arr = np.array(img).astype(np.float32)
    rgb, alpha = arr[..., :3], arr[..., 3:4] / 255.0

    # 1) 去白边：原图是「白底抠图」，半透明像素的颜色是(cup 与白底的混合)，
    #    按 a 反解回真实颜色，消除边缘白晕。
    safe = np.maximum(alpha, 1e-3)
    decon = np.clip((rgb - (1.0 - alpha) * 255.0) / safe, 0, 255)
    # 只对半透明过渡带生效，完全不透明/完全透明区域保持原样
    band = ((alpha > 0.01) & (alpha < 0.99)).astype(np.float32)
    rgb = rgb * (1 - band) + decon * band

    # 2) 收紧 alpha：把 [0,1] 的软过渡映射成更窄的区间，进一步压掉残余彩边
    a = np.clip((alpha - 0.22) / 0.56, 0, 1)
    a = a * a * (3.0 - 2.0 * a)  # smoothstep，边缘更干净

    out = np.dstack([rgb, a * 255.0]).astype(np.uint8)
    cup = Image.fromarray(out, "RGBA")

    # 3) 裁到内容边界，方便后续按比例摆放
    bbox = cup.getchannel("A").point(lambda v: 255 if v > 6 else 0).getbbox()
    return cup.crop(bbox)


# --------------------------------------------------------------------------- #
# squircle 底板
# --------------------------------------------------------------------------- #
def squircle_coverage(size: int, plate: int, n: float) -> np.ndarray:
    """返回 [0,1] 的覆盖率图（含抗锯齿）。"""
    half = plate / 2.0
    c = size / 2.0
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    dx = np.abs(xx + 0.5 - c) / half
    dy = np.abs(yy + 0.5 - c) / half
    f = dx**n + dy**n - 1.0

    # 用数值梯度把「场」换算成像素尺度的距离，从而得到 ~1px 的抗锯齿过渡
    gy, gx = np.gradient(f)
    grad = np.sqrt(gx**2 + gy**2) + 1e-6
    cov = np.clip(0.5 - f / grad, 0.0, 1.0)
    return cov


def make_plate(size: int, palette: dict) -> Image.Image:
    """生成带对角渐变 + 顶部高光 + 内描边的圆角底板。"""
    c0 = np.array(palette["from"], dtype=np.float32)
    c1 = np.array(palette["to"], dtype=np.float32)

    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    t = np.clip((xx / size) * 0.45 + (yy / size) * 0.55, 0, 1)[..., None]
    rgb = c0 * (1 - t) + c1 * t

    # 左上柔和高光，模拟系统图标的受光
    cx, cy = size * 0.32, size * 0.24
    r = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (size * 0.78)
    hl = np.clip(1.0 - r, 0, 1)[..., None] ** 2 * palette["highlight"] * 255.0
    rgb = rgb + hl

    alpha = squircle_coverage(size, PLATE / CANVAS * size, SQUIRCLE_N) * 255.0

    # 内描边：贴边 1.2px 的浅色高光，让底板有立体感
    inner = squircle_coverage(size, PLATE / CANVAS * size - 2.4, SQUIRCLE_N)
    rim = np.clip(alpha / 255.0 - inner, 0, 1)[..., None]
    rgb = rgb + rim * 46.0

    plate = np.dstack([np.clip(rgb, 0, 255), alpha]).astype(np.uint8)
    return Image.fromarray(plate, "RGBA")


# --------------------------------------------------------------------------- #
# 合成
# --------------------------------------------------------------------------- #
def build_icon(variant: str) -> Image.Image:
    plate = make_plate(CANVAS, VARIANTS[variant])
    cup = load_cup()

    # 杯子宽度占底板 ~68%，居中并略微上移（视觉重心更稳）
    target_w = int(PLATE * 0.68)
    scale = target_w / cup.width
    cup = cup.resize((target_w, int(round(cup.height * scale))), Image.LANCZOS)

    px = (CANVAS - cup.width) // 2
    py = int((CANVAS - cup.height) / 2 - CANVAS * 0.012)

    # 杯子放到与画布同尺寸的层上，方便做阴影与合成
    cup_layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    cup_layer.paste(cup, (px, py), cup)

    # 杯底接触阴影，避免杯子"浮"在底板上
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", cup.size, (28, 16, 8, 130)), (px, py), cup)
    shadow = shadow.filter(ImageFilter.GaussianBlur(CANVAS * 0.018))
    shadow.putalpha(shadow.getchannel("A").point(lambda v: int(v * 0.62)))

    out = Image.alpha_composite(plate, shadow)
    out = Image.alpha_composite(out, cup_layer)
    return out


def export(variant: str, out_dir: str) -> str:
    icon = build_icon(variant)

    iconset = os.path.join(out_dir, "AppIcon.iconset")
    if os.path.isdir(iconset):
        shutil.rmtree(iconset)
    os.makedirs(iconset, exist_ok=True)

    for name, size in ICONSET_SIZES:
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))

    # 1024 母版：后续所有尺寸的唯一来源，纳入版本管理
    master_png = os.path.join(ROOT, "logo", "AppIcon-1024.png")
    icon.save(master_png)

    # 供 build-app.sh 直接拷贝进 .app/Contents/Resources 的成品 icns
    icns = os.path.join(ROOT, "logo", "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)

    build_icns = os.path.join(out_dir, "AppIcon.icns")
    shutil.copyfile(icns, build_icns)
    return icns


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", choices=sorted(VARIANTS), default="espresso")
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "appicon"))
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    icns = export(args.variant, args.out)
    print(f"variant = {args.variant}")
    print(f"iconset = {os.path.join(args.out, 'AppIcon.iconset')}")
    print(f"icns    = {icns}")
    print(f"master  = {os.path.join(ROOT, 'logo', 'AppIcon-1024.png')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
