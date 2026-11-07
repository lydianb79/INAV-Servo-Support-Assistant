#!/usr/bin/env python3
"""Renders AppIcon.png (1024x1024) for INAV Servo Support Assistant.
Drawn at 2x and downsampled. macOS Big Sur icon grid: 824px rounded square, 100px margin."""
import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

S = 2048            # supersampled canvas
K = S / 1024        # scale factor
def k(v): return int(round(v * K))

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def rounded_mask(size, box, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=r, fill=255)
    return m

def vgradient(size, top, bottom):
    w, h = size
    g = Image.new("RGBA", size)
    d = ImageDraw.Draw(g)
    for y in range(h):
        d.line([(0, y), (w, y)], fill=lerp(top, bottom, y / max(h - 1, 1)))
    return g

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# ---------- squircle background + shadow ----------
box = (k(100), k(100), k(924), k(924))
radius = k(186)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + k(14), box[2], box[3] + k(14)), radius=radius, fill=(0, 0, 0, 120))
shadow = shadow.filter(ImageFilter.GaussianBlur(k(22)))
canvas.alpha_composite(shadow)

bg = vgradient((S, S), (22, 40, 82, 255), (8, 14, 32, 255))
# soft radial glow behind the chip
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
cx, cy = k(430), k(430)
for i in range(60, 0, -1):
    r = k(9 * i)
    a = int(3.2 * (60 - i) ** 0.9)
    gd.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(40, 140, 210, min(a, 90)))
glow = glow.filter(ImageFilter.GaussianBlur(k(40)))
bg.alpha_composite(glow)
mask = rounded_mask((S, S), box, radius)
canvas.paste(bg, (0, 0), mask)

# subtle inner rim highlight
rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(rim).rounded_rectangle(box, radius=radius, outline=(255, 255, 255, 40), width=k(4))
canvas.alpha_composite(rim)

layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)

# faint PCB traces in the background
trace = (70, 120, 170, 70)
for (x1, y1, x2, y2, x3, y3) in [
    (180, 300, 260, 300, 300, 260), (180, 640, 250, 640, 290, 680), (300, 820, 300, 760, 340, 720),
    (720, 200, 720, 250, 690, 280), (200, 470, 240, 470, 260, 450)]:
    d.line([(k(x1), k(y1)), (k(x2), k(y2)), (k(x3), k(y3))], fill=trace, width=k(6), joint="curve")
    d.ellipse((k(x1) - k(9), k(y1) - k(9), k(x1) + k(9), k(y1) + k(9)), outline=trace, width=k(5))

# ---------- chip ----------
chip_c = (k(405), k(405))
half = k(150)
pins_per_side = 6
pin_len, pin_w = k(48), k(24)
pitch = (2 * half - k(70)) / (pins_per_side - 1)
highlight = {("right", 1), ("right", 2)}     # the UART pads that become servo outputs
silver_top, silver_bot = (225, 230, 238, 255), (150, 158, 170, 255)
orange = (255, 150, 30, 255)

def pin_boxes():
    for side in ("left", "right", "top", "bottom"):
        for i in range(pins_per_side):
            off = -half + k(35) + i * pitch
            if side == "left":
                yield side, i, (chip_c[0] - half - pin_len, chip_c[1] + off - pin_w / 2, chip_c[0] - half + k(8), chip_c[1] + off + pin_w / 2)
            elif side == "right":
                yield side, i, (chip_c[0] + half - k(8), chip_c[1] + off - pin_w / 2, chip_c[0] + half + pin_len, chip_c[1] + off + pin_w / 2)
            elif side == "top":
                yield side, i, (chip_c[0] + off - pin_w / 2, chip_c[1] - half - pin_len, chip_c[0] + off + pin_w / 2, chip_c[1] - half + k(8))
            else:
                yield side, i, (chip_c[0] + off - pin_w / 2, chip_c[1] + half - k(8), chip_c[0] + off + pin_w / 2, chip_c[1] + half + pin_len)

