#!/usr/bin/env python3
"""Render every platform's home-screen icon from the two source layers.

Sources (1024x1024):
  assets/icon/background.png  - opaque background layer
  assets/icon/foreground.png  - the mark on a transparent canvas

Run from the repo root:  python3 tool/generate_app_icons.py   (needs Pillow)

The in-app mark (assets/app_icon.png) is deliberately left alone.
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
BG = Image.open(ROOT / "assets/icon/background.png").convert("RGBA")
FG = Image.open(ROOT / "assets/icon/foreground.png").convert("RGBA")
MARK = FG.crop(FG.getbbox())  # tight crop of the logo
WORDMARK_FONT = ROOT / "assets/fonts/SpaceGrotesk-Bold.ttf"
INK = (11, 21, 48, 255)


def save(img: Image.Image, rel: str, rgb: bool = False) -> None:
    path = ROOT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    (img.convert("RGB") if rgb else img).save(path, optimize=True)


def mark(height: int) -> Image.Image:
    w = round(MARK.width * height / MARK.height)
    return MARK.resize((w, height), Image.LANCZOS)


def paste_center(canvas: Image.Image, im: Image.Image, cx: float, cy: float) -> None:
    canvas.alpha_composite(im, (round(cx - im.width / 2), round(cy - im.height / 2)))


def background(w: int, h: int) -> Image.Image:
    return BG.resize((w, h), Image.LANCZOS)


def flat(size: int, mark_frac: float = 0.62) -> Image.Image:
    """Full-bleed square; the OS applies its own mask (iOS, Android, web maskable)."""
    c = background(size, size)
    paste_center(c, mark(round(size * mark_frac)), size / 2, size / 2)
    return c


def tile(size: int, tile_frac: float = 0.805, shadow: bool = True) -> Image.Image:
    """Rounded tile on transparency, for platforms that don't mask (macOS, Windows, Linux, web)."""
    ss = 4  # supersample for smooth corners
    S = size * ss
    t = round(S * tile_frac)
    off = (S - t) // 2
    radius = round(t * 0.2237)
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((off, off, off + t, off + t), radius, fill=255)
    if shadow:
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        sh_mask = mask.transform(mask.size, Image.AFFINE, (1, 0, 0, 0, 1, -round(t * 0.012)))
        sh.putalpha(sh_mask.point(lambda v: v * 0.32))
        canvas.alpha_composite(sh.filter(ImageFilter.GaussianBlur(t * 0.022)))
    face = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    face.paste(background(t, t), (off, off))
    face.putalpha(mask)
    canvas.alpha_composite(face)
    paste_center(canvas, mark(round(t * 0.62)), S / 2, S / 2)
    return canvas.resize((size, size), Image.LANCZOS)


def lockup(w: int, h: int, mark_frac: float, text_frac: float, with_bg: bool = True) -> Image.Image:
    """Logo + "Debrify" wordmark, for TV banners and the tvOS top shelf."""
    c = background(w, h) if with_bg else Image.new("RGBA", (w, h), (0, 0, 0, 0))
    m = mark(round(h * mark_frac))
    font = ImageFont.truetype(str(WORDMARK_FONT), round(h * text_frac))
    text = "Debrify"
    l, t, r, b = font.getbbox(text)
    gap = round(m.height * 0.28)
    total = m.width + gap + (r - l)
    x = (w - total) / 2
    paste_center(c, m, x + m.width / 2, h / 2)
    ImageDraw.Draw(c).text((x + m.width + gap - l, h / 2 - (t + b) / 2), text, font=font, fill=INK)
    return c


def ios() -> None:
    d = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for img in json.loads((ROOT / d / "Contents.json").read_text())["images"]:
        if "filename" not in img:
            continue
        px = round(float(img["size"].split("x")[0]) * int(img["scale"][0]))
        save(flat(px), f"{d}/{img['filename']}", rgb=True)  # App Store rejects alpha


def macos() -> None:
    d = "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for px in (16, 32, 64, 128, 256, 512, 1024):
        save(tile(px, shadow=px >= 64), f"{d}/app_icon_{px}.png")


def android() -> None:
    res = "android/app/src/main/res"
    for density, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        save(tile(px, tile_frac=0.92, shadow=False), f"{res}/mipmap-{density}/ic_launcher.png")
        # Adaptive foreground (108dp canvas); ic_launcher.xml insets it by 16%.
        save(FG.resize((px * 9 // 4, px * 9 // 4), Image.LANCZOS), f"{res}/drawable-{density}/ic_launcher_foreground.png")
    # Android TV launcher banner (16:9 at 320x180dp).
    for folder in ("drawable", "drawable-xhdpi", "drawable-xxhdpi", "drawable-xxxhdpi"):
        path = ROOT / res / folder / "banner_debrify.png"
        if path.exists():
            w, h = Image.open(path).size
            save(lockup(w, h, 0.5, 0.26), f"{res}/{folder}/banner_debrify.png", rgb=True)


def tvos() -> None:
    base = ROOT / "tvos/Runner/Assets.xcassets/AppIcon.brandassets"
    for stack in base.glob("*.imagestack"):
        for layer in stack.glob("*.imagestacklayer"):
            for png in layer.glob("Content.imageset/*.png"):
                w, h = Image.open(png).size
                if layer.name.startswith("Back"):
                    im = background(w, h)
                elif layer.name.startswith("Front"):
                    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
                    paste_center(im, mark(round(h * 0.6)), w / 2, h / 2)
                else:
                    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
                save(im, str(png.relative_to(ROOT)))
    for png in base.glob("Top Shelf*.imageset/*.png"):
        w, h = Image.open(png).size
        save(lockup(w, h, 0.36, 0.2), str(png.relative_to(ROOT)), rgb=True)


def windows() -> None:
    tile(256, shadow=False).save(
        ROOT / "windows/runner/resources/app_icon.ico",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )


def web() -> None:
    save(tile(32, shadow=False), "web/favicon.png")
    for px in (192, 512):
        save(tile(px), f"web/icons/Icon-{px}.png")
        save(flat(px, mark_frac=0.5), f"web/icons/Icon-maskable-{px}.png")


def shared() -> None:
    # Used by Linux packaging and the SideStore source.
    save(tile(512), "assets/icon/app_icon_rounded.png")
    save(flat(1024), "assets/icon/app_icon_flat.png", rgb=True)


if __name__ == "__main__":
    for step in (ios, macos, android, tvos, windows, web, shared):
        step()
        print(f"{step.__name__}: done")
