"""Erzeugt den Hintergrund des Installationsfensters (Resources/dmg-background*.png).

Hell gestaltet: Der Finder zeigt Fenster mit Hintergrundbild immer im hellen
Erscheinungsbild, die Dateinamen also in dunkler Schrift. Maße in Punkten wie
in scripts/dmg_settings.py (600 × 400, Symbole bei x = 165 und 435, y = 185).
Benötigt Pillow und die Schrift Inter.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

W, H = 600, 400
ICON_Y = 185
ROOT = Path(__file__).resolve().parent.parent
FONT_DIRS = [Path("/usr/share/fonts/opentype/inter"), Path.home() / "Library/Fonts", Path("/Library/Fonts")]


def font(name, size):
    for d in FONT_DIRS:
        p = d / name
        if p.exists():
            return ImageFont.truetype(str(p), size)
    return ImageFont.load_default()


def render(scale):
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h))
    px = img.load()
    # sehr sanfter Verlauf von oben nach unten
    top, bottom = (250, 250, 252), (238, 238, 241)
    for y in range(h):
        t = y / (h - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c

    d = ImageDraw.Draw(img)
    s = scale
    # Pfeil zwischen den Symbolen
    y = ICON_Y * s
    x0, x1 = 262 * s, 338 * s
    color = (174, 174, 178)
    d.line([(x0, y), (x1, y)], fill=color, width=round(2.5 * s))
    head = 9 * s
    d.line([(x1 - head, y - head), (x1, y), (x1 - head, y + head)], fill=color,
           width=round(2.5 * s), joint="curve")

    text = "Drag BarDrop to the Applications folder to install it"
    f = font("Inter-Medium.otf", 13 * s)
    tw = d.textlength(text, font=f)
    d.text(((w - tw) / 2, 318 * s), text, font=f, fill=(134, 134, 139))
    return img


if __name__ == "__main__":
    out = ROOT / "Resources"
    render(1).save(out / "dmg-background.png")
    render(2).save(out / "dmg-background@2x.png")
    print("Background written")
