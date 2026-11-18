#!/usr/bin/env python3
# eterm 应用图标生成（macOS / Android 共用一套视觉）。
# 设计：墨蓝渐变圆角方（Apple 网格 824/1024）+ 白瓷色终端提示符「›」+ 黄铜色光标块。
# 超采样 4096 → LANCZOS 缩至 1024。产物：
#   icon-1024.png         macOS 全 artwork（含透明边距与圆角）
#   icon-foreground.png   Android 自适应前景（仅字形，安全区内）
#   preview-1024.png      预览
from PIL import Image, ImageDraw

S = 4096          # 绘制画布
OUT = 1024        # 输出尺寸

# 调色
INK_TOP = (38, 47, 62)      # 0x262F3E
INK_BOT = (24, 30, 41)      # 0x181E29
PORCELAIN = (236, 239, 245) # 0xECEFF5
BRASS = (211, 168, 104)     # 0xD3A868

# Apple macOS 图标网格：画布 1024 → 形状 824，圆角 ≈ 22.5%
RECT = 3296
MARGIN = (S - RECT) // 2
RADIUS = int(RECT * 0.225)


def rounded_gradient_base(size: int) -> Image.Image:
    """墨蓝垂直渐变圆角方形（带 1px 内侧高光的\"机加工\"质感）。"""
    scale = 4  # 渐变用更高分辨率画再缩，避免 banding
    big = size * scale
    grad = Image.new("RGB", (big, big))
    d = ImageDraw.Draw(grad)
    for y in range(big):
        t = y / (big - 1)
        # 轻微非线性（顶部略提亮），中段过渡更绵
        tt = t ** 0.92
        c = tuple(round(a + (b - a) * tt) for a, b in zip(INK_TOP, INK_BOT))
        d.line([(0, y), (big, y)], fill=c)
    grad = grad.resize((size, size), Image.LANCZOS)

    mask = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [MARGIN * scale, MARGIN * scale, (S - MARGIN) * scale, (S - MARGIN) * scale],
        radius=RADIUS * scale, fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)

    base = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    base.paste(grad, (0, 0), mask)

    # 内侧高光描边：白色 4% alpha，往内缩 3px
    ov = Image.new("RGBA", (size * scale, size * scale), (0, 0, 0, 0))
    ImageDraw.Draw(ov).rounded_rectangle(
        [MARGIN * scale + 3 * scale, MARGIN * scale + 3 * scale,
         (S - MARGIN) * scale - 3 * scale, (S - MARGIN) * scale - 3 * scale],
        radius=RADIUS * scale - 3 * scale,
        outline=(255, 255, 255, 10), width=4 * scale)
    ov = ov.resize((size, size), Image.LANCZOS)
    base.alpha_composite(ov)
    return base


def draw_prompt(scale: float, cx: float, cy: float) -> Image.Image:
    """终端提示符字形层（透明底）：「›」+ 光标块，组内光学居中。
    scale=1 时按 4096 画布基准绘制。返回画布尺寸与基准一致的 RGBA。"""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    lw = 190 * scale
    # 提示符「›」：折线 + 圆帽
    pts = [(cx - 430 * scale, cy - 205 * scale),
           (cx - 150 * scale, cy),
           (cx - 430 * scale, cy + 205 * scale)]
    d.line([(p[0] * 1, p[1]) for p in pts], fill=PORCELAIN + (255,),
           width=round(lw), joint="curve")
    r = lw / 2
    for p in (pts[0], pts[2]):
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=PORCELAIN + (255,))
    # 光标块：黄铜色胶囊
    x0, x1 = cx + 45 * scale, cx + 525 * scale
    y0, y1 = cy - 107 * scale, cy + 107 * scale
    d.rounded_rectangle([x0, y0, x1, y1], radius=(y1 - y0) / 2, fill=BRASS + (255,))
    return img


def make_macos_icon() -> Image.Image:
    base = rounded_gradient_base(S)
    # 字形组放大约 15% 增强存在感（组对 cx 光学对称，无需偏移）
    glyph = draw_prompt(1.15, S / 2, S / 2)
    base.alpha_composite(glyph)
    return base.resize((OUT, OUT), Image.LANCZOS)


def make_adaptive_foreground() -> Image.Image:
    # 自适应前景：仅字形，宽约 42% 画布（远小于 66% 安全区直径）
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    img.alpha_composite(draw_prompt(1730 / 1050, S / 2, S / 2))  # 基准组宽 1050 → ~1730
    return img.resize((OUT, OUT), Image.LANCZOS)


if __name__ == "__main__":
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    mac = make_macos_icon()
    mac.save(os.path.join(here, "icon-1024.png"))
    fg = make_adaptive_foreground()
    fg.save(os.path.join(here, "icon-foreground.png"))
    mac.save(os.path.join(here, "preview-1024.png"))
    print("done")
