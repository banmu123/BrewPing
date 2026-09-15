#!/usr/bin/env python3
"""生成 BrewPing Desktop dmg 安装界面背景图。

尺寸 660x400（dmg 窗口标准大小）。
布局：
  - 背景：深咖啡渐变 (latte-950 -> latte-900)
  - 顶部圆点装饰：brew-500 焦糖色，呼应品牌
  - 中上：logo 圆形（AppIcon 缩放至 96x96）
  - 中下：英文提示 + 中文小字 + 箭头
  - 右下角：commitbrew.com
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 660, 400
OUT = Path(__file__).resolve().parent.parent / "build" / "dmg-background.png"
LOGO = Path(__file__).resolve().parent.parent / "logo" / "AppIcon-1024.png"

# 品牌色
LATTE_950 = (0x24, 0x1A, 0x12)
LATTE_900 = (0x33, 0x24, 0x1A)
LATTE_800 = (0x52, 0x37, 0x22)
BREW_500 = (0xC9, 0x8A, 0x4B)
BREW_400 = (0xD2, 0x9A, 0x5C)
CREAM_100 = (0xFA, 0xF6, 0xEE)
CREAM_300 = (0xEB, 0xE0, 0xCB)
LATTE_400 = (0xC0, 0x9B, 0x6E)


def lerp_color(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))


def make_gradient(w, h, c_top, c_bottom):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        c = lerp_color(c_top, c_bottom, y / (h - 1))
        for x in range(w):
            px[x, y] = c
    return img


def load_font(size, bold=False):
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    for p in candidates:
        if Path(p).exists():
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()


def load_cjk_font(size):
    candidates = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/Supplemental/Songti.ttc",
    ]
    for p in candidates:
        if Path(p).exists():
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return load_font(size)


def draw_arrow(draw, cx, cy, w=44, h=22, color=BREW_500):
    """向右的箭头：一条横线 + 三角头。"""
    left = cx - w // 2
    right = cx + w // 2
    mid_y = cy
    # 横线
    draw.line([(left, mid_y), (right - 6, mid_y)], fill=color, width=3)
    # 三角头
    head = [
        (right - 14, mid_y - 9),
        (right, mid_y),
        (right - 14, mid_y + 9),
    ]
    draw.polygon(head, fill=color)


def main():
    # 1. 背景渐变
    img = make_gradient(W, H, LATTE_950, LATTE_900).convert("RGBA")

    # 2. 顶部细装饰条：一条半透明 brew-500 横线
    draw = ImageDraw.Draw(img)
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    od.line([(60, 56), (W - 60, 56)], fill=(*BREW_500, 60), width=1)
    # 顶部圆点（呼吸感）
    for i, x in enumerate([60, 76, 92]):
        od.ellipse([x, 50, x + 6, 56], fill=(*BREW_400, 200 if i == 0 else 90))
    img = Image.alpha_composite(img, overlay)
    draw = ImageDraw.Draw(img)

    # 3. 中上 logo（圆形遮罩 AppIcon）
    if LOGO.exists():
        logo = Image.open(LOGO).convert("RGBA").resize((96, 96), Image.LANCZOS)
        # 圆形遮罩
        mask = Image.new("L", (96, 96), 0)
        md = ImageDraw.Draw(mask)
        md.ellipse([0, 0, 95, 95], fill=255)
        # 软阴影
        shadow = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow)
        sd.ellipse([0, 0, 95, 95], fill=(0, 0, 0, 120))
        shadow = shadow.filter(ImageFilter.GaussianBlur(8))
        img.paste(shadow, (W // 2 - 48, 96), shadow)
        img.paste(logo, (W // 2 - 48, 92), mask)

    # 4. 文字
    f_title = load_font(28, bold=True)
    f_sub = load_font(14)
    f_hint = load_cjk_font(13)
    f_brand = load_font(11)

    title = "BrewPing Desktop"
    sub_en = "Drag the app icon into your Applications folder."
    sub_zh = "将 BrewPing Desktop 拖到「应用程序」文件夹即可完成安装"

    # 标题
    bbox = draw.textbbox((0, 0), title, font=f_title)
    tw = bbox[2] - bbox[0]
    draw.text(((W - tw) // 2, 210), title, font=f_title, fill=CREAM_100)

    # 副标题英文
    bbox = draw.textbbox((0, 0), sub_en, font=f_sub)
    tw = bbox[2] - bbox[0]
    draw.text(((W - tw) // 2, 252), sub_en, font=f_sub, fill=CREAM_300)

    # 中文小字
    bbox = draw.textbbox((0, 0), sub_zh, font=f_hint)
    tw = bbox[2] - bbox[0]
    draw.text(((W - tw) // 2, 276), sub_zh, font=f_hint, fill=(*LATTE_400, 230))

    # 5. 中间箭头：从左侧 .app 指向右侧 Applications（与图标行同高）
    # Finder 里 .app 位于 {170, 290}、Applications 位于 {490, 290}，图标 72px
    # 图标垂直中心 = 290 + 36 = 326
    draw_arrow(draw, W // 2, 326, w=64, h=26, color=BREW_500)

    # 6. 右下角品牌
    brand = "commitbrew.com"
    bbox = draw.textbbox((0, 0), brand, font=f_brand)
    tw = bbox[2] - bbox[0]
    draw.text((W - tw - 24, H - 26), brand, font=f_brand, fill=(*LATTE_400, 180))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(OUT, "PNG")
    print(f"saved: {OUT}")


if __name__ == "__main__":
    main()