# glow for highlighted pins
pglow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
pg = ImageDraw.Draw(pglow)
for side, i, b in pin_boxes():
    if (side, i) in highlight:
        pg.rounded_rectangle((b[0] - k(14), b[1] - k(14), b[2] + k(14), b[3] + k(14)), radius=k(16), fill=(255, 140, 20, 170))
pglow = pglow.filter(ImageFilter.GaussianBlur(k(16)))
layer.alpha_composite(pglow)
d = ImageDraw.Draw(layer)

for side, i, b in pin_boxes():
    hot = (side, i) in highlight
    col = orange if hot else silver_top
    d.rounded_rectangle(b, radius=k(6), fill=col)
    # small shading
    if side in ("left", "right"):
        d.rectangle((b[0], (b[1] + b[3]) / 2, b[2], b[3]), fill=(lerp(col, (0, 0, 0, 255), 0.18)))
    else:
        d.rectangle(((b[0] + b[2]) / 2, b[1], b[2], b[3]), fill=(lerp(col, (0, 0, 0, 255), 0.18)))

# chip body with gradient
body_box = (chip_c[0] - half, chip_c[1] - half, chip_c[0] + half, chip_c[1] + half)
body = vgradient((S, S), (62, 68, 80, 255), (24, 27, 34, 255))
bmask = rounded_mask((S, S), body_box, k(34))
body_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
body_layer.paste(body, (0, 0), bmask)
layer.alpha_composite(body_layer)
d = ImageDraw.Draw(layer)
d.rounded_rectangle(body_box, radius=k(34), outline=(120, 128, 142, 255), width=k(4))
inner = (body_box[0] + k(26), body_box[1] + k(26), body_box[2] - k(26), body_box[3] - k(26))
d.rounded_rectangle(inner, radius=k(20), outline=(255, 255, 255, 22), width=k(3))
# pin-1 dot
d.ellipse((body_box[0] + k(40), body_box[1] + k(40), body_box[0] + k(68), body_box[1] + k(68)), fill=(14, 16, 20, 255))

# chip label
try:
    f_big = ImageFont.truetype("/usr/share/fonts/opentype/inter/Inter-Bold.otf", k(78))
    f_small = ImageFont.truetype("/usr/share/fonts/opentype/inter/Inter-Medium.otf", k(30))
except OSError:
    f_big = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", k(70))
    f_small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", k(28))
d.text((chip_c[0], chip_c[1] - k(14)), "INAV", font=f_big, fill=(232, 236, 242, 255), anchor="mm")
d.text((chip_c[0], chip_c[1] + k(52)), "TIM · UART", font=f_small, fill=(140, 200, 240, 255), anchor="mm")

# ---------- PWM signal from the orange pins to the servo ----------
start_y = chip_c[1] - half + k(35) + 2 * pitch
x0 = chip_c[0] + half + pin_len + k(4)
pts = [(x0, start_y), (x0 + k(26), start_y)]
x = x0 + k(26)
y_hi, y_lo = start_y - k(40), start_y
seg = k(30)
for n in range(3):
    pts += [(x, y_hi), (x + seg * 0.7, y_hi), (x + seg * 0.7, y_lo), (x + seg * 1.7, y_lo)]
    x += seg * 1.7
servo_x = int(x) + k(26)
pts += [(servo_x - k(30), y_lo)]
# rounded corner down to the servo
pts += [(servo_x - k(12), y_lo + k(5)), (servo_x - k(3), y_lo + k(15)), (servo_x, y_lo + k(32)), (servo_x, k(612))]
sig = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(sig)
sd.line(pts, fill=(255, 170, 60, 200), width=k(16), joint="curve")
sig = sig.filter(ImageFilter.GaussianBlur(k(10)))
layer.alpha_composite(sig)
d = ImageDraw.Draw(layer)
d.line(pts, fill=(255, 200, 110, 255), width=k(8), joint="curve")

