#!/usr/bin/env python3
"""Erzeugt die Papier-Noise-Textur (256x256, Graustufen, nahtlos kachelbar).

Reproduzierbar: fester Seed. Abhaengigkeiten: numpy, Pillow.
Aufruf:  python3 app/tools/make_noise.py [ausgabe.png]
Standardausgabe: app/Sources/Dropboard/Resources/noise.png

Nahtlos, weil das Rauschen im Frequenzraum (FFT) gefiltert wird: das Ergebnis ist
per Konstruktion periodisch, Kanten links/rechts und oben/unten passen exakt.

Version 2 (Optik-Feinschliff): feinere Koernung, nur noch leichte horizontale
Streckung (Korrelationslaenge x:y ~1.7:1 statt ~6:1), geringerer Kontrast, Mittelwert 128.
Die Ebene wird in der App mit PaperStyle.noiseOpacity ueber das Papier gelegt.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

N = 256
SEED = 20261007
MEAN = 128.0    # Zielmittelwert (0..255)
STD = 34.0      # Ziel-Standardabweichung (v1: 55); die Deckkraft regelt die App

rng = np.random.default_rng(SEED)
fx = np.fft.fftfreq(N)[None, :]
fy = np.fft.fftfreq(N)[:, None]


def filtered(sx: float, sy: float) -> np.ndarray:
    """Weisses Rauschen, gaussgefiltert im Frequenzraum (sx/sy = Bandbreite; kleiner = groeber)."""
    spectrum = np.fft.fft2(rng.standard_normal((N, N)))
    h = np.exp(-0.5 * ((fx / sx) ** 2 + (fy / sy) ** 2))
    out = np.real(np.fft.ifft2(spectrum * h))
    return out / out.std()


grain = filtered(0.30, 0.30)   # feine, isotrope Koernung
fibre = filtered(0.08, 0.14)   # nur leicht horizontal gestreckt (~1.75:1)
cloud = filtered(0.02, 0.02)   # sehr weiche Unruhe, kaum Anteil
v = 0.50 * grain + 0.80 * fibre + 0.15 * cloud
v = (v - v.mean()) / v.std()
img = np.clip(MEAN + STD * v + 0.5, 0, 255).astype(np.uint8)

out = Path(sys.argv[1]) if len(sys.argv) > 1 else (
    Path(__file__).resolve().parent.parent / "Sources/Dropboard/Resources/noise.png")
out.parent.mkdir(parents=True, exist_ok=True)
Image.fromarray(img, mode="L").save(out, optimize=True)

# Messung: Mittelwert/Std, Autokorrelation x vs. y (Halbwertslag), Naht.
f = img.astype(np.float64)
d = f - f.mean()
ac = np.real(np.fft.ifft2(np.abs(np.fft.fft2(d)) ** 2)) / (d.var() * d.size)


def corr_len(profile, t=0.3) -> float:
    """Lag (px, interpoliert), bei dem die Autokorrelation unter t faellt."""
    for i in range(1, len(profile)):
        if profile[i] < t:
            return i - 1 + (profile[i - 1] - t) / (profile[i - 1] - profile[i])
    return float(len(profile))


hx, hy = corr_len(ac[0, :N // 2]), corr_len(ac[:N // 2, 0])
print(f"geschrieben: {out}  ({N}x{N}, mean={f.mean():.1f}, std={f.std():.1f})")
print(f"Autokorrelation lag1 x/y={ac[0,1]:.3f}/{ac[1,0]:.3f}  Korrelationslaenge(0.3) x/y={hx:.1f}/{hy:.1f} px  Anisotropie={hx/max(hy,1):.2f}")
print(f"Naht x/y={np.abs(f[:,0]-f[:,-1]).mean():.2f}/{np.abs(f[0,:]-f[-1,:]).mean():.2f}  "
      f"Innen x/y={np.abs(f[:,1:]-f[:,:-1]).mean():.2f}/{np.abs(f[1:,:]-f[:-1,:]).mean():.2f}")
