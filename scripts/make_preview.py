"""Creates docs/preview.gif, a seamless loop that shows how BarDrop works:

1. A file is dragged from a Finder window to the right edge of the screen.
   A thin strip curves out of the edge, the shelf opens and takes the file.
2. Another app (Mail) comes to the front.
3. The pointer goes to the edge, the shelf opens again, and the file is dragged
   out of it into the email.
4. Mail closes and everything is back where it started.

Shapes, sizes and timings follow the app (EdgeBlobShape, ShelfMetrics,
AnimationStyle). Needs Pillow and NumPy; uses ffmpeg for a smaller GIF if
it is installed.

    python3 scripts/make_preview.py
"""
import math
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
W, H = 880, 550          # output size
S = 2                    # supersampling
FPS = 25
DURATION = 10.8          # seconds per loop
K = 0.8                  # app points → output pixels
CY = 300                 # vertical center of the shelf
MENU_H = 24

# ---------------------------------------------------------------------------
# Helpers


def font(weight, size):
    names = {"regular": "Inter-Regular.otf", "medium": "Inter-Medium.otf",
             "semibold": "Inter-SemiBold.otf", "bold": "Inter-Bold.otf"}
    for d in [Path("/usr/share/fonts/opentype/inter"), Path.home() / "Library/Fonts", Path("/Library/Fonts")]:
        p = d / names[weight]
        if p.exists():
            return ImageFont.truetype(str(p), int(size * S))
    return ImageFont.load_default()


def clamp(x, a=0.0, b=1.0):
    return max(a, min(b, x))


def smooth(t):
    t = clamp(t)
    return t * t * (3 - 2 * t)


def ease_in_out(t):
    t = clamp(t)
    return 4 * t ** 3 if t < 0.5 else 1 - (-2 * t + 2) ** 3 / 2


def ramp(t, a, b):
    return smooth((t - a) / (b - a)) if b > a else float(t >= b)


def spring(t, response, damping):
    """Damped spring like SwiftUI's .spring(response:dampingFraction:)."""
    if t <= 0:
        return 0.0
    w = 2 * math.pi / response
    if damping >= 1:
        return 1 - math.exp(-w * t) * (1 + w * t)
    wd = w * math.sqrt(1 - damping ** 2)
    return 1 - math.exp(-damping * w * t) * (math.cos(wd * t) + damping * w / wd * math.sin(wd * t))


def lerp(a, b, t):
    return a + (b - a) * t


def P(x):
    """Output pixels → supersampled pixels."""
    return x * S


# ---------------------------------------------------------------------------
# Shelf shape (port of EdgeBlobShape, right edge)


def bezier(p0, p1, p2, p3, n=14):
    pts = []
    for i in range(1, n + 1):
        t = i / n
        u = 1 - t
        pts.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                    u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
    return pts


def blob_path(edge_x, top, width, height, corner, fillet, stretch, corner_stretch):
    """Outline points; the shape sits flush at edge_x and extends to the left."""
    if width < 0.5 or height < 0.5:
        return []
    rect_h = height
    max_fy = max(0, min(fillet, rect_h / 4))
    r = max(0, min(corner, (rect_h - 2 * max_fy) / 2, width))
    fx = max(0, min(fillet, width - r))
    fy = min(max_fy, fx * stretch)
    bottom = top + rect_h
    body_top = top + fy
    body_bottom = bottom - fy
    ry = max(0, min(r * max(1, corner_stretch), (body_bottom - body_top) / 2))
    k = 0.5523
    inner = edge_x - width
    pts = [(edge_x, top)]
    pts += bezier((edge_x, top), (edge_x, top + k * fy), (edge_x - fx + k * fx, body_top), (edge_x - fx, body_top))
    pts.append((inner + r, body_top))
    pts += bezier((inner + r, body_top), (inner + r - k * r, body_top), (inner, body_top + ry - k * ry), (inner, body_top + ry))
    pts.append((inner, body_bottom - ry))
    pts += bezier((inner, body_bottom - ry), (inner, body_bottom - ry + k * ry), (inner + r - k * r, body_bottom), (inner + r, body_bottom))
    pts.append((edge_x - fx, body_bottom))
    pts += bezier((edge_x - fx, body_bottom), (edge_x - fx + k * fx, body_bottom), (edge_x, bottom - k * fy), (edge_x, bottom))
    return pts


# Shelf states: width, body height, corner, fillet, fillet stretch, corner stretch
def peek_state():
    t = 8 * K
    soft = 0.4
    corner = t * 0.5
    stretch = 1 + soft
    return (t, 64 * K, corner, (t - corner) * stretch + 1, stretch, max(1, 8 * K / max(corner, 0.5)))


PEEK = peek_state()
HIDDEN = (0, PEEK[1] * 0.55) + PEEK[2:]
OPEN = (240 * K, 430 * K, 28 * K, 16 * K, 1.25, 1)

# Level changes: (time, state, response, damping)
SPRING_PEEK = (0.38, 0.72)
SPRING_OPEN = (0.4, 0.7)
SPRING_CLOSE = (0.32, 0.9)
EVENTS = [
    (0.0, HIDDEN, *SPRING_CLOSE),
    (1.50, PEEK, *SPRING_PEEK),     # drag starts: strip appears right away
    (2.42, OPEN, *SPRING_OPEN),     # file near the edge: shelf opens
    (3.78, HIDDEN, *SPRING_CLOSE),  # pointer left the shelf
    (5.78, PEEK, *SPRING_PEEK),     # pointer touches the edge
    (6.18, OPEN, *SPRING_OPEN),     # after the short delay
    (7.12, HIDDEN, *SPRING_CLOSE),  # file dragged out of the shelf
]


def state_at(t):
    idx = max(i for i, e in enumerate(EVENTS) if e[0] <= t)
    start = EVENTS[0][1] if idx == 0 else state_at(EVENTS[idx][0] - 1e-6)
    t0, target, response, damping = EVENTS[idx]
    f = spring(t - t0, response, damping)
    return tuple(lerp(a, b, f) for a, b in zip(start, target))


def content_alpha(t):
    """Contents of the open shelf: blur-fade in after a short delay, quick fade out."""
    a = 0.0
    for t0, state, *_ in EVENTS:
        if t0 > t:
            break
        if state is OPEN:
            a = ramp(t, t0 + 0.07, t0 + 0.35)
        else:
            a = max(0.0, a * (1 - ramp(t, t0, t0 + 0.12))) if a > 0 else 0.0
    return a


# ---------------------------------------------------------------------------
# Icons


