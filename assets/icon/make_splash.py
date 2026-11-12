"""Generate OpenRung splash-screen artwork: the neon ladder logo and the
bilingual slogan, on the #030604 terminal background.

Outputs:
  Android  res/drawable-<density>/splash_logo.png      (288dp, 12+ icon rules)
           res/drawable-<density>/splash_branding.png  (200x80dp slogan)
  iOS      Images.xcassets/SplashLogo.imageset         (288pt logo; the
           slogan is live text in LaunchScreen.storyboard)

The slogan is rasterised because Android's system splash (API 31+) only takes
images. Fonts are not vendored; pass two OFL fonts:

  python3 make_splash.py --mono NotoSansMono.ttf --cjk NotoSansTC.ttf
"""
import argparse
import json
import os

from PIL import Image, ImageDraw, ImageFont

from make_icons import REPO, power_glyph

DIM_TEXT = (125, 169, 137)      # #7DA989 palette.dimText (home-screen slogan)
GREEN = (101, 245, 138)         # #65F58A palette.terminalGreen
SLOGAN_EN = ('Internet access is a right,', 'not a privilege')
SLOGAN_ZH = '互聯網本非特權'

RES = os.path.join(REPO, 'android/app/src/main/res')
DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
LOGO_DP = 288     # Android 12 icon-without-background canvas
LOGO_SCALE = 0.95  # keeps the glyph inside the 192dp mask circle
BRAND_W, BRAND_H = 200, 80  # Android 12 branding-image box


def logo(size: int) -> Image.Image:
    return power_glyph(size, scale=LOGO_SCALE)


def branding(mult: float, mono: str, cjk: str) -> Image.Image:
    ss = 4  # supersample, then downscale for clean edges
    k = mult * ss
    w, h = round(BRAND_W * k), round(BRAND_H * k)
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    en = ImageFont.truetype(mono, round(11.5 * k))
    zh = ImageFont.truetype(cjk, round(14 * k))
    zh.set_variation_by_axes([500])
    lines = [(t, en, DIM_TEXT, 17) for t in SLOGAN_EN] + [(SLOGAN_ZH, zh, GREEN, 24)]
    total = sum(lh for *_, lh in lines) * k
    y = (h - total) / 2
    for text, font, color, lh in lines:
        tracking = 0.25 * k if font is en else 3 * k
        widths = [d.textlength(c, font=font) for c in text]
        x = (w - sum(widths) - tracking * (len(text) - 1)) / 2
        cy = y + lh * k / 2
        for c, cw in zip(text, widths):
            d.text((x, cy), c, font=font, fill=color + (255,), anchor='lm')
            x += cw + tracking
        y += lh * k
    return img.resize((round(BRAND_W * mult), round(BRAND_H * mult)), Image.LANCZOS)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--mono', required=True, help='monospace TTF (e.g. Noto Sans Mono)')
    ap.add_argument('--cjk', required=True, help='Traditional Chinese TTF (e.g. Noto Sans TC)')
    args = ap.parse_args()

    for density, mult in DENSITIES.items():
        folder = os.path.join(RES, f'drawable-{density}')
        os.makedirs(folder, exist_ok=True)
        logo(round(LOGO_DP * mult)).save(os.path.join(folder, 'splash_logo.png'), optimize=True)
        branding(mult, args.mono, args.cjk).save(
            os.path.join(folder, 'splash_branding.png'), optimize=True)

    ios_dir = os.path.join(REPO, 'ios/OpenRung/Images.xcassets/SplashLogo.imageset')
    os.makedirs(ios_dir, exist_ok=True)
    images = []
    for scale in (1, 2, 3):
        name = f'SplashLogo@{scale}x.png' if scale > 1 else 'SplashLogo.png'
        logo(LOGO_DP * scale).save(os.path.join(ios_dir, name), optimize=True)
        images.append({'filename': name, 'idiom': 'universal', 'scale': f'{scale}x'})
    with open(os.path.join(ios_dir, 'Contents.json'), 'w') as f:
        json.dump({'images': images, 'info': {'author': 'xcode', 'version': 1}}, f, indent=2)
        f.write('\n')
    print('splash written')


if __name__ == '__main__':
    main()
