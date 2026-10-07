# Dropboard – Prototyp (Phase 2, Briefing-Schritte 1–6)

Zusammenführung der drei Spikes (`spikes/eselsohr-drop`, `spikes/board-paper`, `spikes/stopmotion`) zu einer App:
Eselsohr oben rechts, Drop-Annahme, Quick-Drop mit Speicherung, Board aus Papier, Realtime-Expand per Drag-Hover,
Stop-Motion nach dem Drop. Grundlage: `docs/briefing.md`, `docs/entscheidungen.md` (E1–E10), `docs/phase0/`.

**Status: im Linux-Container geschrieben, nie kompiliert, nie ausgeführt.** Code, der wörtlich aus den Spikes stammt,
ist auf dem Mac mini kompiliert. Neue, in keinem Spike belegte APIs sind mit `⚠️ VERIFIZIEREN` markiert
(`grep -rn "VERIFIZIEREN" Sources`).

## Build und Start

```sh
cd app
swift build                                   # nur Command Line Tools, kein Xcode, kein XCTest
swift run Dropboard --selftest                # Logik-Assertions, kein Fenster; Exit 0 = alles PASS
swift run Dropboard                           # App (Handoff two-panels)
swift run Dropboard --handoff grow            # Handoff-Variante B
.build/debug/Dropboard --snapshot /tmp/db.png --snapshot-demo   # Offscreen-PNG ohne Fenster/Berechtigung
```

Beenden: Ctrl-C im Terminal (wird geloggt). Die App hat kein Dock-Icon (`.accessory`) und aktiviert sich nie.

## Argumente

| Argument | Wirkung |
|---|---|
| `--handoff two-panels\|grow` | Übergabe der Drag-Session ans Board. Default `two-panels` (`DropboardConfig.defaultHandoff`), weil T4 auf Hardware offen ist. |
| `--board-dir <pfad>` | Anderer Board-Ordner statt `~/Library/Application Support/Dropboard/Boards/default` (Tests). |
| `--reduce-motion` | „Bewegung reduzieren“ erzwingen (zusätzlich zur Systemeinstellung, E2). |
| `--selftest` | Stop-Motion-Planer (55 Spike-Tests) + Layout + Store. Kein Fenster. Exit 0/1. |
| `--snapshot <pfad.png>` | Board mit den gespeicherten Bildern offscreen per `CALayer.render(in:)` in Backing-Scale als PNG, dazu das Eselsohr als `<pfad ohne .png>-ear.png`. Dann Ende. |
| `--snapshot-demo` | Mit `--snapshot`: 5 Platzhalterbilder (3 per Free-Slot-Finder, 2 per Cursor-Drop) plus ein offener Platzhalter in einem **temporären** Board (wird danach gelöscht; der echte Ordner bleibt unberührt). |
| `--snapshot-dimmed` | Mit `--snapshot`: abgedunkeltes Papier (Look während des Drags). |

## Ablage

```
~/Library/Application Support/Dropboard/Boards/default/
  board.json            {"version":1,"items":[{id,fileName,center{x,y},rotation,size{width,height},addedAt,source{route,originalPath,originalName,app}}]}
  images/<uuid>.<ext>   Bildkopien
  incoming/<uuid>/      Zielordner für File-Promises (Datei wird danach nach images/ verschoben)
```

- `board.json` wird nach jeder Änderung atomisch geschrieben (`Data.write(.atomic)`) und beim Start geladen.
  Eine unlesbare Datei wird als `board.corrupt-<unix>.json` beiseitegelegt, nicht überschrieben.
- Board-Koordinaten: pt, Ursprung **oben links** des Bildschirms, y nach unten (Lesereihenfolge). Rotation in Grad,
  positiv = gegen den Uhrzeigersinn (Core-Animation-Konvention). `addedAt` auf ganze Sekunden (ISO 8601).
- `source.app` ist die vorderste App beim Drop (= Ursprungs-App, da Dropboard nie aktiv wird).

## Architektur