def page_icon(size, kind):
    s = P(size)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pw, ph = s * 0.74, s * 0.94
    x0, y0 = (s - pw) / 2, (s - ph) / 2
    fold = pw * 0.26
    body = [(x0, y0), (x0 + pw - fold, y0), (x0 + pw, y0 + fold), (x0 + pw, y0 + ph), (x0, y0 + ph)]
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon([(x + 0, y + s * 0.02) for x, y in body], fill=(0, 0, 0, 70))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s * 0.03)))
    d.polygon(body, fill=(255, 255, 255, 255), outline=(205, 205, 210, 255))
    d.polygon([(x0 + pw - fold, y0), (x0 + pw - fold, y0 + fold), (x0 + pw, y0 + fold)], fill=(226, 226, 232, 255))
    if kind == "pdf":
        for i in range(4):
            yy = y0 + ph * (0.22 + i * 0.1)
            d.rounded_rectangle([x0 + pw * 0.14, yy, x0 + pw * (0.86 if i else 0.6), yy + s * 0.025], radius=s * 0.01,
                                fill=(200, 200, 206, 255))
        d.rounded_rectangle([x0 + pw * 0.12, y0 + ph * 0.66, x0 + pw * 0.88, y0 + ph * 0.86], radius=s * 0.03,
                            fill=(228, 64, 58, 255))
        f = ImageFont.truetype(font("bold", 1).path, int(s * 0.14))
        tw = d.textlength("PDF", font=f)
        d.text((x0 + pw / 2 - tw / 2, y0 + ph * 0.675), "PDF", font=f, fill=(255, 255, 255, 255))
    else:
        for i in range(6):
            yy = y0 + ph * (0.2 + i * 0.11)
            d.rounded_rectangle([x0 + pw * 0.14, yy, x0 + pw * (0.86 if i % 3 else 0.7), yy + s * 0.022],
                                radius=s * 0.01, fill=(196, 196, 202, 255))
    return img


def photo_icon(size):
    s = P(size)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    m = s * 0.08
    box = [m, s * 0.18, s - m, s * 0.82]
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([box[0], box[1] + s * 0.02, box[2], box[3] + s * 0.02], radius=s * 0.06,
                                             fill=(0, 0, 0, 80))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s * 0.03)))
    pic = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    pd = ImageDraw.Draw(pic)
    for y in range(int(box[1]), int(box[3])):
        f = (y - box[1]) / (box[3] - box[1])
        pd.line([(box[0], y), (box[2], y)], fill=(int(lerp(120, 250, f)), int(lerp(170, 200, f)), int(lerp(240, 170, f)), 255))
    pd.polygon([(box[0], box[3]), (box[0] + s * 0.3, s * 0.48), (box[0] + s * 0.5, s * 0.62), (box[0] + s * 0.66, s * 0.44),
                (box[2], box[3])], fill=(60, 110, 90, 255))
    pd.ellipse([s * 0.62, s * 0.26, s * 0.74, s * 0.38], fill=(255, 240, 200, 255))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=s * 0.06, fill=255)
    img.paste(pic, (0, 0), mask)
    ImageDraw.Draw(img).rounded_rectangle(box, radius=s * 0.06, outline=(255, 255, 255, 255), width=max(2, int(s * 0.03)))
    return img


def airdrop_icon(size):
    s = P(size)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    grad = Image.new("RGBA", (s, s))
    gd = ImageDraw.Draw(grad)
    for y in range(s):
        f = y / s
        gd.line([(0, y), (s, y)], fill=(int(lerp(90, 30, f)), int(lerp(190, 120, f)), 255, 255))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([s * 0.06, s * 0.06, s * 0.94, s * 0.94], radius=s * 0.22, fill=255)
    img.paste(grad, (0, 0), mask)
    c = s / 2
    w = max(2, int(s * 0.055))
    for r in (0.3, 0.2):
        d.arc([c - s * r, c - s * r + s * 0.06, c + s * r, c + s * r + s * 0.06], 205, 335, fill=(255, 255, 255, 255), width=w)
    d.polygon([(c, c - s * 0.02), (c - s * 0.08, c + s * 0.18), (c + s * 0.08, c + s * 0.18)], fill=(255, 255, 255, 255))
    return img


def folder_icon(size):
    s = P(size)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([s * 0.06, s * 0.2, s * 0.48, s * 0.36], radius=s * 0.05, fill=(84, 160, 238, 255))
    d.rounded_rectangle([s * 0.06, s * 0.28, s * 0.94, s * 0.84], radius=s * 0.07, fill=(102, 178, 248, 255))
    d.rounded_rectangle([s * 0.06, s * 0.34, s * 0.94, s * 0.84], radius=s * 0.07, fill=(122, 194, 252, 255))
    c = s / 2
    w = max(2, int(s * 0.06))
    d.line([(c, s * 0.44), (c, s * 0.72)], fill=(70, 140, 220, 255), width=w)
    d.line([(c - s * 0.11, s * 0.61), (c, s * 0.73), (c + s * 0.11, s * 0.61)], fill=(70, 140, 220, 255), width=w, joint="curve")
    return img


def cursor_img():
    pts = [(0, 0), (0, 16.5), (4.1, 12.8), (6.7, 18.9), (9.1, 17.9), (6.6, 11.9), (11.7, 11.9)]
    s = P(24)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sh = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(sh).polygon([(P(x + 2.2), P(y + 2.6)) for x, y in pts], fill=(0, 0, 0, 90))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(P(1.2))))
    d = ImageDraw.Draw(img)
    big = [(P(x + 1.5), P(y + 1.5)) for x, y in pts]
    d.polygon(big, fill=(0, 0, 0, 255))
    d.line(big + [big[0]], fill=(255, 255, 255, 255), width=round(P(1.3)), joint="curve")
    return img


ICON_PDF = {sz: page_icon(sz, "pdf") for sz in (52, 40, 46)}
ICON_TXT = page_icon(52, "txt")
ICON_PHOTO = photo_icon(52)
ICON_AIRDROP = airdrop_icon(27)
ICON_FOLDER = folder_icon(27)
CURSOR = cursor_img()

# ---------------------------------------------------------------------------
# Static scenes

F_MENU = font("semibold", 12.5)
F_MENU_R = font("regular", 12.5)
F_LABEL = font("medium", 11)
F_SMALL = font("regular", 11)
F_TITLE = font("semibold", 12.5)
F_BODY = font("regular", 13)


