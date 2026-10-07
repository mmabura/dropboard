#!/usr/bin/env python3
"""Erzeugt die Papier-Noise-Textur (256x256, Graustufen, nahtlos kachelbar).

Reproduzierbar: fester Seed. Abhaengigkeiten: numpy, Pillow.
Aufruf:  python3 tools/make_noise.py [ausgabe.png]
Standardausgabe: Sources/BoardPaper/Resources/noise.png

Nahtlos, weil das Rauschen im Frequenzraum (FFT) gefiltert wird. Das Ergebnis ist
per Konstruktion periodisch, Kanten links/rechts und oben/unten passen exakt.
Die Koernung ist horizontal gestreckt (lange Frequenzkomponenten in x), das ergibt
eine leichte Faserstruktur.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

N = 256
SEED = 20261007
MEAN = 0.5      # mittleres Grau (0..1)
STD = 0.22      # Kontrast der Textur; die Deckkraft der Ebene regelt die App

rng = np.random.default_rng(SEED)
fx = np.fft.fftfreq(N)[None, :]
fy = np.fft.fftfreq(N)[:, None]


def filtered(sx: float, sy: float) -> np.ndarray:
    """Weisses Rauschen, gaussgefiltert im Frequenzraum (sx/sy = Bandbreite)."""
    spectrum = np.fft.fft2(rng.standard_normal((N, N)))
    h = np.exp(-0.5 * ((fx / sx) ** 2 + (fy / sy) ** 2))
    out = np.real(np.fft.ifft2(spectrum * h))
    return out / out.std()


grain = filtered(0.35, 0.35)   # feine Koernung
fibre = filtered(0.03, 0.25)   # horizontal gestreckt: Fasern
cloud = filtered(0.02, 0.02)   # sehr weiche Unruhe
v = 0.6 * grain + 0.8 * fibre + 0.3 * cloud
v = (v - v.mean()) / v.std()
img = np.clip((MEAN + STD * v) * 255.0 + 0.5, 0, 255).astype(np.uint8)

out = Path(sys.argv[1]) if len(sys.argv) > 1 else (
    Path(__file__).resolve().parent.parent / "Sources/BoardPaper/Resources/noise.png")
out.parent.mkdir(parents=True, exist_ok=True)
Image.fromarray(img, mode="L").save(out, optimize=True)

# Nahtpruefung: mittlere Differenz ueber den Wrap-Rand vs. im Inneren.
f = img.astype(np.float64)
seam_x = np.abs(f[:, 0] - f[:, -1]).mean()
seam_y = np.abs(f[0, :] - f[-1, :]).mean()
inner_x = np.abs(f[:, 1:] - f[:, :-1]).mean()
inner_y = np.abs(f[1:, :] - f[:-1, :]).mean()
print(f"geschrieben: {out}  ({img.shape[1]}x{img.shape[0]}, mean={f.mean():.1f}, std={f.std():.1f})")
print(f"Naht x/y: {seam_x:.1f}/{seam_y:.1f}   Innen x/y: {inner_x:.1f}/{inner_y:.1f}")
