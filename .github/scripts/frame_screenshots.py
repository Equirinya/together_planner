#!/usr/bin/env python3
"""Turn raw simulator screenshots into App Store / Play Store marketing images.

For every PNG in the screenshots folder it builds a polished, store-ready frame:
  * a rich four-colour mesh gradient (the app's onboarding palette) that flows
    continuously across the set of pages for each device,
  * the screenshot with rounded corners, a soft shadow and a slight tilt,
  * a small "Together Planner" logo on top,
  * a catchy headline + explanatory subtitle per feature.

Filenames are expected as "<device>_<page>.png" (e.g. iphone_recipe_detail.png).
Layout varies per page so the set doesn't look static: the tilt direction, the
text/image alignment and the caption position alternate from page to page.

Every image is rendered at the exact pixel size each store expects, so the
output can be uploaded without any further cropping:

    appstore_iphone_6_5   1284 x 2778   (iPhone 16/15/14 Pro Max)
    appstore_ipad_13      2064 x 2752   (iPad Pro M4, 13")
    playstore_phone       1080 x 1920   (9:16 Android phone)
    playstore_tablet_10   1800 x 2560   (10" Android tablet)

Run it standalone on a folder of screenshots:

    python .github/scripts/frame_screenshots.py screenshots

Output PNGs are written to <folder>/framed/<spec>/<page>.png (RGB, no alpha).
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Where the app logo lives, relative to the repo root (two levels up from here).
REPO_ROOT = Path(__file__).resolve().parents[2]
LOGO_PATH = REPO_ROOT / "assets" / "icon" / "icon_transparent_big.png"

# How much of the raw screenshot height to trim (status bar / bottom padding),
# as (top, bottom) fractions per device. Tune each device independently.
CROPS = {
    "iphone": (0.07, 0.04),
    "ipad": (0.02, 0.015),
}
DEFAULT_CROP = (0.03, 0.03)

# Onboarding mesh palette, mapped to the four corners of a 2x2 grid:
# top-left, top-right, bottom-left, bottom-right.
MESH_CORNERS = (
    (93, 246, 170),   # mint
    (76, 216, 90),    # green
    (192, 223, 98),   # lime
    (255, 161, 68),   # orange
)
# Soft palette blobs layered on top of the bilinear blend for an organic,
# mesh-like wobble. Each is (colour, centre_x, centre_y, radius, strength) in
# fractions of the full gradient strip.
MESH_BLOBS = (
    ((120, 250, 180), 0.18, 0.20, 0.45, 0.35),
    ((255, 170, 80), 0.85, 0.85, 0.55, 0.40),
    ((210, 235, 110), 0.55, 0.45, 0.50, 0.25),
)
# Dark wash over the whole canvas, matching the onboarding overlay.
DARK_WASH = 0.12

# The pages, in the order they should flow across the gradient.
PAGE_ORDER = ["recipe", "shopping_list", "smart_meal_plan", "recipe_detail"]

# headline + subtitle per page.
CAPTIONS = {
    "shopping_list": (
        "In sync, every aisle",
        "Shared shopping lists that update for everyone the moment "
        "something is added or ticked off.",
    ),
    "recipe": (
        "Plan meals together",
        "Create a shared cooking plan and decide what's for dinner, together.",
    ),
    "smart_meal_plan": (
        "Smart meal planner",
        "A balanced weekly plan tailored to your tastes, at the tap of a button.",
    ),
    "recipe_detail": (
        "All your recipes in one place",
        "Add and collect all your recipes, beautifully laid out and always at hand.",
    ),
}

# Output targets: name -> (width, height, source device).
SPECS = [
    ("appstore_iphone_6_5", 1284, 2778, "iphone"),
    ("appstore_ipad_13", 2064, 2752, "ipad"),
    ("playstore_phone", 1080, 1920, "iphone"),
    ("playstore_tablet_10", 1800, 2560, "ipad"),
]

# Per-page layout: tilt in degrees, caption position, text/image alignment.
# Tilts are gentle and one screen stays straight so the set doesn't feel busy.
LAYOUTS = [
    {"tilt": -2.5, "caption": "top", "align": "left"},
    {"tilt": 2.5, "caption": "bottom", "align": "right"},
    {"tilt": -2.5, "caption": "bottom", "align": "left"},
    {"tilt": 0, "caption": "top", "align": "center"},
]

_FONT_DIR = Path("/usr/share/fonts/truetype/google-fonts")
_FONTS = {
    "bold": _FONT_DIR / "Poppins-Bold.ttf",
    "medium": _FONT_DIR / "Poppins-Medium.ttf",
    "regular": _FONT_DIR / "Poppins-Regular.ttf",
}


def _font(weight, size):
    path = _FONTS.get(weight)
    if path and path.exists():
        return ImageFont.truetype(str(path), size)
    return ImageFont.load_default(size)


def _page_of(stem):
    return stem.split("_", 1)[1] if "_" in stem else stem


def _device_of(stem):
    return stem.split("_", 1)[0] if "_" in stem else stem


# --- gradient ---------------------------------------------------------------

def _smoothstep(t):
    return t * t * (3 - 2 * t)


def _mesh_strip(width, height):
    """Continuous four-colour mesh gradient as an (H, W, 3) float array."""
    xs = _smoothstep(np.linspace(0, 1, width))[None, :, None]
    ys = _smoothstep(np.linspace(0, 1, height))[:, None, None]
    tl, tr, bl, br = (np.array(c, float) for c in MESH_CORNERS)
    top = tl * (1 - xs) + tr * xs
    bot = bl * (1 - xs) + br * xs
    grid = top * (1 - ys) + bot * ys

    gx = np.linspace(0, 1, width)[None, :]
    gy = np.linspace(0, 1, height)[:, None]
    for colour, cx, cy, radius, strength in MESH_BLOBS:
        d2 = ((gx - cx) ** 2 + (gy - cy) ** 2) / (radius ** 2)
        w = np.exp(-d2)[..., None] * strength
        grid = grid * (1 - w) + np.array(colour, float) * w

    return np.clip(grid, 0, 255)


# --- screenshot styling -----------------------------------------------------

def _rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0], img.size[1]], radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def _prepare_shot(src, device):
    shot = Image.open(src).convert("RGBA")
    w, h = shot.size
    crop_top, crop_bottom = CROPS.get(device, DEFAULT_CROP)
    shot = shot.crop((0, round(h * crop_top), w, round(h * (1 - crop_bottom))))
    return _rounded(shot, round(shot.size[0] * 0.05))


# --- text -------------------------------------------------------------------

def _wrap(draw, text, font, max_w):
    words = text.split()
    lines, line = [], ""
    for word in words:
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=font) <= max_w or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def _draw_lines(canvas, lines, font, top, align, box_left, box_right, fill, line_gap):
    """Draw centre/left/right aligned lines (no shadow). Returns bottom y."""
    draw = ImageDraw.Draw(canvas)
    asc, desc = font.getmetrics()
    line_h = asc + desc + line_gap
    y = top
    for line in lines:
        w = draw.textlength(line, font=font)
        x = box_left if align == "left" else (box_right - w if align == "right" else (box_left + box_right - w) / 2)
        draw.text((x, y), line, font=font, fill=fill)
        y += line_h
    return y


def _apply_scrim(canvas, width, height, ramps):
    """Darken vertical bands behind text for contrast (a smooth wash, not a
    per-glyph shadow). Each ramp is (y0, y1, alpha0, alpha1) in pixels/0-1."""
    col = np.zeros(height, float)
    for y0, y1, a0, a1 in ramps:
        y0, y1 = max(0, int(y0)), min(height, int(y1))
        if y1 > y0:
            col[y0:y1] = np.maximum(col[y0:y1], np.linspace(a0, a1, y1 - y0))
    alpha = np.repeat((col * 255).astype("uint8")[:, None], width, axis=1)
    layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    layer.putalpha(Image.fromarray(alpha, "L"))
    canvas.alpha_composite(layer)


def _logo_row(canvas, width, top, logo):
    """Centre the logo icon + wordmark near the top. Returns bottom y."""
    draw = ImageDraw.Draw(canvas)
    icon_h = round(width * 0.052)
    font = _font("bold", round(width * 0.042))
    text = "Together Planner"
    text_w = draw.textlength(text, font=font)
    gap = round(width * 0.018)
    icon = logo.resize((icon_h, icon_h)) if logo else None
    total = (icon_h + gap if icon else 0) + text_w
    x = (width - total) / 2
    asc, desc = font.getmetrics()
    if icon:
        canvas.alpha_composite(icon, (round(x), round(top + (asc + desc - icon_h) / 2)))
        x += icon_h + gap
    draw.text((x, top), text, font=font, fill="white")
    return top + asc + desc


# --- composition ------------------------------------------------------------

def _caption_metrics(canvas, width, page, max_w, gap):
    draw = ImageDraw.Draw(canvas)
    headline, subtitle = CAPTIONS.get(page, (page.replace("_", " ").title(), ""))
    hf = _font("bold", round(width * 0.072))
    sf = _font("medium", round(width * 0.036))
    hlines = _wrap(draw, headline, hf, max_w)
    slines = _wrap(draw, subtitle, sf, max_w) if subtitle else []
    ha = sum(hf.getmetrics()) + round(width * 0.012)
    sa = sum(sf.getmetrics()) + round(width * 0.010)
    h = len(hlines) * ha
    if slines:
        h += gap + len(slines) * sa
    return h, hlines, slines, hf, sf


def _compose(page, shot, gradient_slice, width, height, layout, logo):
    canvas = Image.fromarray(gradient_slice.astype("uint8"), "RGB").convert("RGBA")
    canvas.alpha_composite(Image.new("RGBA", (width, height), (0, 0, 0, round(255 * DARK_WASH))))

    margin = round(width * 0.07)
    align = layout["align"]
    box_left, box_right = margin, width - margin
    text_max_w = (box_right - box_left) if align == "center" else round(width * 0.78)

    logo_top = round(height * 0.035)
    logo_font = _font("bold", round(width * 0.042))
    logo_bottom = logo_top + sum(logo_font.getmetrics())
    content_top = logo_bottom + round(height * 0.02)

    cap_gap = round(width * 0.02)
    cap_h, hlines, slines, hf, sf = _caption_metrics(canvas, width, page, text_max_w, cap_gap)

    if layout["caption"] == "top":
        cap_top = content_top
        region_top = cap_top + cap_h + round(height * 0.03)
        region_bottom = height - round(height * 0.045)
    else:
        region_top = content_top + round(height * 0.01)
        cap_top = height - round(height * 0.05) - cap_h
        region_bottom = cap_top - round(height * 0.03)

    # Contrast scrim: a soft top band for the logo (+ top caption) and a bottom
    # band when the caption sits low. Peaks where the text is, fades to nothing.
    ramps = [(0, height * 0.16, 0.34, 0.0)]
    if layout["caption"] == "top":
        ramps.append((0, cap_top + cap_h + height * 0.06, 0.44, 0.0))
    else:
        ramps.append((cap_top - height * 0.07, height, 0.0, 0.46))
    _apply_scrim(canvas, width, height, ramps)

    region_h = max(1, region_bottom - region_top)
    scale = min(region_h * 0.97 / shot.height, (width * 0.82) / shot.width)
    dev = shot.resize((max(1, round(shot.width * scale)), max(1, round(shot.height * scale))))
    radius = round(dev.width * 0.05)

    smask = Image.new("L", dev.size, 0)
    ImageDraw.Draw(smask).rounded_rectangle([0, 0, dev.width, dev.height], radius, fill=130)
    shadow_src = Image.new("RGBA", dev.size, (0, 0, 0, 255))
    shadow_src.putalpha(smask)
    shadow_rot = shadow_src.rotate(layout["tilt"], expand=True, resample=Image.BICUBIC)
    dev_rot = dev.rotate(layout["tilt"], expand=True, resample=Image.BICUBIC)

    fit = min(1.0, (width * 0.86) / dev_rot.width, region_h / dev_rot.height)
    if fit < 1.0:
        dev_rot = dev_rot.resize((round(dev_rot.width * fit), round(dev_rot.height * fit)))
        shadow_rot = shadow_rot.resize(dev_rot.size)

    nudge = {"left": 0.06, "right": -0.06, "center": 0.0}[align] * width
    dev_x = round(width / 2 + nudge - dev_rot.width / 2)
    dev_y = round(region_top + (region_h - dev_rot.height) / 2)

    shadow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    shadow.alpha_composite(shadow_rot, (dev_x, dev_y + round(width * 0.02)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(round(width * 0.022)))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(dev_rot, (dev_x, dev_y))

    _logo_row(canvas, width, logo_top, logo)
    y = _draw_lines(canvas, hlines, hf, cap_top, align, box_left, box_right, "white", round(width * 0.012))
    if slines:
        _draw_lines(canvas, slines, sf, y + cap_gap, align, box_left, box_right, "white", round(width * 0.010))

    return canvas.convert("RGB")


# --- driver -----------------------------------------------------------------

def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("screenshots")
    out = root / "framed"
    sources = [p for p in sorted(root.glob("*.png")) if p.parent == root]
    if not sources:
        print("No screenshots found in", root)
        return

    logo = Image.open(LOGO_PATH).convert("RGBA") if LOGO_PATH.exists() else None

    by_device = {}
    for p in sources:
        by_device.setdefault(_device_of(p.stem), []).append(p)
    for files in by_device.values():
        files.sort(key=lambda p: PAGE_ORDER.index(_page_of(p.stem))
                   if _page_of(p.stem) in PAGE_ORDER else len(PAGE_ORDER))

    for name, w, h, device in SPECS:
        files = by_device.get(device, [])
        if not files:
            continue
        strip = _mesh_strip(w * len(files), h)
        for i, src in enumerate(files):
            page = _page_of(src.stem)
            layout = LAYOUTS[i % len(LAYOUTS)]
            shot = _prepare_shot(src, device)
            grad = strip[:, i * w:(i + 1) * w, :]
            img = _compose(page, shot, grad, w, h, layout, logo)
            dst = out / name / f"{page}.png"
            dst.parent.mkdir(parents=True, exist_ok=True)
            img.save(dst, "PNG")
            print("framed", src.name, "->", dst.relative_to(root), img.size)


if __name__ == "__main__":
    main()