def wallpaper():
    y, x = np.mgrid[0:P(H), 0:P(W)].astype(np.float32)
    fx, fy = x / P(W), y / P(H)
    top = np.array([34, 44, 92], np.float32)
    bottom = np.array([214, 132, 128], np.float32)
    t = np.clip(fy * 0.75 + fx * 0.25, 0, 1)[..., None]
    base = top * (1 - t) + bottom * t
    glow = np.exp(-(((fx - 0.25) / 0.35) ** 2 + ((fy - 0.85) / 0.35) ** 2))[..., None]
    base = base + glow * np.array([60, 30, 10], np.float32) * 0.6
    glow2 = np.exp(-(((fx - 0.8) / 0.4) ** 2 + ((fy - 0.15) / 0.3) ** 2))[..., None]
    base = base + glow2 * np.array([40, 30, 70], np.float32) * 0.6
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def menubar(img, app, items):
    bar = Image.new("RGBA", (P(W), P(MENU_H)), (250, 250, 252, 205))
    img.alpha_composite(bar, (0, 0))
    d = ImageDraw.Draw(img)
    x = P(16)
    d.text((x, P(5)), app, font=F_MENU, fill=(20, 20, 24, 255))
    x += d.textlength(app, font=F_MENU) + P(20)
    for it in items:
        d.text((x, P(5)), it, font=F_MENU_R, fill=(20, 20, 24, 255))
        x += d.textlength(it, font=F_MENU_R) + P(18)
    clock = "Thu 10:24"
    d.text((P(W) - P(16) - d.textlength(clock, font=F_MENU_R), P(5)), clock, font=F_MENU_R, fill=(20, 20, 24, 255))


def window_shadow(img, box, radius, strength=110, blur=22, dy=14):
    x0, y0, x1, y1 = [P(v) for v in box]
    pad = P(blur * 2)
    layer = Image.new("RGBA", (x1 - x0 + 2 * pad, y1 - y0 + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle([pad, pad + P(dy), pad + x1 - x0, pad + y1 - y0 + P(dy)],
                                            radius=P(radius), fill=(0, 0, 0, strength))
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(P(blur))), (x0 - pad, y0 - pad))


def traffic_lights(d, x, y):
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx = P(x + i * 20)
        d.ellipse([cx, P(y), cx + P(12), P(y + 12)], fill=c + (255,))


FINDER = (64, 82, 470, 352)
FILES = [("Report.pdf", "pdf"), ("Photo.jpg", "photo"), ("Notes.txt", "txt")]


def finder_file_pos(i):
    x0, y0, _, _ = FINDER
    return (x0 + 150 + i * 98, y0 + 112)      # center of the icon


def draw_finder(img):
    x0, y0, x1, y1 = FINDER
    window_shadow(img, FINDER, 12)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([P(x0), P(y0), P(x1), P(y1)], radius=P(12), fill=(255, 255, 255, 255),
                        outline=(200, 200, 206, 255), width=P(1))
    side = Image.new("RGBA", (P(118), P(y1 - y0)), (0, 0, 0, 0))
    ImageDraw.Draw(side).rounded_rectangle([0, 0, P(130), P(y1 - y0)], radius=P(12), fill=(236, 236, 240, 255))
    img.alpha_composite(side, (P(x0), P(y0)))
    d.line([(P(x0 + 118), P(y0)), (P(x0 + 118), P(y1))], fill=(214, 214, 220, 255), width=P(1))
    traffic_lights(d, x0 + 14, y0 + 14)
    d.text((P(x0 + 136), P(y0 + 13)), "Documents", font=F_TITLE, fill=(30, 30, 34, 255))
    d.line([(P(x0 + 118), P(y0 + 42)), (P(x1), P(y0 + 42))], fill=(226, 226, 230, 255), width=P(1))
    f = font("semibold", 10)
    d.text((P(x0 + 14), P(y0 + 46)), "Favorites", font=f, fill=(150, 150, 156, 255))
    for i, name in enumerate(["Desktop", "Documents", "Downloads"]):
        yy = y0 + 64 + i * 24
        if name == "Documents":
            d.rounded_rectangle([P(x0 + 8), P(yy - 3), P(x0 + 110), P(yy + 17)], radius=P(5), fill=(214, 214, 220, 255))
        d.text((P(x0 + 18), P(yy)), name, font=F_SMALL, fill=(40, 40, 44, 255))
    for i, (name, kind) in enumerate(FILES):
        cx, cy = finder_file_pos(i)
        icon = ICON_PDF[52] if kind == "pdf" else ICON_PHOTO if kind == "photo" else ICON_TXT
        img.alpha_composite(icon, (P(cx - 26), P(cy - 26)))
        tw = d.textlength(name, font=F_LABEL)
        d.text((P(cx) - tw / 2, P(cy + 30)), name, font=F_LABEL, fill=(40, 40, 44, 255))


MAIL = (150, 66, 752, 488)
ATTACH = (300, 352)       # where the file is dropped into the email


def mail_layer(attached=False):
    layer = Image.new("RGBA", (P(W), P(H)), (0, 0, 0, 0))
    draw_mail(layer, attached)
    return layer


def draw_mail(img, attached=False):
    x0, y0, x1, y1 = MAIL
    window_shadow(img, MAIL, 12, strength=130, blur=26, dy=18)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([P(x0), P(y0), P(x1), P(y1)], radius=P(12), fill=(255, 255, 255, 255),
                        outline=(200, 200, 206, 255), width=P(1))
    top = Image.new("RGBA", (P(x1 - x0), P(48)), (0, 0, 0, 0))
    ImageDraw.Draw(top).rounded_rectangle([0, 0, P(x1 - x0), P(60)], radius=P(12), fill=(242, 242, 246, 255))
    img.alpha_composite(top, (P(x0), P(y0)))
    d.line([(P(x0), P(y0 + 48)), (P(x1), P(y0 + 48))], fill=(220, 220, 226, 255), width=P(1))
    traffic_lights(d, x0 + 14, y0 + 18)
    d.text((P(x0 + 84), P(y0 + 16)), "New Message", font=F_TITLE, fill=(30, 30, 34, 255))
    # send button
    bx = x1 - 50
    d.ellipse([P(bx), P(y0 + 12), P(bx + 26), P(y0 + 38)], fill=(10, 122, 255, 255))
    d.polygon([(P(bx + 8), P(y0 + 18)), (P(bx + 20), P(y0 + 25)), (P(bx + 8), P(y0 + 32)), (P(bx + 11), P(y0 + 25))],
              fill=(255, 255, 255, 255))
    rows = [("To:", "Alex Morgan"), ("Subject:", "Quarterly report")]
    for i, (k, v) in enumerate(rows):
        yy = y0 + 60 + i * 34
        d.text((P(x0 + 20), P(yy)), k, font=F_BODY, fill=(140, 140, 146, 255))
        d.text((P(x0 + 88), P(yy)), v, font=F_BODY, fill=(30, 30, 34, 255))
        d.line([(P(x0 + 20), P(yy + 24)), (P(x1 - 20), P(yy + 24))], fill=(232, 232, 236, 255), width=P(1))
    d.text((P(x0 + 20), P(y0 + 146)), "Hi Alex,", font=F_BODY, fill=(30, 30, 34, 255))
    d.text((P(x0 + 20), P(y0 + 168)), "here is the report from this morning.", font=F_BODY, fill=(30, 30, 34, 255))
    if attached:
        draw_attachment(img, 1.0)