# ---------- servo ----------
sv_box = (k(600), k(612), k(856), k(840))      # servo body
shadow2 = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow2).rounded_rectangle((sv_box[0] + k(8), sv_box[1] + k(16), sv_box[2] + k(8), sv_box[3] + k(16)), radius=k(36), fill=(0, 0, 0, 140))
shadow2 = shadow2.filter(ImageFilter.GaussianBlur(k(18)))
layer.alpha_composite(shadow2)
d = ImageDraw.Draw(layer)
# mounting tabs
d.rounded_rectangle((sv_box[0] - k(36), sv_box[1] + k(70), sv_box[2] + k(36), sv_box[1] + k(122)), radius=k(14), fill=(200, 100, 10, 255))
for xx in (sv_box[0] - k(18), sv_box[2] + k(18)):
    d.ellipse((xx - k(9), sv_box[1] + k(87), xx + k(9), sv_box[1] + k(105)), fill=(90, 40, 0, 255))
body2 = vgradient((S, S), (255, 168, 48, 255), (226, 102, 12, 255))
m2 = rounded_mask((S, S), sv_box, k(36))
b2 = Image.new("RGBA", (S, S), (0, 0, 0, 0))
b2.paste(body2, (0, 0), m2)
layer.alpha_composite(b2)
d = ImageDraw.Draw(layer)
d.rounded_rectangle(sv_box, radius=k(36), outline=(255, 214, 150, 255), width=k(4))
# output shaft + horn (arm), rotated slightly
hc = (sv_box[0] + k(86), sv_box[1] + k(146))
d.ellipse((hc[0] - k(56), hc[1] - k(56), hc[0] + k(56), hc[1] + k(56)), fill=(250, 250, 252, 255), outline=(200, 205, 215, 255), width=k(4))
ang = math.radians(-28)
L = k(140)
tip = (hc[0] + L * math.cos(ang), hc[1] + L * math.sin(ang))
# arm as a tapered polygon
def arm_poly(c, t, w0, w1):
    dx, dy = t[0] - c[0], t[1] - c[1]
    ln = math.hypot(dx, dy); nx, ny = -dy / ln, dx / ln
    return [(c[0] + nx * w0, c[1] + ny * w0), (t[0] + nx * w1, t[1] + ny * w1),
            (t[0] - nx * w1, t[1] - ny * w1), (c[0] - nx * w0, c[1] - ny * w0)]
d.polygon(arm_poly(hc, tip, k(30), k(18)), fill=(250, 250, 252, 255))
d.ellipse((tip[0] - k(19), tip[1] - k(19), tip[0] + k(19), tip[1] + k(19)), fill=(250, 250, 252, 255))
for t in (0.45, 0.72, 0.95):
    px, py = hc[0] + (tip[0] - hc[0]) * t, hc[1] + (tip[1] - hc[1]) * t
    d.ellipse((px - k(6), py - k(6), px + k(6), py + k(6)), fill=(150, 156, 168, 255))
d.ellipse((hc[0] - k(18), hc[1] - k(18), hc[0] + k(18), hc[1] + k(18)), fill=(120, 126, 138, 255))
# motion marks around the arm tip
for rr, a0, a1 in ((k(160), -44, -14), (k(178), -40, -18)):
    d.arc((hc[0] - rr, hc[1] - rr, hc[0] + rr, hc[1] + rr), start=a0, end=a1, fill=(255, 236, 205, 255), width=k(5))

# clip everything to the squircle
clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
clipped.paste(layer, (0, 0), ImageChops.multiply(layer.getchannel("A"), mask))
canvas.alpha_composite(clipped)

# glossy top highlight
gloss = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(gloss).ellipse((k(40), k(-420), k(984), k(420)), fill=(255, 255, 255, 18))
gl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gl.paste(gloss, (0, 0), ImageChops.multiply(gloss.getchannel("A"), mask))
canvas.alpha_composite(gl)

out = canvas.resize((1024, 1024), Image.LANCZOS)
path = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png"
out.save(path)
out.resize((256, 256), Image.LANCZOS).save(path.replace(".png", "_256.png"))
print("wrote", path)
