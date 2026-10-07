# Phase 0 – Zusammenfassung zur Abnahme

Stand: 7. Okt. 2026 · Orchestrator · **Status: wartet auf Abnahme durch Max**

| Report | Kernfrage | Antwort | ⚠️ |
|---|---|---|---|
| [01](01-drag-drop-screenshot-thumbnail.md) Drag vom Screenshot-Thumbnail | Kommt der Drop an? File-Promise? | Ja, wahrscheinlich: File-Promise **plus** temporäre fileURL, die macOS kurz nach dem Drag löscht → sofort sichern | 15 |
| [02](02-window-level-fullscreen.md) Window-Level / Fullscreen | Wie bleibt das Panel über Fullscreen-Spaces sichtbar? | `NSPanel` + `.nonactivatingPanel` ist entscheidend, Level `.statusBar`; Behavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` | 21 |
| [03](03-stepped-animation.md) Stepped Animation | Ticker oder `CAKeyframeAnimation .discrete`? | `.discrete` + deterministischer Frame-Planer, kein laufender Timer im Idle | 20 |

Kein Report ist auf einem Mac verifiziert. Jeder enthält einen Testplan für den Mac mini.

## Prüfung durch den Orchestrator

- **Format:** Alle drei halten das Report-Format aus `betriebsregeln.md` ein.
- **Apple-Quellen:** Alle zitierten Apple-Doku-URLs sind erreichbar (HTTP 200), geprüft am 7. Okt. 2026.
- **GitHub-Quellen:** Alle zitierten Code-Dateien auf GitHub existieren, geprüft über raw.githubusercontent.com. Rund 17 zitierte GitHub-Issues und -PRs konnte ich nicht prüfen, weil der Proxy github.com blockt. Sie bleiben als Belege zweiter Ordnung stehen.
- **Konsistenz:** Keine Widersprüche zwischen den Reports. Die Panel-Konfiguration ist in 01 und 02 identisch (`hidesOnDeactivate = false`, `.nonactivatingPanel`, `orderFrontRegardless`). 03 verweist für die Reveal-Panel-Frage korrekt auf 02.
- **Alter einer Quelle:** In 02 stammen die SDK-Header-Zitate aus dem macOS-11.3-SDK (Archiv „phracker“). Das Ausschlussverhalten der Collection-Behavior-Flags wird auf dem Mac mini gegengeprüft.

## Synthese: Architekturentscheidungen für Phase 1

1. **Zwei Panels**
   - Eselsohr-Panel (klein, dauerhaft).
   - Board-Panel: wird beim Expand **sofort in Endgröße** per `orderFrontRegardless()` eingeblendet. Das 200-ms-Aufblättern läuft nur als Layer-Maske, nicht über `setFrame`.
   - Kein dauerhaft bildschirmgroßes transparentes Fenster, weil das Durchklicken regressionsanfällig ist.
2. **Panel-Konfiguration**
   - `[.borderless, .nonactivatingPanel]` im Initializer, `hidesOnDeactivate = false`, transparent, ohne Schatten.
   - `canBecomeMain = false`.
   - Activation-Policy `.accessory`.
3. **Drop-Annahme**
   - Registrierte Typen: `NSFilePromiseReceiver.readableDraggedTypes` + `.fileURL` + Bildtypen.
   - Reihenfolge der Auswertung: Promise → fileURL (synchron kopieren) → Bilddaten → URL.
   - Das Board zeigt einen Platzhalter, bis das Promise erfüllt ist.
4. **Animation**
   - Realtime: `CABasicAnimation` linear/easeOut.
   - Stop-Motion: `CAKeyframeAnimation .discrete`.
   - Bilder sind Standalone-`CALayer` in einer Layer-Hosting-View.
   - Model-Wert zuerst setzen, ohne `.forwards`-Trick.
5. **Look**
   - Harter Schatten: `shadowRadius = 0` + `shadowPath`.
   - Noise-Textur: einmal vorgekachelt rendern.
6. **Berechtigungen:** Für den Prototyp voraussichtlich keine. Das ist nur indirekt belegt, der Testplan prüft es auf dem Mac mini.

## Größte Risiken → Testpriorität für Spike 1

1. **Drag-Übergang Eselsohr → Board** während einer laufenden Session (02 T4). Daran hängt die Kern-Interaktion. Ein Rückfall ist vorbereitet: ein Panel, das per `setFrame` wächst.
2. **Thumbnail-Typen und Lebensdauer der Temp-Datei** auf macOS 26.5 (01 T0–T3).
3. **Fullscreen-Sichtbarkeit** über einer nativen Fullscreen-App und über DaVinci Resolve (02 T2/T3).
4. **Fokus bleibt in der Ursprungs-App** nach dem Drop (02 T5).

## Entscheidungen, die Max treffen muss

1. **Stop-Motion-Raster:** Globales 6-fps-Raster für alle Objekte (Startverzögerung bis 167 ms) oder Start sofort mit eigenem Takt je Sequenz?
2. **„Bewegung reduzieren“:** Fällt auch das 200-ms-Aufblättern weg (Board erscheint sofort)?
3. **Deployment-Target:** macOS 14 als Minimum? Auf dem Mac mini stehen SDKs bis 15.5 bereit.
4. **Sandbox:** Prototyp ohne App Sandbox?
5. **Screenshot wird „verbraucht“:** Laut einem Drittbericht speichert macOS nach einem angenommenen Thumbnail-Drop keine Datei auf dem Schreibtisch. Die Dropboard-Kopie ist dann die einzige. Ist das so gewollt?
6. **DaVinci Resolve:** Ist es auf dem Mac mini installiert, und welchen Vollbildmodus nutzt du (nativer Fullscreen-Space oder Resolves eigenes Vollbild)?
7. **`betriebsregeln.md`:** Den Entwurf so abnehmen?

## Vorschlag Phase 1 (startet erst nach Abnahme)

| Spike | Verzeichnis | Modell | Grund |
|---|---|---|---|
| Eselsohr-Panel mit Drop-Test + Pasteboard-Logger | `spikes/eselsohr-drop/` | Opus | Viele offene API-Fragen (T0–T5) |
| Board-Panel mit Papier-Textur | `spikes/board-paper/` | Sonnet | Durch 02/03 vollständig spezifiziert |
| Stop-Motion-Ticker als isoliertes Demo | `spikes/stopmotion/` | Sonnet | Durch 03 vollständig spezifiziert, Planer testbar |

- Alle Spikes werden SwiftPM-Executables, gebaut mit `swift build` (der Mac mini hat nur die Command Line Tools, kein Xcode).
- Build und Start übernimmt die Mac-mini-Session, die Gesten macht Max.
- Nachweis ist das Log der App.