def draw_attachment(img, a):
    if a <= 0:
        return
    cx, cy = ATTACH
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    layer.alpha_composite(ICON_PDF[46], (P(cx - 23), P(cy - 23)))
    d = ImageDraw.Draw(layer)
    name = "Report.pdf"
    tw = d.textlength(name, font=F_LABEL)
    d.text((P(cx) - tw / 2, P(cy + 26)), name, font=F_LABEL, fill=(40, 40, 44, 255))
    if a < 1:
        layer.putalpha(layer.getchannel("A").point(lambda v: int(v * a)))
    img.alpha_composite(layer)


def build_bases():
    desk = wallpaper()
    draw_finder(desk)
    return desk, mail_layer(), mail_layer(attached=True)


def draw_menubar(img, t, mail_front):
    if mail_front:
        menubar(img, "Mail", ["File", "Edit", "View", "Message", "Format"])
    else:
        menubar(img, "Finder", ["File", "Edit", "View", "Go", "Window"])


# ---------------------------------------------------------------------------
# Shelf shape (port of EdgeBlobShape, right edge)


def bezier(p0, p1, p2, p3, n=14):
    pts = []
    for i in range(1, n + 1):
        t = i / n
        u = 1 - t
        pts.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                    u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
    return pts


def blob_path(edge_x, top, width, height, corner, fillet, stretch, corner_stretch):
    """Outline points; the shape sits flush at edge_x and extends to the left."""
    if width < 0.5 or height < 0.5:
        return []
    rect_h = height
    max_fy = max(0, min(fillet, rect_h / 4))
    r = max(0, min(corner, (rect_h - 2 * max_fy) / 2, width))
    fx = max(0, min(fillet, width - r))
    fy = min(max_fy, fx * stretch)
    bottom = top + rect_h
    body_top = top + fy
    body_bottom = bottom - fy
    ry = max(0, min(r * max(1, corner_stretch), (body_bottom - body_top) / 2))
    k = 0.5523
    inner = edge_x - width
    pts = [(edge_x, top)]
    pts += bezier((edge_x, top), (edge_x, top + k * fy), (edge_x - fx + k * fx, body_top), (edge_x - fx, body_top))
    pts.append((inner + r, body_top))
    pts += bezier((inner + r, body_top), (inner + r - k * r, body_top), (inner, body_top + ry - k * ry), (inner, body_top + ry))
    pts.append((inner, body_bottom - ry))
    pts += bezier((inner, body_bottom - ry), (inner, body_bottom - ry + k * ry), (inner + r - k * r, body_bottom), (inner + r, body_bottom))
    pts.append((edge_x - fx, body_bottom))
    pts += bezier((edge_x - fx, body_bottom), (edge_x - fx + k * fx, body_bottom), (edge_x, bottom - k * fy), (edge_x, bottom))
    return pts


# Shelf states: width, body height, corner, fillet, fillet stretch, corner stretch
def peek_state():
    t = 8 * K
    soft = 0.4
    corner = t * 0.5
    stretch = 1 + soft
    return (t, 64 * K, corner, (t - corner) * stretch + 1, stretch, max(1, 8 * K / max(corner, 0.5)))


PEEK = peek_state()
HIDDEN = (0, PEEK[1] * 0.55) + PEEK[2:]
OPEN = (240 * K, 430 * K, 28 * K, 16 * K, 1.25, 1)

# Level changes: (time, state, response, damping)
SPRING_PEEK = (0.38, 0.72)
SPRING_OPEN = (0.4, 0.7)
SPRING_CLOSE = (0.32, 0.9)
EVENTS = [
    (0.0, HIDDEN, *SPRING_CLOSE),
    (1.50, PEEK, *SPRING_PEEK),     # drag starts: strip appears right away
    (2.42, OPEN, *SPRING_OPEN),     # file near the edge: shelf opens
    (3.78, HIDDEN, *SPRING_CLOSE),  # pointer left the shelf
    (5.78, PEEK, *SPRING_PEEK),     # pointer touches the edge
    (6.18, OPEN, *SPRING_OPEN),     # after the short delay
    (7.12, HIDDEN, *SPRING_CLOSE),  # file dragged out of the shelf
]


def state_at(t):
    idx = max(i for i, e in enumerate(EVENTS) if e[0] <= t)
    start = EVENTS[0][1] if idx == 0 else state_at(EVENTS[idx][0] - 1e-6)
    t0, target, response, damping = EVENTS[idx]
    f = spring(t - t0, response, damping)
    return tuple(lerp(a, b, f) for a, b in zip(start, target))


def content_alpha(t):
    """Contents of the open shelf: blur-fade in after a short delay, quick fade out."""
    a = 0.0
    for t0, state, *_ in EVENTS:
        if t0 > t:
            break
        if state is OPEN:
            a = ramp(t, t0 + 0.07, t0 + 0.35)
        else:
            a = max(0.0, a * (1 - ramp(t, t0, t0 + 0.12))) if a > 0 else 0.0
    return a


# ---------------------------------------------------------------------------
# Icons


def page_icon(size, kind):
    s = P(size)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pw, ph = s * 0.74, s * 0.94
    x0, y0 = (s - pw) / 2, (s - ph) / 2
    fold = pw * 0.26
    body = [(x0, y0), (x0 + pw - fold, y0), (x0 + pw, y0 + fold), (x0 + pw, y0 + ph), (x0, y0 + ph)]
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon([(x + 0, y + s * 0.02) for x, y in body], fill=(0, 0, 0, 70))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s * 0.03)))
    d.polygon(body, fill=(255, 255, 255, 255), outline=(205, 205, 210, 255))
    d.polygon([(x0 + pw - fold, y0), (x0 + pw - fold, y0 + fold), (x0 + pw, y0 + fold)], fill=(226, 226, 232, 255))
    if kind == "pdf":
        for i in range(4):
            yy = y0 + ph * (0.22 + i * 0.1)
            d.rounded_rectangle([x0 + pw * 0.14, yy, x0 + pw * (0.86 if i else 0.6), yy + s * 0.025], radius=s * 0.01,
                                fill=(200, 200, 206, 255))
        d.rounded_rectangle([x0 + pw * 0.12, y0 + ph * 0.66, x0 + pw * 0.88, y0 + ph * 0.86], radius=s * 0.03,
                            fill=(228, 64, 58, 255))
        f = ImageFont.truetype(font("bold", 1).path, int(s * 0.14))
        tw = d.textlength("PDF", font=f)
        d.text((x0 + pw / 2 - tw / 2, y0 + ph * 0.675), "PDF", font=f, fill=(255, 255, 255, 255))
    else:
        for i in range(6):
            yy = y0 + ph * (0.2 + i * 0.11)
            d.rounded_rectangle([x0 + pw * 0.14, yy, x0 + pw * (0.86 if i % 3 else 0.7), yy + s * 0.022],
                                radius=s * 0.01, fill=(196, 196, 202, 255))
    return img