| Datei | Verantwortung | Herkunft |
|---|---|---|
| **DropboardCore** (nur Foundation/CoreGraphics) | | |
| `BoardModel.swift` | `BoardItem`, `BoardDocument` (Codable), `BoardClock` | neu |
| `BoardStore.swift` | Pfade, Laden, atomisches Speichern, Quarantäne, Dateinamen | neu |
| `BoardLayout.swift` | `LayoutMetrics` (Grid 24, Abstand 12, Rand 48, Kante 220, Kipp 1–2°), Snap, Overlap, Free-Slot-Finder, Drop-Snap, Größen, Zufallskipp | neu, Werte aus board-paper |
| `StopMotion/*.swift` | `StopMotionClock`, `SplitMix64`, Jitter, `StopMotionPlanner`, `StopMotionSequences` | unverändert aus stopmotion |
| **Dropboard** (AppKit/QuartzCore) | | |
| `main.swift` | Argumente, `--selftest`, `--snapshot`, App-Start (`MainActor.assumeIsolated`) | Muster aus eselsohr-drop |
| `LaunchOptions.swift`, `DropboardConfig.swift` | Argumente; alle Verhaltens-Konstanten (E8 `dropCloseDelay`, E10 `expandDelay`, Handoff-Default, Eselsohr-Geometrie, Watchdog) | neu / eselsohr-drop |
| `AppController.swift` | baut die Teile zusammen, System-Beobachter (Spaces, Aktivierung, Bildschirm) | eselsohr-drop |
| `DragCoordinator.swift` | Zustandsautomat `idle → hovering → expanded → dropClosing/collapsing → idle`, Expand-Timer, Watchdog | eselsohr-drop/AppController |
| `BoardPresenter.swift` | Panels, Handoff two-panels/grow, Öffnen/Zuklappen (Realtime), sofortiges Schließen | eselsohr-drop |
| `BoardController.swift` | Dokument, Platzierung (Quick-Drop/Cursor), Platzhalter → Bild, Speichern | neu |
| `ImageImporter.swift` | Drop-Annahme Promise → fileURL (synchron) → Bilddaten → URL (nur Log), Pasteboard-Logs | eselsohr-drop/DropSaver |
| `ImageDecoder.swift` | Bild lesen und auf Board-Größe rendern, im Hintergrund | board-paper/ImageLibrary.fit |
| `BoardScene.swift` | Layer-Baum: Papier, Noise, Abdunklung, Bild-/Platzhalter-Layer mit hartem Schatten | board-paper/BoardView |
| `Panels.swift` | `DropboardPanel` (Panel-Konfig), `DropTargetView` (Layer-Hosting + NSDraggingDestination) | eselsohr-drop/Panels |
| `Motion.swift` | **`RealtimeMotion`** und **`StopMotion`** (getrennt), `MotionPreferences` | stopmotion/Motion |
| `PaperStyle.swift`, `PaperArt.swift` | Look-Konstanten; Noise-Kachel/-Tiling, Eselsohr-Bitmap, Demo-Bilder, PNG-Export | board-paper |
| `Diagnostics.swift`, `Log.swift` | `[WIN]`/`[FOCUS]`-Logs; Logger, FileProbe | eselsohr-drop |
| `Snapshot.swift`, `SelfTest*.swift` | Offscreen-PNG; Selftest | neu / stopmotion |

### Realtime vs. Stop-Motion

| Pfad | Typ | Wann | Wie |
|---|---|---|---|
| Realtime | `RealtimeMotion.reveal/collapse` | Aufblättern nach 300 ms Drag-Hover; Zuklappen ohne Drop | Maske auf dem Papier-Layer, Scale 0.001 ↔ 1 um die Eselsohr-Ecke, 200 ms, easeOut, kein Bounce. Maske wird danach entfernt. Reduce Motion: sofort. |
| keine Animation | `StopMotion.setModel` | Quick-Drop, Laden | Model-Wert hart gesetzt. |
| Stop-Motion | `StopMotion.apply` + `StopMotionSequences.drop` | nach dem Drop aufs Board | 2 Frames à 1/6 s (groß ohne Kipp + Jitter, dann final mit Kipp), `CAKeyframeAnimation` `.discrete`, Start sofort (E1). Board schließt nach `dropCloseDelay` ≈ 333 ms (E8). Reduce Motion: 1 Frame, schließt sofort. |

Jitter gibt es nur in `DragCoordinator.postDropMotionOptions()` und nur in der Phase `dropClosing` (nach dem Drop).
Das Board ist während des Drags abgedunkelt (Graphit 0,35 über dem Papier, unter den Bildern) und bleibt es bis zum Schließen.

### Ansichtsmodus (Schritt 7) – vorgesehene Erweiterung

Ein Klick aufs Eselsohr loggt nur `Ansichtsmodus (Schritt 7) noch nicht implementiert`. Ergänzung ohne Umbau:
`DragCoordinator.Phase.viewing` + `clicked` → `BoardPresenter.openForViewing()` (Stop-Motion-Reveal 3 Frames,
`StopMotionSequences.reveal`, ohne Abdunklung); `BoardController.moveItem/deleteItem` mit `StopMotionSequences.move/delete`
und `BoardDocument.upsert/remove`; Esc über einen lokalen Key-Monitor (Panels dürfen bereits key werden).

