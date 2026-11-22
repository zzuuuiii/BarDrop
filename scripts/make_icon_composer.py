"""Erzeugt Resources/AppIcon.icon (Icon-Composer-Dokument) für BarDrop.

Ab macOS 26 rundet und beschattet das System App-Symbole selbst. Fertig gerundete
Bilder (wie Resources/AppIcon.png) legt es in eine graue Kachel. Darum hier nur die
Motive ohne Rundung und Schatten: heller bzw. dunkler Grund als Füllung, Ablage am rechten Rand und
zwei Dokumente als eigene Ebenen.
Benötigt Pillow: pip install pillow
"""
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw

S = 4
N = 1024 * S


def ablage():
    edge_x = N  # rechter Rand der Kachel
    w, h, f, r = 447 * S, 696 * S, 62 * S, 119 * S
    cy = N // 2
    top_y, bot_y = cy - h // 2, cy + h // 2
    m = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle((edge_x - w, top_y + f, edge_x + 2 * r, bot_y - f), radius=r, fill=255)
    # konkave Übergänge zum Rand
    d.rectangle((edge_x - f, top_y, edge_x, top_y + f), fill=255)
    d.ellipse((edge_x - 2 * f, top_y - f, edge_x, top_y + f), fill=0)
    d.rectangle((edge_x - f, bot_y - f, edge_x, bot_y), fill=255)
    d.ellipse((edge_x - 2 * f, bot_y - f, edge_x, bot_y + f), fill=0)
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    img.paste(Image.new("RGBA", (N, N), (0, 0, 0, 255)), (0, 0), m)
    return img, edge_x - w // 2, cy


def dokumente(doc_x, cy):
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    def doc(cx, cy_, angle, shade):
        dw, dh = 186 * S, 236 * S
        layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        box = (cx - dw // 2, cy_ - dh // 2, cx + dw // 2, cy_ + dh // 2)
        ld.rounded_rectangle(box, radius=27 * S, fill=(shade, shade, shade, 255))
        for i in range(3):
            y = box[1] + 65 * S + i * 42 * S
            ld.rounded_rectangle((box[0] + 32 * S, y, box[2] - (32 + i * 27) * S, y + 15 * S),
                                 radius=7 * S, fill=(150, 156, 168, 255))
        canvas.alpha_composite(layer.rotate(angle, center=(cx, cy_), resample=Image.BICUBIC))

    doc(doc_x - 22 * S, cy + 25 * S, 9, 210)
    doc(doc_x + 17 * S, cy - 22 * S, -6, 248)
    return canvas


def main(out):
    assets = out / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    tray, tray_cx, cy = ablage()
    tray.resize((1024, 1024), Image.LANCZOS).save(assets / "Ablage.png")
    dokumente(tray_cx + 12 * S, cy).resize((1024, 1024), Image.LANCZOS).save(assets / "Dokumente.png")
    def c(rgb): return "extended-srgb:" + ",".join(f"{v / 255:.5f}" for v in rgb) + ",1.00000"
    doc = {
        # Hintergrund wie bei Apples eigenen Symbolen: hell weiß, dunkel dunkelgrau. So ist nur die
        # schwarze Ablage am Rand das Logo (Johann 2026-11-20)
        "fill-specializations": [
            {"value": {"linear-gradient": [c((255, 255, 255)), c((232, 233, 237))]}},
            {"appearance": "dark", "value": {"linear-gradient": [c((58, 58, 62)), c((30, 30, 33))]}},
        ],
        "groups": [
            {"layers": [{"image-name": "Dokumente.png", "name": "Dokumente", "glass": False}],
             "shadow": {"kind": "neutral", "opacity": 0.5},
             "translucency": {"enabled": False, "value": 0.5}},
            {"layers": [{"image-name": "Ablage.png", "name": "Ablage", "glass": False}],
             "shadow": {"kind": "neutral", "opacity": 0.5},
             "translucency": {"enabled": False, "value": 0.5}},
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    (out / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")
    print(f"Icon geschrieben: {out}")


if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else
         Path(__file__).resolve().parent.parent / "Resources" / "AppIcon.icon")