def photo_icon(size):
    s = P(size)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    m = s * 0.08
    box = [m, s * 0.18, s - m, s * 0.82]
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([box[0], box[1] + s * 0.02, box[2], box[3] + s * 0.02], radius=s * 0.06,
                                             fill=(0, 0, 0, 80))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s * 0.03)))
    pic = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    pd = ImageDraw.Draw(pic)
    for y in range(int(box[1]), int(box[3])):
        f = (y - box[1]) / (box[3] - box[1])
        pd.line([(box[0], y), (box[2], y)], fill=(int(lerp(120, 250, f)), int(lerp(170, 200, f)), int(lerp(240, 170, f)), 255))
    pd.polygon([(box[0], box[3]), (box[0] + s * 0.3, s * 0.48), (box[0] + s * 0.5, s * 0.62), (box[0] + s * 0.66, s * 0.44),
                (box[2], box[3])], fill=(60, 110, 90, 255))
    pd.ellipse([s * 0.62, s * 0.26, s * 0.74, s * 0.38], fill=(255, 240, 200, 255))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=s * 0.06, fill=255)
    img.paste(pic, (0, 0), mask)
    ImageDraw.Draw(img).rounded_rectangle(box, radius=s * 0.06, outline=(255, 255, 255, 255), width=max(2, int(s * 0.03)))
    return img


def airdrop_icon(size):
    s = P(size)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    grad = Image.new("RGBA", (s, s))
    gd = ImageDraw.Draw(grad)
    for y in range(s):
        f = y / s
        gd.line([(0, y), (s, y)], fill=(int(lerp(90, 30, f)), int(lerp(190, 120, f)), 255, 255))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([s * 0.06, s * 0.06, s * 0.94, s * 0.94], radius=s * 0.22, fill=255)
    img.paste(grad, (0, 0), mask)
    c = s / 2
    w = max(2, int(s * 0.055))
    for r in (0.3, 0.2):
        d.arc([c - s * r, c - s * r + s * 0.06, c + s * r, c + s * r + s * 0.06], 205, 335, fill=(255, 255, 255, 255), width=w)
    d.polygon([(c, c - s * 0.02), (c - s * 0.08, c + s * 0.18), (c + s * 0.08, c + s * 0.18)], fill=(255, 255, 255, 255))
    return img


def folder_icon(size):
    s = P(size)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([s * 0.06, s * 0.2, s * 0.48, s * 0.36], radius=s * 0.05, fill=(84, 160, 238, 255))
    d.rounded_rectangle([s * 0.06, s * 0.28, s * 0.94, s * 0.84], radius=s * 0.07, fill=(102, 178, 248, 255))
    d.rounded_rectangle([s * 0.06, s * 0.34, s * 0.94, s * 0.84], radius=s * 0.07, fill=(122, 194, 252, 255))
    c = s / 2
    w = max(2, int(s * 0.06))
    d.line([(c, s * 0.44), (c, s * 0.72)], fill=(70, 140, 220, 255), width=w)
    d.line([(c - s * 0.11, s * 0.61), (c, s * 0.73), (c + s * 0.11, s * 0.61)], fill=(70, 140, 220, 255), width=w, joint="curve")
    return img


def cursor_img():
    pts = [(0, 0), (0, 16.5), (4.1, 12.8), (6.7, 18.9), (9.1, 17.9), (6.6, 11.9), (11.7, 11.9)]
    s = P(24)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sh = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(sh).polygon([(P(x + 2.2), P(y + 2.6)) for x, y in pts], fill=(0, 0, 0, 90))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(P(1.2))))
    d = ImageDraw.Draw(img)
    big = [(P(x + 1.5), P(y + 1.5)) for x, y in pts]
    d.polygon(big, fill=(0, 0, 0, 255))
    d.line(big + [big[0]], fill=(255, 255, 255, 255), width=round(P(1.3)), joint="curve")
    return img


ICON_PDF = {sz: page_icon(sz, "pdf") for sz in (52, 40, 46)}
ICON_TXT = page_icon(52, "txt")
ICON_PHOTO = photo_icon(52)
ICON_AIRDROP = airdrop_icon(27)
ICON_FOLDER = folder_icon(27)
CURSOR = cursor_img()

# ---------------------------------------------------------------------------
# Static scenes

F_MENU = font("semibold", 12.5)
F_MENU_R = font("regular", 12.5)
F_LABEL = font("medium", 11)
F_SMALL = font("regular", 11)
F_TITLE = font("semibold", 12.5)
F_BODY = font("regular", 13)


def wallpaper():
    y, x = np.mgrid[0:P(H), 0:P(W)].astype(np.float32)
    fx, fy = x / P(W), y / P(H)
    top = np.array([34, 44, 92], np.float32)
    bottom = np.array([214, 132, 128], np.float32)
    t = np.clip(fy * 0.75 + fx * 0.25, 0, 1)[..., None]
    base = top * (1 - t) + bottom * t
    glow = np.exp(-(((fx - 0.25) / 0.35) ** 2 + ((fy - 0.85) / 0.35) ** 2))[..., None]
    base = base + glow * np.array([60, 30, 10], np.float32) * 0.6
    glow2 = np.exp(-(((fx - 0.8) / 0.4) ** 2 + ((fy - 0.15) / 0.3) ** 2))[..., None]
    base = base + glow2 * np.array([40, 30, 70], np.float32) * 0.6
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def menubar(img, app, items):
    bar = Image.new("RGBA", (P(W), P(MENU_H)), (250, 250, 252, 205))
    img.alpha_composite(bar, (0, 0))
    d = ImageDraw.Draw(img)
    x = P(16)
    d.text((x, P(5)), app, font=F_MENU, fill=(20, 20, 24, 255))
    x += d.textlength(app, font=F_MENU) + P(20)
    for it in items:
        d.text((x, P(5)), it, font=F_MENU_R, fill=(20, 20, 24, 255))
        x += d.textlength(it, font=F_MENU_R) + P(18)
    clock = "Thu 10:24"
    d.text((P(W) - P(16) - d.textlength(clock, font=F_MENU_R), P(5)), clock, font=F_MENU_R, fill=(20, 20, 24, 255))


def window_shadow(img, box, radius, strength=110, blur=22, dy=14):
    x0, y0, x1, y1 = [P(v) for v in box]
    pad = P(blur * 2)
    layer = Image.new("RGBA", (x1 - x0 + 2 * pad, y1 - y0 + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle([pad, pad + P(dy), pad + x1 - x0, pad + y1 - y0 + P(dy)],
                                            radius=P(radius), fill=(0, 0, 0, strength))
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(P(blur))), (x0 - pad, y0 - pad))


