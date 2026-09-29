#!/usr/bin/env python3
"""生成「微信多开」图标：深色圆角底 + 三个层叠的绿色气泡，表达多实例。
刻意不用微信的纯绿底，避免在 Dock 里跟微信本体混淆。

两个踩过的坑：
1. ImageDraw 画半透明色是替换像素而非叠加，叠加效果必须用独立图层 +
   alpha_composite，否则会把底层擦穿。
2. macOS 图标不铺满画布：1024 画布里圆角方块只占约 824，四周留透明边，
   否则在 Dock 里会比邻居大一圈。圆角半径按方块边长的 ~22.4% 算。
"""
from pathlib import Path

from PIL import Image, ImageDraw

S = 1024
SS = 4  # 超采样，画完缩回去做抗锯齿
W = S * SS

# 苹果规格：1024 画布内方块 824，四边各留 100 透明边
INSET = int(W * 100 / 1024)
BOX = W - INSET * 2               # 圆角方块边长
R = int(BOX * 0.224)              # 圆角半径
L, T = INSET, INSET               # 方块左上角
RT, B = W - INSET, W - INSET      # 方块右下角


def layer():
    return Image.new("RGBA", (W, W), (0, 0, 0, 0))


def rounded_mask():
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).rounded_rectangle([L, T, RT - 1, B - 1], radius=R, fill=255)
    return m


# --- 底：深石板色圆角方 ---
base = layer()
ImageDraw.Draw(base).rounded_rectangle([L, T, RT - 1, B - 1], radius=R, fill=(40, 46, 56, 255))

# --- 顶部受光：渐变画在独立层，再用圆角遮罩裁进方块内 ---
glow = layer()
gd = ImageDraw.Draw(glow)
h = int(BOX * 0.55)
for i in range(h):
    a = int(22 * (1 - i / h) ** 1.6)
    if a:
        gd.rectangle([L, T + i, RT, T + i + 1], fill=(255, 255, 255, a))
glow.putalpha(Image.composite(glow.getchannel("A"), Image.new("L", (W, W), 0), rounded_mask()))
base = Image.alpha_composite(base, glow)


# --- 三个气泡：各自一层，从后往前叠，越靠前越亮 ---
def bubble(cx, cy, rad, fill):
    lay = layer()
    ld = ImageDraw.Draw(lay)
    ld.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=fill)
    # 左下角尾巴，补上气泡的形状提示
    ld.polygon(
        [
            (cx - rad * 0.58, cy + rad * 0.60),
            (cx - rad * 0.86, cy + rad * 1.14),
            (cx - rad * 0.14, cy + rad * 0.86),
        ],
        fill=fill,
    )
    return lay


# 气泡尺寸与位置都按方块边长 BOX 算，跟着方块缩放
C = W // 2
base = Image.alpha_composite(base, bubble(C + int(BOX * 0.150), C - int(BOX * 0.155), int(BOX * 0.170), (56, 118, 82, 255)))
base = Image.alpha_composite(base, bubble(C + int(BOX * 0.062), C - int(BOX * 0.048), int(BOX * 0.190), (72, 168, 108, 255)))
front = bubble(C - int(BOX * 0.070), C + int(BOX * 0.082), int(BOX * 0.210), (126, 228, 146, 255))

# 前景气泡里三个点，暗示会话
fd = ImageDraw.Draw(front)
fcx, fcy = C - int(BOX * 0.070), C + int(BOX * 0.070)
dot = int(BOX * 0.024)
for off in (-int(BOX * 0.058), 0, int(BOX * 0.058)):
    fd.ellipse([fcx + off - dot, fcy - dot, fcx + off + dot, fcy + dot], fill=(28, 68, 44, 255))

base = Image.alpha_composite(base, front)

# 气泡若超出方块要裁掉（当前布局没超，留着防止调参时溢出）
base.putalpha(Image.composite(base.getchannel("A"), Image.new("L", (W, W), 0), rounded_mask()))

out = base.resize((S, S), Image.LANCZOS)
DEST = Path(__file__).resolve().parent / "icon_1024.png"
out.save(DEST)
print(f"已生成 {DEST}  (方块 {BOX // SS}/{S}，四边留白 {INSET // SS})")