## Manuelle Tests gegen die Interaktionstabelle

Vorher: Log mitlaufen lassen (`tail -f ~/Library/Logs/Dropboard/dropboard.log`). Je Test notieren: wer, Datum,
macOS-Version, Ergebnis, Logzeilen. Die erwarteten Zeilen sind Hypothesen, Abweichungen sind Befunde.

| # | Zeile der Interaktionstabelle / Schritt | Aktion | Erwartet (Log) | Prüfen (Auge) |
|---|---|---|---|---|
| 0 | Selftest/Snapshot | `swift run Dropboard --selftest`; `--snapshot /tmp/db.png --snapshot-demo`, dann mit `--snapshot-dimmed` | `N/N PASS`, Exit 0; `[WIN] Snapshot Board geschrieben … items=5`, `[WIN] Snapshot Eselsohr geschrieben …-ear.png` | PNG: Off-White + Noise, harte Schatten 1–2 px unten rechts, Kipp ±1–2°, ein leeres Platzhalter-Rechteck, Eselsohr als Papiereck |
| 1 | Eselsohr (Schritt 1) | Start | `[WIN] Start Dropboard handoff=two-panels …`, `[WIN] Start ear … level=25 … visible=true`, `[WIN] Start board … visible=false`, `[FOCUS] Start … NSApp.isActive=false`, `[STORE] geladen items=…` | ca. 40 pt oben rechts, 12 pt eingerückt, knapp unter der Menüleiste, gedämpft, ohne Schatten, kein Dock-Icon |
| 1b | Eselsohr still | beliebigen Drag starten, nicht aufs Eselsohr | keine Zeile | keine Reaktion, keine Idle-Animation |
| 1c | über allen Fenstern | Space wechseln; Safari nativ Vollbild | `[WIN] Space-Wechsel ear … onActiveSpace=true visible=true` | Eselsohr auf jedem Space und über der Vollbild-App |
| 2 | Drop-Test (Schritt 2) | Finder-PNG/JPEG/HEIC, Screenshot-Thumbnail (⌘⇧4), Safari-Bild jeweils schnell aufs Eselsohr | `[HANDOFF] neue Drag-Session`, `[PB] draggingEntered …`, `[DROP] performDragOperation win=ear art=Quick-Drop`, dann `Weg=fileURL kopiert …` bzw. `Weg=File-Promise …` + `Promise0 vollständig nach …ms`, `[DROP] dekodiert id=…` | Datei in `images/`, keine in `incoming/` übrig |
| 2b | nur Bilder | Textschnipsel oder PDF aufs Eselsohr | `[PB] kein Bild im Drag → Eselsohr bleibt still` | kein Expand, Drop wird abgelehnt |
| 3 | Drop direkt aufs Eselsohr (Schritt 3) | Bild aufs Eselsohr, **vor** 300 ms loslassen | `art=Quick-Drop`, `[STORE] Platzhalter … art=Quick-Drop (keine Animation)`, `[STORE] gespeichert items=N …`, `[FOCUS] nach Drop frontmost=<Ursprungs-App> NSApp.isActive=false` | Board öffnet nicht; kein `[MOTION]`-Eintrag |
| 3b | nächste freie Stelle | drei Quick-Drops, dann Drag-Hover zum Ansehen | erste `mitte=` oben links der Ablagefläche (visibleFrame − 48 pt, auf 24-pt-Grid), die nächsten rechts daneben | Bilder oben links in Lesereihenfolge, keine Überlappung |
| 3c | Persistenz | App beenden und neu starten | `[STORE] geladen items=N` | gleiche Positionen und Kippwinkel |
| 4 | Board-Look (Schritt 4) | Drag-Hover ≥ 300 ms | `[MOTION] RealtimeMotion reveal … abgedunkelt=true` | abgedunkeltes Papier statt schwarzer Transparenz, Bilder mit hartem Schatten und Kipp |
| 5 | Drag + Hover auf Eselsohr (Schritt 5) | Drag aufs Eselsohr, ≥ 300 ms halten | `[FOCUS] vor Expand`, `[HANDOFF] Expand ausgelöst mode=two-panels … dauer(orderFront/setFrame)=…ms`, `[MOTION] RealtimeMotion reveal animated=true dauer=200ms`, `[WIN] nach Expand board … visible=true level=25`, dann `[HANDOFF] draggingEntered win=board …` | Papier zieht in ~200 ms von der Ecke diagonal auf, kein Bounce; Menüleiste bleibt bei der Ursprungs-App |
| 5b | Drop auf Board | im offenen Board loslassen | `[DROP] performDragOperation win=board art=Board-Drop dropPos=…`, `[STORE] Platzhalter … art=Board-Drop`, `[MOTION] StopMotion drop … frames=2 duration=0.333s animated=true jitter=true`, `[MOTION] Board schließt in 333ms`, `[HANDOFF] Board geschlossen grund=nach Drop`, `[FOCUS] nach Drop frontmost=<Ursprungs-App>` | Bild an der Cursorposition (gesnappt), zwei harte Frames (groß → final mit Kipp), dann ist das Board weg; Weitertippen landet in der Ursprungs-App |
| 5c | Drop eines Screenshot-Thumbnails aufs Board | wie 5b mit ⌘⇧4-Thumbnail | zusätzlich `Weg=File-Promise`, später `Promise0 vollständig`, `[DROP] dekodiert` | zuerst leeres Papier-Rechteck mit Schatten, dann das Bild |
| 5d | Maus verlässt Board ohne Drop | Expand, dann auf zweiten Monitor ziehen | `[HANDOFF] draggingExited win=board …`, `[MOTION] RealtimeMotion collapse animated=true grund=Maus hat Board verlassen …`, `[HANDOFF] Board geschlossen grund=… zuklappen=…ms` | klappt in ~200 ms zur Ecke zu, nichts gespeichert |
| 5e | Esc | Expand, Esc bei gedrückter Maustaste | `draggingExited win=board`, `Cursor noch im Board-Frame (Esc/Abbruch?)`, nach 300 ms `collapse … grund=Drag im Board abgebrochen (Esc)` (oder früher `draggingEnded ohne Drop`) | klappt zu |
| 5f | Drag endet ohne Drop | Expand, Drag zurück zur Quelle und dort loslassen | `draggingEnded … dropEmpfangen=false` oder `Maustaste losgelassen (Polling)` → `collapse` | klappt zu |
| 5g | kurz drüber | Drag in < 300 ms über das Eselsohr hinweg | `draggingExited win=ear vor Expand → Expand abgebrochen` | kein Expand |
| 5h | grow | Start mit `--handoff grow`, 5–5f wiederholen | `Expand ausgelöst mode=grow`, `draggingUpdated (erstes nach Expand) win=ear(grown)`, `performDragOperation win=ear(grown) art=Board-Drop` | wie two-panels; danach Eselsohr wieder 40×40 |
| 6 | Stop-Motion nach Drop (Schritt 6) | 5b mehrfach | `frames=2 … jitter=true`; nie `[MOTION] StopMotion` vor dem Drop | Frames hart getrennt (kein Lag-Eindruck), letzter Frame ruhig |
| 6b | Bewegung reduzieren (E2) | Systemeinstellung umschalten (oder `--reduce-motion`), 5, 5b, 5d | `[MOTION] Bewegung reduzieren geändert: … effective=true`, `reveal animated=false dauer=0ms`, `StopMotion drop … frames=1 … animated=false`, `Board schließt in 0ms`, `collapse animated=false` | Board erscheint/verschwindet sofort, kein Jitter |
| 7 | Klick aufs Eselsohr | klicken, ohne Drag | `[WIN] Klick auf ear ohne Drag → Ansichtsmodus (Schritt 7) noch nicht implementiert`, `[FOCUS] nach Klick … NSApp.isActive=false` | nichts öffnet sich; kein `!!! DROPBOARD SELBST AKTIVIERT` |