def traffic_lights(d, x, y):
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx = P(x + i * 20)
        d.ellipse([cx, P(y), cx + P(12), P(y + 12)], fill=c + (255,))


FINDER = (64, 82, 470, 352)
FILES = [("Report.pdf", "pdf"), ("Photo.jpg", "photo"), ("Notes.txt", "txt")]


def finder_file_pos(i):
    x0, y0, _, _ = FINDER
    return (x0 + 150 + i * 98, y0 + 112)      # center of the icon


def draw_finder(img):
    x0, y0, x1, y1 = FINDER
    window_shadow(img, FINDER, 12)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([P(x0), P(y0), P(x1), P(y1)], radius=P(12), fill=(255, 255, 255, 255),
                        outline=(200, 200, 206, 255), width=P(1))
    side = Image.new("RGBA", (P(118), P(y1 - y0)), (0, 0, 0, 0))
    ImageDraw.Draw(side).rounded_rectangle([0, 0, P(130), P(y1 - y0)], radius=P(12), fill=(236, 236, 240, 255))
    img.alpha_composite(side, (P(x0), P(y0)))
    d.line([(P(x0 + 118), P(y0)), (P(x0 + 118), P(y1))], fill=(214, 214, 220, 255), width=P(1))
    traffic_lights(d, x0 + 14, y0 + 14)
    d.text((P(x0 + 136), P(y0 + 13)), "Documents", font=F_TITLE, fill=(30, 30, 34, 255))
    d.line([(P(x0 + 118), P(y0 + 42)), (P(x1), P(y0 + 42))], fill=(226, 226, 230, 255), width=P(1))
    f = font("semibold", 10)
    d.text((P(x0 + 14), P(y0 + 46)), "Favorites", font=f, fill=(150, 150, 156, 255))
    for i, name in enumerate(["Desktop", "Documents", "Downloads"]):
        yy = y0 + 64 + i * 24
        if name == "Documents":
            d.rounded_rectangle([P(x0 + 8), P(yy - 3), P(x0 + 110), P(yy + 17)], radius=P(5), fill=(214, 214, 220, 255))
        d.text((P(x0 + 18), P(yy)), name, font=F_SMALL, fill=(40, 40, 44, 255))
    for i, (name, kind) in enumerate(FILES):
        cx, cy = finder_file_pos(i)
        icon = ICON_PDF[52] if kind == "pdf" else ICON_PHOTO if kind == "photo" else ICON_TXT
        img.alpha_composite(icon, (P(cx - 26), P(cy - 26)))
        tw = d.textlength(name, font=F_LABEL)
        d.text((P(cx) - tw / 2, P(cy + 30)), name, font=F_LABEL, fill=(40, 40, 44, 255))


MAIL = (150, 66, 752, 488)
ATTACH = (300, 352)       # where the file is dropped into the email


def mail_layer(attached=False):
    layer = Image.new("RGBA", (P(W), P(H)), (0, 0, 0, 0))
    draw_mail(layer, attached)
    return layer


def draw_mail(img, attached=False):
    x0, y0, x1, y1 = MAIL
    window_shadow(img, MAIL, 12, strength=130, blur=26, dy=18)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([P(x0), P(y0), P(x1), P(y1)], radius=P(12), fill=(255, 255, 255, 255),
                        outline=(200, 200, 206, 255), width=P(1))
    top = Image.new("RGBA", (P(x1 - x0), P(48)), (0, 0, 0, 0))
    ImageDraw.Draw(top).rounded_rectangle([0, 0, P(x1 - x0), P(60)], radius=P(12), fill=(242, 242, 246, 255))
    img.alpha_composite(top, (P(x0), P(y0)))
    d.line([(P(x0), P(y0 + 48)), (P(x1), P(y0 + 48))], fill=(220, 220, 226, 255), width=P(1))
    traffic_lights(d, x0 + 14, y0 + 18)
    d.text((P(x0 + 84), P(y0 + 16)), "New Message", font=F_TITLE, fill=(30, 30, 34, 255))
    # send button
    bx = x1 - 50
    d.ellipse([P(bx), P(y0 + 12), P(bx + 26), P(y0 + 38)], fill=(10, 122, 255, 255))
    d.polygon([(P(bx + 8), P(y0 + 18)), (P(bx + 20), P(y0 + 25)), (P(bx + 8), P(y0 + 32)), (P(bx + 11), P(y0 + 25))],
              fill=(255, 255, 255, 255))
    rows = [("To:", "Alex Morgan"), ("Subject:", "Quarterly report")]
    for i, (k, v) in enumerate(rows):
        yy = y0 + 60 + i * 34
        d.text((P(x0 + 20), P(yy)), k, font=F_BODY, fill=(140, 140, 146, 255))
        d.text((P(x0 + 88), P(yy)), v, font=F_BODY, fill=(30, 30, 34, 255))
        d.line([(P(x0 + 20), P(yy + 24)), (P(x1 - 20), P(yy + 24))], fill=(232, 232, 236, 255), width=P(1))
    d.text((P(x0 + 20), P(y0 + 146)), "Hi Alex,", font=F_BODY, fill=(30, 30, 34, 255))
    d.text((P(x0 + 20), P(y0 + 168)), "here is the report from this morning.", font=F_BODY, fill=(30, 30, 34, 255))
    if attached:
        draw_attachment(img, 1.0)


def draw_attachment(img, a):
    if a <= 0:
        return
    cx, cy = ATTACH
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    layer.alpha_composite(ICON_PDF[46], (P(cx - 23), P(cy - 23)))
    d = ImageDraw.Draw(layer)
    name = "Report.pdf"
    tw = d.textlength(name, font=F_LABEL)
    d.text((P(cx) - tw / 2, P(cy + 26)), name, font=F_LABEL, fill=(40, 40, 44, 255))
    if a < 1:
        layer.putalpha(layer.getchannel("A").point(lambda v: int(v * a)))
    img.alpha_composite(layer)


def build_bases():
    wall = wallpaper()
    desk = wall.copy()
    menubar(desk, "Finder", ["File", "Edit", "View", "Go", "Window"])
    draw_finder(desk)
    mail = wall.copy()
    draw_finder(mail)
    menubar(mail, "Mail", ["File", "Edit", "View", "Message", "Format"])
    draw_mail(mail)
    mail_att = wall.copy()
    draw_finder(mail_att)
    menubar(mail_att, "Mail", ["File", "Edit", "View", "Message", "Format"])
    draw_mail(mail_att, attached=True)
    return desk, mail, mail_att


