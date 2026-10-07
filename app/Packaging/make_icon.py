#!/usr/bin/env python3
"""Erzeugt das App-Icon von Dropboard als 1024x1024-PNG (RGBA).

Reproduzierbar (keine Zufallswerte ausser der festen Noise-Textur). Abhaengigkeiten: numpy, Pillow.
Aufruf:  python3 app/Packaging/make_icon.py [ausgabe.png]
Standardausgabe: app/Packaging/AppIcon-1024.png  (wird committet)
build-app.sh macht daraus per sips/iconutil die AppIcon.icns (16...1024 inkl. @2x).

Motiv: warmes Off-White-Papier (PaperStyle.paperHex #F4F0E8) mit dezenter Noise (Sources/Dropboard/Resources/noise.png),
oben rechts ein umgeknicktes Eselsohr (Rueckseite minimal dunkler/kuehler, Falzlinie), darauf drei schraeg liegende
kleine Fotos in gedaempften Farben mit hartem Schatten ohne Blur. Graphit (#3A2E22) statt Schwarz, kein Systemblau.

Raster: Big-Sur-Proportionen – Inhaltsflaeche 824x824 bei 100 px Rand, Eckradius ~22,4 % (185 px).
Gerendert wird 2x ueberabgetastet (2048) und mit LANCZOS auf 1024 verkleinert (Kantenglaettung).
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
NOISE = HERE.parent / "Sources" / "Dropboard" / "Resources" / "noise.png"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "AppIcon-1024.png"

K = 2                      # Ueberabtastung
S = 1024 * K
INSET, RADIUS = 100, 185   # Big-Sur-Raster (1x)
EAR = 250                  # Kantenlaenge des umgeknickten Dreiecks (1x)
FLAP_R = 36                # Rundung der Laschen-Spitze (1x)


def hexrgb(h):
    return np.array([(h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF], dtype=np.float32)


PAPER = hexrgb(0xF4F0E8)
BACK = hexrgb(0xE3E2DD)        # Rueckseite: minimal dunkler und kuehler (App: 0xE5E3DD)
GRAPHITE = hexrgb(0x3A2E22)
PHOTO_BORDER = (0xFB, 0xF9, 0xF4)


def noise_field():
    """Graustufen-Noise -0.5..0.5, gekachelt auf S x S (Kachel in 1x-Pixeln, also K-fach vergroessert)."""
    tile = Image.open(NOISE).convert("L")
    tile = tile.resize((tile.width * K, tile.height * K), Image.NEAREST)
    reps = S // tile.width + 1
    big = np.tile(np.asarray(tile, dtype=np.float32) / 255.0, (reps, reps))[:S, :S]
    return big - 0.5


def rounded_mask():
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [INSET * K, INSET * K, (1024 - INSET) * K - 1, (1024 - INSET) * K - 1], radius=RADIUS * K, fill=255)
    return np.asarray(m, dtype=np.float32) / 255.0


def photo(w, h, sky, ground, sun, angle):
    """Kleines Foto: heller Rand, Himmel/Boden, Sonne. Rueckgabe: gedrehtes RGBA-Bild (2x)."""
    w, h = w * K, h * K
    im = Image.new("RGBA", (w, h), PHOTO_BORDER + (255,))
    d = ImageDraw.Draw(im)
    b = 16 * K
    horizon = int(b + (h - 2 * b) * 0.62)
    d.rectangle([b, b, w - b - 1, horizon], fill=sky)
    d.rectangle([b, horizon, w - b - 1, h - b - 1], fill=ground)
    # sanfter Huegel als zweite Bodenfarbe (flache Ellipse, an der Bildkante abgeschnitten)
    hill = tuple(int(c * 0.88) for c in ground)
    hx = int(w * 0.62)
    d.ellipse([hx - int(w * 0.42), horizon - int(h * 0.12), hx + int(w * 0.42), horizon + int(h * 0.30)], fill=hill)
    d.rectangle([b, h - b, w, h], fill=PHOTO_BORDER)       # Huegel nicht in den Rand ragen lassen
    d.rectangle([w - b, b, w, h], fill=PHOTO_BORDER)
    r = int(min(w, h) * 0.085)
    cx, cy = int(w * 0.30), int(b + (horizon - b) * 0.42)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=sun)
    return im.rotate(angle, resample=Image.BICUBIC, expand=True)


def paste_with_hard_shadow(canvas, im, center, offset=(7, 9), alpha=0.45):
    cx, cy = center[0] * K, center[1] * K
    x0, y0 = cx - im.width // 2, cy - im.height // 2
    a = np.asarray(im.split()[3], dtype=np.float32) / 255.0
    shadow = np.zeros((im.height, im.width, 4), dtype=np.uint8)
    shadow[..., :3] = GRAPHITE.astype(np.uint8)
    shadow[..., 3] = (a * alpha * 255).astype(np.uint8)
    canvas.alpha_composite(Image.fromarray(shadow, "RGBA"), (x0 + offset[0] * K, y0 + offset[1] * K))
    canvas.alpha_composite(im, (x0, y0))


def main():
    noise = noise_field()
    mask = rounded_mask()

    ys, xs = np.mgrid[0:S, 0:S].astype(np.float32)
    # Falzlinie von A=(R-EAR, T) nach B=(R, T+EAR); f > 0 = abgeknickte Ecke (aussen)
    R, T = (1024 - INSET) * K, INSET * K
    f = (xs - (R - EAR * K)) - (ys - T)
    outer = f > 0

    # Papier (Vorderseite) ohne die abgeknickte Ecke
    paper_a = np.where(outer, 0.0, mask)
    # Lasche = die umgeknickte Ecke, an der Falzlinie gespiegelt: Dreieck A, B, D=(R-EAR, T+EAR) mit rechtem Winkel
    # unten links (wie das Eselsohr in der App). Die Spiegelung der stark gerundeten Icon-Ecke ergaebe nur eine
    # schmale Sichel; deshalb gerade Kanten und eine kleine Rundung (FLAP_R) an der gespiegelten Ecke D.
    tri = Image.new("L", (S, S), 0)
    ImageDraw.Draw(tri).polygon([(R - EAR * K, T), (R, T + EAR * K), (R - EAR * K, T + EAR * K)], fill=255)
    rr = Image.new("L", (S, S), 0)
    ImageDraw.Draw(rr).rounded_rectangle([R - EAR * K, T - EAR * K, R + EAR * K, T + EAR * K - 1],
                                         radius=FLAP_R * K, fill=255)
    flap_a = (np.asarray(tri, dtype=np.float32) / 255.0) * (np.asarray(rr, dtype=np.float32) / 255.0)
    flap_a = np.where(outer, 0.0, flap_a)

    # Noise wie in der App als graue Ebene ueber dem Papier; hier kraeftiger, damit sie im Icon ueberhaupt traegt
    noise_gain = 255 * 0.14
    paper_rgb = PAPER[None, None, :] + noise[..., None] * noise_gain

    # Rueckseite: gleiche Noise, schmales Falzband (leicht dunkler) direkt am Falz
    dist = -f / np.sqrt(2) / K                       # Abstand zur Falzlinie in 1x-Pixeln (innen positiv)
    band = np.clip(1 - dist / 14.0, 0, 1) * 0.06
    flap_rgb = BACK[None, None, :] + noise[..., None] * noise_gain
    flap_rgb = flap_rgb * (1 - band[..., None]) + GRAPHITE[None, None, :] * band[..., None]

    # Ebene 1: harter Schatten der ganzen Papierform (kein Blur), nach unten
    shape_a = np.maximum(paper_a, flap_a)
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh = np.zeros((S, S, 4), dtype=np.uint8)
    sh[..., :3] = GRAPHITE.astype(np.uint8)
    sh[..., 3] = (np.roll(shape_a, 8 * K, axis=0) * 0.20 * 255).astype(np.uint8)
    canvas.alpha_composite(Image.fromarray(sh, "RGBA"))

    # Ebene 2: Papier-Vorderseite
    pa = np.dstack([np.clip(paper_rgb, 0, 255), paper_a * 255]).astype(np.uint8)
    canvas.alpha_composite(Image.fromarray(pa, "RGBA"))

    # Ebene 3: Fotos (hinten -> vorne) auf eigener Ebene, gedaempfte Farben, harter Schatten;
    # danach auf die Papier-Vorderseite beschnitten (nichts ragt ueber den Rand oder in die abgeknickte Ecke)
    photos = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    paste_with_hard_shadow(photos, photo(290, 220, (0xC7, 0xC0, 0xAA), (0x8C, 0x86, 0x6C), (0xEE, 0xE4, 0xCC), 4),
                           (395, 350))
    paste_with_hard_shadow(photos, photo(330, 250, (0xA9, 0xB8, 0xB0), (0x7A, 0x8C, 0x6B), (0xE6, 0xCD, 0x92), 9),
                           (390, 600))
    paste_with_hard_shadow(photos, photo(300, 230, (0xD8, 0xB9, 0xA4), (0xA4, 0x70, 0x5F), (0xF3, 0xE6, 0xD3), -8),
                           (650, 655))
    ph = np.asarray(photos, dtype=np.float32).copy()
    ph[..., 3] *= paper_a
    canvas.alpha_composite(Image.fromarray(ph.astype(np.uint8), "RGBA"))

    # Ebene 4: Lasche (Rueckseite), kein Schatten
    fa = np.dstack([np.clip(flap_rgb, 0, 255), flap_a * 255]).astype(np.uint8)
    canvas.alpha_composite(Image.fromarray(fa, "RGBA"))

    # Ebene 5: Falzlinie (Graphit) + heller Haarstrich daneben auf der Lasche
    line = (np.abs(dist) < 1.1) & (flap_a > 0.5)
    hi = (dist > 1.6) & (dist < 2.8) & (flap_a > 0.5)
    lines = np.zeros((S, S, 4), dtype=np.uint8)
    lines[line, :3] = GRAPHITE.astype(np.uint8)
    lines[line, 3] = int(0.28 * 255)
    lines[hi, :3] = 255
    lines[hi, 3] = int(0.45 * 255)
    canvas.alpha_composite(Image.fromarray(lines, "RGBA"))

    # Ebene 6: feiner Kantenstrich der Papierform (Lesbarkeit auf hellem Finder-Hintergrund)
    shape_img = Image.fromarray((shape_a * 255).astype(np.uint8), "L")
    eroded = np.asarray(shape_img.filter(ImageFilter.MinFilter(2 * K + 1)), dtype=np.float32) / 255.0
    edge = np.clip(shape_a - eroded, 0, 1)
    # dazu die beiden Papierkanten der Lasche (wie earEdgeAlpha in der App), damit sie sich vom Papier abhebt
    flap_img = Image.fromarray((flap_a * 255).astype(np.uint8), "L")
    flap_er = np.asarray(flap_img.filter(ImageFilter.MinFilter(2 * K + 1)), dtype=np.float32) / 255.0
    edge = np.maximum(edge, np.clip(flap_a - flap_er, 0, 1))
    ed = np.zeros((S, S, 4), dtype=np.uint8)
    ed[..., :3] = GRAPHITE.astype(np.uint8)
    ed[..., 3] = (edge * 0.16 * 255).astype(np.uint8)
    canvas.alpha_composite(Image.fromarray(ed, "RGBA"))

    canvas = canvas.resize((1024, 1024), Image.LANCZOS)
    canvas.save(OUT, optimize=True)
    print(f"geschrieben: {OUT} ({OUT.stat().st_size} Bytes)")


if __name__ == "__main__":
    main()
