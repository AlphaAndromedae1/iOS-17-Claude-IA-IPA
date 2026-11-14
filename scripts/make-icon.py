#!/usr/bin/env python3
"""Draws the app icon (a chat bubble on a warm gradient) into the asset catalog.

Usage: python3 scripts/make-icon.py   (needs Pillow: pip install pillow)
"""
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # draw large, then downsample for smooth edges
OUT = Path(__file__).resolve().parent.parent / "ClaudeWeb/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

TOP = (230, 138, 104)
BOTTOM = (196, 98, 68)
BUBBLE = (255, 250, 244)
DOTS = (205, 108, 76)


def main() -> None:
    s = SIZE * SCALE
    icon = Image.new("RGB", (s, s))

    # Vertical gradient background. iOS applies the rounded mask itself; the icon must be opaque.
    gradient = ImageDraw.Draw(icon)
    for y in range(s):
        t = y / (s - 1)
        gradient.line([(0, y), (s, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))

    draw = ImageDraw.Draw(icon)
    u = s / 1024

    # Speech bubble body and tail.
    left, top, right, bottom = 212 * u, 262 * u, 812 * u, 702 * u
    draw.rounded_rectangle([left, top, right, bottom], radius=150 * u, fill=BUBBLE)
    draw.polygon([(330 * u, 660 * u), (300 * u, 820 * u), (470 * u, 690 * u)], fill=BUBBLE)

    # Three "typing" dots.
    cy, r = 482 * u, 46 * u
    for cx in (382 * u, 512 * u, 642 * u):
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=DOTS)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon.resize((SIZE, SIZE), Image.LANCZOS).save(OUT, optimize=True)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