# ---------------------------------------------------------------------------
# Shelf


def shelf_geometry(st):
    w, h, corner, fillet, stretch, cstretch = st
    total = h + 2 * fillet
    return W, CY - total / 2, w, total, corner, fillet, stretch, cstretch


def tile_center(i=0):
    w = OPEN[0]
    col_w = (w - 28) / 3
    return (W - w + 14 + col_w * (i + 0.5), CY - OPEN[1] / 2 + 60)


def draw_shelf_content(layer, state):
    """Contents of the open shelf at full size; masked by the shape afterwards."""
    d = ImageDraw.Draw(layer)
    w, h = OPEN[0], OPEN[1]
    x0 = W - w
    y0 = CY - h / 2
    d.text((P(x0 + 16), P(y0 + 14)), "Shelf", font=font("semibold", 11.5), fill=(255, 255, 255, 235))
    if state["count"]:
        c = "1 item"
        f = font("medium", 10)
        d.text((P(W - 16) - d.textlength(c, font=f), P(y0 + 15)), c, font=f, fill=(255, 255, 255, 120))
    grid_box = [x0 + 10, y0 + 36, W - 10, y0 + h - 64]
    if state["target"] > 0:
        a = state["target"]
        d.rounded_rectangle([P(v) for v in grid_box], radius=P(12), outline=(255, 255, 255, int(70 * a)),
                            width=round(P(1.4)), fill=(255, 255, 255, int(13 * a)))
    if state["tile"] > 0:
        cx, cy = tile_center()
        a = state["tile"]
        sc = state["tile_scale"]
        icon = ICON_PDF[40]
        if sc != 1:
            sz = max(1, int(icon.width * sc))
            icon = icon.resize((sz, sz), Image.LANCZOS)
        if a < 1:
            icon = icon.copy()
            icon.putalpha(icon.getchannel("A").point(lambda v: int(v * a)))
        layer.alpha_composite(icon, (int(P(cx) - icon.width / 2), int(P(cy) - icon.height / 2)))
        f = font("medium", 9)
        name = "Report.pdf"
        d.text((P(cx) - d.textlength(name, font=f) / 2, P(cy + 24)), name, font=f, fill=(255, 255, 255, int(220 * a)))
    elif state["target"] == 0:
        f1, f2 = font("medium", 12), font("regular", 9.5)
        t1 = "Drop here"
        cy = (grid_box[1] + grid_box[3]) / 2
        d.text((P(W - w / 2) - d.textlength(t1, font=f1) / 2, P(cy - 14)), t1, font=f1, fill=(255, 255, 255, 200))
        for i, line in enumerate(["Files, web images,", "links and text"]):
            d.text((P(W - w / 2) - d.textlength(line, font=f2) / 2, P(cy + 6 + i * 13)), line, font=f2,
                   fill=(255, 255, 255, 110))
    # action bar
    by = y0 + h - 52
    cw = (w - 20) / 2
    for i, (icon, label) in enumerate([(ICON_AIRDROP, "AirDrop"), (ICON_FOLDER, "Downloads")]):
        cx = x0 + 10 + cw * (i + 0.5)
        layer.alpha_composite(icon, (int(P(cx) - icon.width / 2), int(P(by))))
        f = font("medium", 8.5)
        d.text((P(cx) - d.textlength(label, font=f) / 2, P(by + 31)), label, font=f, fill=(255, 255, 255, 170))


