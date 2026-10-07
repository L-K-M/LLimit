#!/usr/bin/env python3
"""Validate actual Swift palettes using D65 CIELAB, WCAG contrast and
Machado et al. (2009) severity-1 CVD matrices in linear sRGB.
https://www.inf.ufrgs.br/~oliveira/pubs_files/CVD_Simulation/CVD_Simulation.html

Base Delta E 76 >=12; base+deep >=8 (with labels/position); OKLCH chroma >=0.10;
graphite contrast >=3. Widget-blue contrast is measured separately: graphite
casing/backing is required where identity marks do not clear 3:1 on blue.
"""
import math
from pathlib import Path
import re
import sys

GRAPHITE = "#1D1F27"
WIDGET_BLUE = "#5994F2"

MATRICES = {
    "protan": ((0.152286, 1.052583, -0.204868), (0.114503, 0.786281, 0.099216),
               (-0.003882, -0.048116, 1.051998)),
    "deutan": ((0.367322, 0.860646, -0.227968), (0.280085, 0.672501, 0.047413),
               (-0.011820, 0.042940, 0.968881)),
    "tritan": ((1.255528, -0.076749, -0.178779), (-0.078411, 0.930809, 0.147602),
               (0.004733, 0.691367, 0.303900)),
}


def read_palettes(root):
    formula = (root / "Shared/LimitKindColorScheme.swift").read_text()
    if "target: (0.02, 0.03, 0.06), fraction: 0.36" not in formula or "(value - mean) * 1.5" not in formula:
        raise ValueError("Color variant formula changed; update and rerun validation")
    models = (root / "Packages/QuotaCore/Sources/QuotaCore/Models.swift").read_text()
    standard = []
    for field in ("Session", "Daily", "Weekly", "Monthly", "Other"):
        line = re.search(rf"default{field}HexColors? = (.+)", models).group(1)
        standard.extend(re.findall(r'"(#[0-9A-Fa-f]{6})"', line))
    source = (root / "Packages/QuotaCore/Sources/QuotaCore/LimitKindPalette.swift").read_text()
    palettes = {"standard": [hex_to_rgb(c) for c in standard]}
    for name, fields in re.findall(r"case \.(\w+):\s+return LimitKindColors\((.*?)\)", source, re.S):
        colors = re.findall(r'"(#[0-9A-Fa-f]{6})"', fields)[:6]
        if len(colors) != 6:
            raise ValueError(f"{name}: expected six identity hues")
        palettes[name] = [hex_to_rgb(c) for c in colors]
    return palettes


def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def rgb_to_xyz(r, g, b):
    return (
        r * 0.4124564 + g * 0.3575761 + b * 0.1804375,
        r * 0.2126729 + g * 0.7151522 + b * 0.0721750,
        r * 0.0193339 + g * 0.1191920 + b * 0.9503041,
    )


def xyz_to_lab(x, y, z):
    xn, yn, zn = 0.95047, 1.0, 1.08883

    def f(t):
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116

    return (116 * f(y / yn) - 16, 500 * (f(x / xn) - f(y / yn)), 200 * (f(y / yn) - f(z / zn)))


def hex_to_lab(h):
    return lab_of_rgb(hex_to_rgb(h))


def delta_e(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def chroma(rgb):
    # OKLab/OKLCH uses a normalized chroma scale; CIELAB C*/100 is not equivalent.
    r, g, b = map(srgb_to_linear, rgb)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return math.hypot(a, b)


def luminance(rgb):
    r, g, b = map(srgb_to_linear, rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    l1, l2 = luminance(a), luminance(b)
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)


def deep_rgb(rgb):
    r, g, b = rgb
    tr, tg, tb = 0.02, 0.03, 0.06
    f = 0.36
    dr, dg, db = r * (1 - f) + tr * f, g * (1 - f) + tg * f, b * (1 - f) + tb * f
    mean = (dr + dg + db) / 3

    def spread(v):
        return max(0, min(1, mean + (v - mean) * 1.5))

    dr, dg, db = spread(dr), spread(dg), spread(db)
    return dr, dg, db


def simulate_cvd(rgb, kind):
    linear = tuple(map(srgb_to_linear, rgb))
    transformed = tuple(max(0, min(1, sum(a * b for a, b in zip(row, linear)))) for row in MATRICES[kind])
    return xyz_to_lab(*rgb_to_xyz(*transformed))


def lab_of_rgb(rgb):
    return xyz_to_lab(*rgb_to_xyz(*map(srgb_to_linear, rgb)))


def minimum_distance(labs):
    return min(delta_e(a, b) for i, a in enumerate(labs) for b in labs[i + 1:])


def measurements(colors):
    all_colors = colors + [deep_rgb(c) for c in colors]
    distances = {}
    for vision in ("normal", *MATRICES):
        labs = [lab_of_rgb(c) if vision == "normal" else simulate_cvd(c, vision) for c in all_colors]
        distances[vision] = (minimum_distance(labs[:6]), minimum_distance(labs))
    return (distances, min(chroma(c) for c in all_colors),
            min(contrast(c, hex_to_rgb(GRAPHITE)) for c in all_colors),
            min(contrast(c, hex_to_rgb(WIDGET_BLUE)) for c in all_colors))


def main():
    failed = False
    root = Path(__file__).resolve().parents[1]
    for name, cols in read_palettes(root).items():
        distances, ch, graphite, blue = measurements(cols)
        print(f"== {name} ==")
        for vision, (base, twelve) in distances.items():
            passed = base >= 12 and twelve >= 8
            failed |= not passed
            print(f"  {vision}: base ΔE={base:.2f}, base+deep ΔE={twelve:.2f} {'PASS' if passed else 'FAIL'}")
        passed = ch >= 0.10 and graphite >= 3
        failed |= not passed
        print(f"  chroma={ch:.3f}, graphite contrast={graphite:.2f} {'PASS' if passed else 'FAIL'}")
        print(f"  widget-blue raw contrast={blue:.2f}; graphite casing/backing required below 3:1")
    if failed:
        print("VALIDATION FAILED")
        return 1
    print("VALIDATION PASSED (normal/CVD ΔE, chroma, graphite contrast; blue measured separately)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
