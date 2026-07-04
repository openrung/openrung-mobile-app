"""Generate OpenRung app icons: neon-green power glyph with glow on the
near-black terminal background. Outputs Android legacy + adaptive mipmaps
and the iOS 1024 universal icon."""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

GREEN = (101, 245, 138)        # #65F58A terminal green
BG_EDGE = (3, 6, 4)            # #030604 screen background
BG_CENTER = (10, 31, 18)       # subtle dark-green lift at center
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))


def radial_bg(size: int) -> Image.Image:
    """Dark radial gradient: slightly green center dissolving to near-black."""
    small = 129
    img = Image.new('RGB', (small, small))
    px = img.load()
    maxd = math.hypot(small / 2, small / 2)
    for y in range(small):
        for x in range(small):
            d = math.hypot(x - small / 2, y - small / 2) / maxd
            t = min(1.0, d * 1.25)  # reach edge color a bit before the corners
            px[x, y] = tuple(
                round(c + (e - c) * t) for c, e in zip(BG_CENTER, BG_EDGE)
            )
    return img.resize((size, size), Image.BICUBIC)


# OpenRung ladder logo, reproduced 1:1 from the foundation's
# openrung-ladder.svg: nine rounded rects (two segmented rails + three
# rungs) in a 256 viewBox, rotated 18deg clockwise about (128, 128).
LADDER_RECTS = [
    (101, 52, 13, 38), (101, 94, 13, 47), (101, 145, 13, 59),
    (142, 52, 13, 38), (142, 94, 13, 47), (142, 145, 13, 59),
    (101, 60, 54, 13), (101, 111, 54, 13), (101, 162, 54, 13),
]
LADDER_RADIUS = 3
LADDER_ROTATION = 18  # degrees, clockwise (SVG y-down convention)


def power_glyph(size: int, scale: float = 1.0) -> Image.Image:
    """Ladder logo on a transparent canvas, with a soft neon glow.

    scale shrinks the glyph inside the canvas (for the adaptive-icon safe zone).
    """
    ss = 4  # supersample
    s = size * ss
    layer = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # The SVG artwork spans a 256 box; map it onto the canvas with `scale`
    # applied about the center (the artwork is already centered on 128).
    k = s / 256 * scale
    off = s / 2  # center of canvas
    for x, y, w, h in LADDER_RECTS:
        d.rounded_rectangle(
            [off + (x - 128) * k, off + (y - 128) * k,
             off + (x + w - 128) * k, off + (y + h - 128) * k],
            radius=LADDER_RADIUS * k,
            fill=GREEN + (255,),
        )
    # PIL rotates counterclockwise; the SVG rotates clockwise.
    layer = layer.rotate(-LADDER_ROTATION, resample=Image.BICUBIC, center=(off, off))

    sharp = layer.resize((size, size), Image.LANCZOS)
    # Two-pass glow: wide faint halo + tight bright bloom.
    wide = sharp.filter(ImageFilter.GaussianBlur(size * 0.045))
    tight = sharp.filter(ImageFilter.GaussianBlur(size * 0.012))
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    wide.putalpha(wide.getchannel('A').point(lambda a: a * 55 // 100))
    tight.putalpha(tight.getchannel('A').point(lambda a: a * 75 // 100))
    out.alpha_composite(wide)
    out.alpha_composite(tight)
    out.alpha_composite(sharp)
    return out


def full_icon(size: int) -> Image.Image:
    img = radial_bg(size).convert('RGBA')
    # The SVG artwork carries generous padding of its own; enlarge slightly.
    img.alpha_composite(power_glyph(size, scale=1.12))
    return img


def circle_crop(img: Image.Image) -> Image.Image:
    mask = Image.new('L', img.size, 0)
    d = ImageDraw.Draw(mask)
    d.ellipse([0, 0, img.size[0] - 1, img.size[1] - 1], fill=255)
    out = img.copy()
    out.putalpha(mask)
    return out


RES = os.path.join(REPO, 'android/app/src/main/res')
DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}

master = full_icon(1024)

for density, mult in DENSITIES.items():
    folder = os.path.join(RES, f'mipmap-{density}')
    os.makedirs(folder, exist_ok=True)
    # Legacy launcher icons (48dp base).
    legacy = master.resize((round(48 * mult),) * 2, Image.LANCZOS)
    legacy.save(os.path.join(folder, 'ic_launcher.png'))
    circle_crop(legacy).save(os.path.join(folder, 'ic_launcher_round.png'))
    # Adaptive foreground (108dp base, glyph shrunk into the 66dp safe zone).
    fg_size = round(108 * mult)
    fg = Image.new('RGBA', (fg_size, fg_size), (0, 0, 0, 0))
    fg.alpha_composite(power_glyph(fg_size, scale=0.85))
    fg.save(os.path.join(folder, 'ic_launcher_foreground.png'))

# iOS: single 1024 universal icon, opaque (no alpha allowed).
ios_dir = os.path.join(REPO, 'ios/OpenRung/Images.xcassets/AppIcon.appiconset')
master.convert('RGB').save(os.path.join(ios_dir, 'AppIcon.png'))

# Previews for inspection.
scratch = os.path.dirname(os.path.abspath(__file__))
master.resize((256, 256), Image.LANCZOS).save(os.path.join(scratch, 'icon-preview.png'))
print('icons written')