def draw_shelf(img, t, state):
    st = state_at(t)
    edge, top, w, total, corner, fillet, stretch, cstretch = shelf_geometry(st)
    if w < 0.3:
        return
    region_x = int(P(W - OPEN[0] - 70))
    pts = [(P(x) - region_x, P(y)) for x, y in blob_path(edge, top, w, total, corner, fillet, stretch, cstretch)]
    rw, rh = P(W) - region_x, P(H)
    mask = Image.new("L", (rw, rh), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    layer = Image.new("RGBA", (rw, rh), (0, 0, 0, 0))
    # Shadow of the open shelf
    open_f = clamp((w - PEEK[0]) / (OPEN[0] - PEEK[0]))
    if open_f > 0.02:
        sh = Image.new("RGBA", (rw, rh), (0, 0, 0, 0))
        sm = Image.new("L", (rw, rh), 0)
        ImageDraw.Draw(sm).polygon([(x, y + P(8)) for x, y in pts], fill=int(150 * open_f))
        sh.putalpha(sm.filter(ImageFilter.GaussianBlur(P(14))))
        layer.alpha_composite(sh)
    black = Image.new("RGBA", (rw, rh), (0, 0, 0, 255))
    layer.paste(black, (0, 0), mask)
    # Contents
    ca = content_alpha(t)
    if ca > 0.01:
        content = Image.new("RGBA", (P(W), P(H)), (0, 0, 0, 0))
        draw_shelf_content(content, state)
        content = content.crop((region_x, 0, P(W), P(H)))
        a = content.getchannel("A")
        a = Image.fromarray((np.asarray(a, np.float32) * (np.asarray(mask, np.float32) / 255) * ca).astype(np.uint8))
        content.putalpha(a)
        layer.alpha_composite(content)
    # Thin light outline, not along the screen edge
    d = ImageDraw.Draw(layer)
    d.line(pts, fill=(255, 255, 255, 52), width=P(1), joint="curve")
    img.alpha_composite(layer, (region_x, 0))


# ---------------------------------------------------------------------------
# Timeline

START = (330, 455)
REPORT = finder_file_pos(0)
EDGE_IN = (W - 5, CY + 4)


def cursor_at(t):
    """Pointer position over time (keyframes with eased moves)."""
    keys = [
        (0.0, START), (0.55, START),
        (1.25, REPORT),                               # to the file
        (1.40, REPORT),                               # press
        (2.70, (W - 4, CY - 6)),                      # drag to the edge
        (3.00, (W - 70, CY - 8)),                     # over the open shelf
        (3.25, (W - 72, CY - 8)),                     # drop
        (3.95, (560, 300)),                           # away
        (4.70, (470, 330)),
        (5.15, (470, 330)),
        (5.85, EDGE_IN),                              # to the edge
        (6.25, EDGE_IN),
        (6.70, tile_center()),                        # onto the file in the shelf
        (6.85, tile_center()),
        (7.95, ATTACH),                               # drag into the email
        (8.10, ATTACH),
        (9.25, ATTACH),
        (10.25, START),
        (DURATION, START),
    ]
    for (t0, p0), (t1, p1) in zip(keys, keys[1:]):
        if t0 <= t <= t1:
            f = ease_in_out((t - t0) / (t1 - t0)) if t1 > t0 else 1
            # slight arc on long moves
            arc = math.sin(math.pi * f) * min(40, abs(p1[0] - p0[0]) * 0.08)
            return (lerp(p0[0], p1[0], f), lerp(p0[1], p1[1], f) - arc)
    return START


CAPTIONS = [
    (0.25, 3.85, "1", "Drag a file to the edge of the screen"),
    (3.95, 5.05, "2", "Switch to any app"),
    (5.15, 9.15, "3", "Get it back from the edge"),
]


def draw_caption(img, t):
    for t0, t1, num, text in CAPTIONS:
        a = ramp(t, t0, t0 + 0.3) * (1 - ramp(t, t1 - 0.3, t1))
        if a <= 0:
            continue
        f = font("semibold", 14)
        tmp = ImageDraw.Draw(img)
        tw = tmp.textlength(text, font=f)
        pw = tw + P(56)
        ph = P(36)
        x = (P(W) - pw) / 2
        y = P(H - 58) + (1 - a) * P(6)
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.rounded_rectangle([x, y, x + pw, y + ph], radius=ph / 2, fill=(14, 14, 18, int(205 * a)))
        d.ellipse([x + P(7), y + P(7), x + P(29), y + P(29)], fill=(255, 255, 255, int(255 * a)))
        fn = font("bold", 12)
        d.text((x + P(18) - d.textlength(num, font=fn) / 2, y + P(10)), num, font=fn, fill=(14, 14, 18, int(255 * a)))
        d.text((x + P(40), y + P(9)), text, font=f, fill=(255, 255, 255, int(255 * a)))
        img.alpha_composite(layer)


def selection_highlight(img, a):
    if a <= 0:
        return
    cx, cy = REPORT
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle([P(cx - 32), P(cy - 32), P(cx + 32), P(cy + 30)], radius=P(7), fill=(0, 0, 0, int(28 * a)))
    tw = d.textlength("Report.pdf", font=F_LABEL)
    d.rounded_rectangle([P(cx) - tw / 2 - P(5), P(cy + 29), P(cx) + tw / 2 + P(5), P(cy + 45)], radius=P(4),
                        fill=(10, 100, 230, int(255 * a)))
    d.text((P(cx) - tw / 2, P(cy + 30)), "Report.pdf", font=F_LABEL, fill=(255, 255, 255, int(255 * a)))
    img.alpha_composite(layer)


def ghost(img, pos, icon, a=0.75, scale=1.0):
    if a <= 0:
        return
    ic = icon if scale == 1 else icon.resize((max(1, int(icon.width * scale)),) * 2, Image.LANCZOS)
    ic = ic.copy()
    ic.putalpha(ic.getchannel("A").point(lambda v: int(v * a)))
    img.alpha_composite(ic, (int(P(pos[0]) - ic.width / 2), int(P(pos[1]) - ic.height / 2)))


def shelf_state(t):
    s = {"count": 0, "target": 0.0, "tile": 0.0, "tile_scale": 1.0}
    if 2.55 <= t < 3.3:
        s["target"] = ramp(t, 2.55, 2.75) * (1 - ramp(t, 3.15, 3.3))
    if 3.2 <= t < 7.5:
        s["count"] = 1
        s["tile"] = ramp(t, 3.2, 3.32)
        s["tile_scale"] = 0.85 + 0.15 * spring(t - 3.2, 0.35, 0.6)
        if 6.85 <= t:
            s["tile"] = 0.35                         # source of the drag stays dimmed
    return s


def frame(t, bases):
    desk, mail, mail_att = bases
    img = desk.copy()
    # Mail opens with a short zoom, closes with a quick fade like on macOS
    opening = ramp(t, 4.05, 4.33)
    closing = ramp(t, 9.3, 9.52)
    show_mail = opening * (1 - closing)
    if show_mail > 0:
        layer = mail_att if t >= 8.15 else mail
        if 7.95 <= t < 8.15:
            layer = mail.copy()
            draw_attachment(layer, ramp(t, 7.97, 8.15))
        scale = 0.965 + 0.035 * opening if closing == 0 else 1 - 0.02 * closing
        if scale != 1:
            cx, cy = P((MAIL[0] + MAIL[2]) / 2), P((MAIL[1] + MAIL[3]) / 2)
            sw, sh = int(layer.width * scale), int(layer.height * scale)
            scaled = layer.resize((sw, sh), Image.BILINEAR)
            layer = Image.new("RGBA", layer.size, (0, 0, 0, 0))
            layer.alpha_composite(scaled, (int(cx - cx * scale), int(cy - cy * scale)))
        if show_mail < 1:
            layer = layer.copy()
            layer.putalpha(layer.getchannel("A").point(lambda v: int(v * show_mail)))
        img.alpha_composite(layer)
    draw_menubar(img, t, show_mail > 0.5)

    # Finder: file selected while it is pressed and dragged
    sel = ramp(t, 1.3, 1.4) * (1 - ramp(t, 3.3, 3.5))
    if show_mail < 1:
        selection_highlight(img, sel * (1 - show_mail))

    draw_shelf(img, t, shelf_state(t))

    pos = cursor_at(t)
    # Dragged file
    if 1.42 <= t < 3.25:
        ghost(img, (pos[0] - 6, pos[1] + 2), ICON_PDF[52], a=0.72)
    elif 3.25 <= t < 3.4:                            # drops into the shelf
        f = ramp(t, 3.25, 3.4)
        tc = tile_center()
        ghost(img, (lerp(pos[0] - 6, tc[0], f), lerp(pos[1] + 2, tc[1], f)), ICON_PDF[52], a=0.72 * (1 - f), scale=1 - 0.2 * f)
    if 6.88 <= t < 7.98:
        ghost(img, (pos[0] - 6, pos[1] + 2), ICON_PDF[52], a=0.72)

    img.alpha_composite(CURSOR, (int(P(pos[0]) - P(1.5)), int(P(pos[1]) - P(1.5))))
    draw_caption(img, t)
    return img.convert("RGB").resize((W, H), Image.LANCZOS)


def main():
    bases = build_bases()
    n = int(DURATION * FPS)
    out = ROOT / "docs" / "preview.gif"
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        frames = []
        for i in range(n):
            f = frame(i / FPS, bases)
            if shutil.which("ffmpeg"):
                f.save(tmp / f"f{i:04d}.png")
            else:
                frames.append(f)
            if i % 25 == 0:
                print(f"frame {i}/{n}")
        if shutil.which("ffmpeg"):
            subprocess.run([
                "ffmpeg", "-loglevel", "error", "-y", "-framerate", str(FPS), "-i", str(tmp / "f%04d.png"),
                "-vf", "split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];"
                       "[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
                "-loop", "0", str(out)], check=True)
        else:
            frames[0].save(out, save_all=True, append_images=frames[1:], duration=int(1000 / FPS), loop=0,
                           optimize=True)
    print(f"written {out} ({out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
