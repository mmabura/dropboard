# Phase 2 – Testprotokoll Prototyp (`app/`)

**Umgebung:** Max' Mac mini (Apple M4, macOS 26.5.1), 4K @ 2.0, Swift 6.1.2 (Command Line Tools).
**Ausgeführt von:** Remote-Control-Session auf dem Mac mini, im Auftrag des Orchestrators.

## Commit 9a00930 – Schritte 1–6

| Prüfung | Ergebnis |
|---|---|
| `swift build` | ✅ Exit 0, 0 Fehler, 0 Warnungen (28,3 s) |
| `--selftest` | ✅ 96/96 PASS, Exit 0 |
| `--snapshot … --snapshot-demo` | ✅ Exit 0, 3840×2160 px; 5 Demo-Bilder + 1 offener Platzhalter (beabsichtigt) |
| `--snapshot … --snapshot-demo --snapshot-dimmed` | ✅ Exit 0 |
| Snapshot-Demo schreibt nicht ins echte Board | ✅ `~/Library/Application Support/Dropboard/` existiert vor und nach dem Lauf nicht; Temp-Ordner aufgeräumt |

### Sichtprüfung des Snapshots (durch die Mac-Session)

| Kriterium (Briefing „Look“) | Befund | Folge |
|---|---|---|
| Warmes Off-White | ✅ ca. #ECE8E2 | — |
| Noise gerade sichtbar, flach | ⚠️ gleichmäßig, aber deutliche horizontale Faserstreifen, eher „deutlich“ als „gerade sichtbar“ | Feinschliff beauftragt |
| Harter Schatten ohne Blur, 1–2 px | ⚠️ scharf, kleiner Versatz, aber im normalen Board kaum wahrnehmbar | Feinschliff beauftragt |
| Zufallsrotation ±1–2° | ✅ alle Karten leicht gekippt | — |
| Abgedunkeltes Papier statt Schwarz | ⚠️ kein schwarzer Schleier, aber kühles neutrales Grau (~#ADABA5), Wärme geht verloren | Feinschliff beauftragt |
| Eselsohr als umgeknicktes Papiereck, ohne Schatten | ⚠️ ohne Schatten, mit Falzlinie, liest sich aber als flaches Dreieck | Feinschliff beauftragt |

### Offen (braucht Max am Gerät)
Interaktive Testliste in `app/README.md`: Quick-Drop, Expand + Drop an Cursor, Zuklappen ohne Drop, Fokus, Vollbild-Spaces, Screenshot-Thumbnail, beide Handoff-Varianten.
