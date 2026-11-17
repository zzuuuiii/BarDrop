# Product images and preview GIF

The pictures in `docs/images` and `docs/preview.gif` show the real app. CI renders the
shelf, Settings and the shelf states for the GIF from the app's own views
(`testProductShots` in `Tests/BarDropTests/ViewSmokeTests.swift`) and attaches them as
`previews.zip` to the draft release “CI Vorschaubilder”.

```bash
pip install playwright pillow numpy
```

## Pictures

Put the `Produkt_*.png` files from that zip next to these files, add `Resources/AppIcon.png`, then:

```bash
python3 make.py && python3 shoot.py p_hero_en p_actions_en p_stacks_en p_settings_en \
    p_hero_de p_actions_de p_stacks_de p_settings_de
```

Scale the results to 1600 × 1000 and save them as `docs/images/<name>-<lang>.jpg`. The four
pictures share one background, so they read as one surface in the 2 × 2 grid of the README.

## Preview GIF

`gif3.html` and `gif3.js` in the website's dark greys. Since November 2026 the frames are rendered
sharp at 2x with WebKit (`gif3frames.swift`, no Playwright needed), 20 fps, and encoded at
1280 px wide so the README stays sharp on Retina displays:

```bash
swiftc -O gif3frames.swift -o gif3frames && mkdir -p frames && ./gif3frames "$PWD/gif3.html" "$PWD/frames" 20
ffmpeg -framerate 20 -i frames/f%04d.png -vf "scale=1280:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192[p];[b][p]paletteuse=dither=sierra2_4a" -loop 0 preview.gif
```

The pictures use the same dark greys (`#3c3c40` to `#1d1d1f`) as one gradient across all four, and
the shelf always sits on the outer side of the 2 × 2 grid (`make.py`, `base.css`).

### Rendering the frames with Playwright (older way)

`gif3.html` and `gif3.js`: two images from an image search go into the shelf, onto a slide on
another desktop, an archive goes to the Trash and comes back. Put the `GIF3_*.png` files from
the zip next to them, cut the Archive icon out of a shelf shot (its black background made
transparent), then render and encode:

```bash
python3 - <<'PY'
from PIL import Image
import numpy as np
im = np.array(Image.open('GIF3_4.png').convert('RGBA').crop((1032, 652, 1288, 908))).astype(float)
a = np.clip((im[..., :3].max(axis=2) - 8) / 22, 0, 1)
im[..., 3] = a * 255
im[..., :3] = np.where(a[..., None] > 0, np.clip(im[..., :3] / np.maximum(a[..., None], 1e-3), 0, 255), 0)
Image.fromarray(im.astype('uint8')).save('GIF3_archive_icon.png')
PY
python3 gif3shot.py 25
ffmpeg -framerate 25 -i frames3/f%04d.png -vf palettegen=max_colors=192:stats_mode=full pal.png
ffmpeg -framerate 25 -i frames3/f%04d.png -i pal.png -lavfi paletteuse=dither=sierra2_4a -loop 0 preview.gif
```

The last frame equals the first, so the GIF loops without a cut.