Jederzeit ein Befund: `[FOCUS] App aktiviert: … !!! DROPBOARD SELBST AKTIVIERT`.

## Offene Punkte

- **T4 (Handoff)** ist auf Hardware nicht geklärt; deshalb beide Varianten. `exitInsideGrace` (300 ms) setzt voraus,
  dass nach dem Expand kein `draggingExited` bei weiter im Board stehendem Cursor kommt. Tut es das bei `grow`
  (Spike-Frage), `DropboardConfig.exitInsideGrace = nil` setzen (dann nur `draggingEnded`/Maustaste wie im Spike).
- Esc während eines fremden Drags erreicht die App nicht als Tastenereignis; erkannt wird der Abbruch über
  `draggingExited`/`draggingEnded`/Maustaste.
- EXIF-Orientierung wird beim Dekodieren nicht ausgewertet (wie im Spike) – Handy-Fotos können gedreht erscheinen.
- Mehrere Monitore: Eselsohr und Board auf dem Bildschirm unter der Maus beim Start; Wechsel der Bildschirm-
  parameter wird nachgezogen, ein Eselsohr pro Bildschirm gibt es noch nicht.
- Board deckt den ganzen Bildschirm inkl. Menüleiste ab (wie Spike); die Ablagefläche ist der `visibleFrame` minus 48 pt.
