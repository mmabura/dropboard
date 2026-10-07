# Spike: Board-Panel mit Papier-Textur

Eigenständiges SwiftPM-Executable (macOS 14+, Swift-5-Sprachmodus, keine Dependencies, keine Info.plist).
Prüft den Look „Papier“ aus `docs/briefing.md`: Off-White-Canvas, Noise-Ebene, harte Schatten, Zufallsrotation, abgedunkeltes Papier.
**Status: nicht kompiliert, nicht ausgeführt** (Entwicklung im Linux-Container). Alle Verhaltensaussagen müssen auf dem Mac geprüft werden.

## Build und Start

```sh
cd spikes/board-paper
swift build
swift run board-paper                      # 6 Platzhalterbilder
swift run board-paper --images ~/Pictures/test   # eigene Bilder (png, jpg, heic, gif, tiff, bmp; nach Name sortiert)
```

Das Board deckt den Bildschirm unter dem Mauszeiger ab (Level `.statusBar`, nicht aktivierendes Panel, über Fullscreen-Spaces).

## Bedienung

| Eingabe | Wirkung |
|---|---|
| Klick aufs Papier | nächstes Bild an der Klickposition ablegen (Mittelpunkt aufs 24-pt-Grid gesnappt, ±1–2° rotiert) |
| `D` | abgedunkeltes Papier umschalten (Graphit, Deckkraft 0,35) |
| `N` | Noise-Ebene an/aus (Vergleich) |
| `Esc` | beenden |

Erreicht `Esc` das Panel nicht (nicht aktivierendes Panel in inaktiver App), einmal ins Papier klicken, danach ist das Panel key.

## Konstanten

Alle visuellen Werte stehen in `enum PaperStyle` (`Sources/BoardPaper/PaperStyle.swift`): Papierfarbe, Graphit, `noiseOpacity` (0,06), `dimOpacity` (0,35), Grid (24 pt), Bildkante (220 pt), Rotationsbereich, Schattenoffset/-deckkraft.

## Noise-Textur neu erzeugen

```sh
python3 tools/make_noise.py      # braucht numpy und Pillow; fester Seed, schreibt Sources/BoardPaper/Resources/noise.png
```

256×256, Graustufen, nahtlos (FFT-gefiltertes Rauschen ist periodisch), horizontal gestreckte Körnung als Faserandeutung.
Die Textur wird beim Start einmal per `CGContext.draw(_:in:byTiling:)` 1:1 in Device-Pixeln auf Bildschirmgröße gekachelt und als `contents` einer Ebene gesetzt.

## Was Max visuell prüfen soll

Bei 100 % (kein Zoom), auf einem Retina-Display und, falls vorhanden, zusätzlich auf einem 1x-Display:

- [ ] **Off-White:** Das Papier wirkt warm, nicht reinweiß (Vergleich mit einem weißen Fenster daneben), flach, ohne Vignette und ohne Verlauf.
- [ ] **Noise gerade sichtbar:** Mit `N` umschalten: Mit Noise ist eine leichte Faserstruktur zu erahnen, ohne Noise ist die Fläche glatt. Die Textur darf nicht als Muster auffallen, keine sichtbaren Kachelnähte (Nähte würden sich alle 256 px wiederholen). Falls zu stark/zu schwach: `noiseOpacity` anpassen und den gewünschten Wert melden.
- [ ] **Harter Schatten ohne Blur:** Unter jedem Bild ein scharf begrenzter Schatten, 1–2 pt nach unten rechts, keine weichen Ränder. Zoom-Screenshot auf Retina und 1x vergleichen.
- [ ] **Rotation ±1–2°:** Bilder wirken von Hand abgelegt, nicht gekippt-schief. Kanten sind glatt (kein Treppeneffekt), kein heller oder dunkler Halo am Schatten.
- [ ] **Snap:** Bildmitten liegen auf einem unsichtbaren Raster (mehrere Bilder in einer Reihe ablegen, Mittelpunkte fluchten), das Raster selbst ist nirgends zu sehen.
- [ ] **Hart eingeblendet:** Bilder erscheinen ohne Überblendung, ohne Bewegung.
- [ ] **Abgedunkeltes Papier (`D`):** Wirkt wie dunkleres Papier (warmes Graphit-Grau, Textur noch erkennbar), nicht wie eine schwarze, durchscheinende Folie.
- [ ] **Typografie:** Hilfezeile unten links in Monospace, dunkles Graphit, kein Systemblau.
- [ ] **Fenster:** Board liegt über einem Fullscreen-Space (z. B. Safari im Vollbild), die Ursprungs-App bleibt aktiv (Menüleiste wechselt nicht), kein Fensterschatten, kein Eintrag im Dock/⌘-Tab.

## Offene API-Annahmen (alle im Code als `⚠️ VERIFIZIEREN` markiert)

- `makeKey()` auf einem nicht aktivierenden Panel einer inaktiven App liefert Tastaturereignisse (sonst erst nach Klick).
- Root-Layer-Frame bei Layer-Hosting wird nicht von AppKit gesetzt (hier explizit gesetzt, Bildschirmwechsel zur Laufzeit ist nicht behandelt).
- Richtung und Rotation des `shadowOffset` (Report 03, V13/V14).
- `CATextLayer` mit `NSAttributedString` (NSFont/NSColor).
- 8-bit-Gray-`CGContext` ohne Alpha für die gekachelte Noise.
- `.process("Resources")` legt `noise.png` flach ins Bundle (`Bundle.module.url(forResource:withExtension:)`).
- `constrainFrameRect(_:to:)`-Override gegen Verschieben unter die Menüleiste.
