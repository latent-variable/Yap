#!/usr/bin/env python3
"""Compose docs/yap-ui.png, the README's hero image, from `--uishot` renders.

    cd app && "$(swift build --show-bin-path)/Yap" --uishot /tmp/yap-ui
    python3 scripts/make_readme_art.py /tmp/yap-ui

The Settings window (Voices, Pocket, dark) with the menu popover (Ears, dark)
over it, on the brand gradient from Views/Theme.swift. Needs Pillow.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

STOPS = [(0x7D, 0x5C, 0xFF), (0xDB, 0x27, 0x77), (0xFA, 0x6B, 0x5C)]  # violet, magenta, coral
W, H = 1800, 1060


def gradient():
    bg = Image.new("RGB", (W, H))
    px = bg.load()
    for y in range(H):
        for x in range(W):
            t = x / W * 0.6 + y / H * 0.4
            a, b, u = (STOPS[0], STOPS[1], t / 0.62) if t < 0.62 else (STOPS[1], STOPS[2], (t - 0.62) / 0.38)
            px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * u) for i in range(3))
    return bg.convert("RGBA")


def place(bg, img, xy, radius, blur=40):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius, fill=255)
    shadow = Image.new("RGBA", (img.width + blur * 4, img.height + blur * 4), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [blur * 2, blur * 2 + blur // 2, blur * 2 + img.width, blur * 2 + blur // 2 + img.height],
        radius, fill=(20, 0, 30, 140))
    bg.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)), (xy[0] - blur * 2, xy[1] - blur * 2))
    im = img.convert("RGBA")
    im.putalpha(mask)
    bg.alpha_composite(im, xy)


def main(shots: Path):
    bg = gradient()
    settings = Image.open(shots / "settings-voice-pocket-dark.png")
    if settings.width < 1200:   # a 1x capture: scale up to sit beside the 2x popover
        settings = settings.resize((int(settings.width * 1.5), int(settings.height * 1.5)), Image.LANCZOS)
    pop = Image.open(shots / "menu-ears-dark.png")
    pop = pop.resize((int(pop.width * 0.95), int(pop.height * 0.95)), Image.LANCZOS)
    place(bg, settings, (80, (H - settings.height) // 2), 18)
    place(bg, pop, (W - pop.width - 90, (H - pop.height) // 2 + 20), 26)
    out = Path(__file__).resolve().parent.parent / "docs" / "yap-ui.png"
    bg.convert("RGB").save(out, optimize=True)
    print(f"wrote {out}")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/yap-ui"))
