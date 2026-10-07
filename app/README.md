# Dropboard – Prototyp (Phase 2, Briefing-Schritte 1–8)

Zusammenführung der drei Spikes (`spikes/eselsohr-drop`, `spikes/board-paper`, `spikes/stopmotion`) zu einer App:
Eselsohr oben rechts, Drop-Annahme, Quick-Drop mit Speicherung, Board aus Papier, Realtime-Expand per Drag-Hover,
Stop-Motion nach dem Drop, Ansichtsmodus, Menüleisten-Symbol mit Einstellungen (Schritt 8). Grundlage: `docs/briefing.md`, `docs/entscheidungen.md` (E1–E10), `docs/phase0/`.

**Status (7. Okt. 2026, Version 0.1.24, Commit ebf8359):** baut auf dem Mac mini (macOS 26.5.1, Swift 6.1.2, nur Command
Line Tools) ohne Fehler und Warnungen, `--selftest` 323/323 PASS, Universal-App ad-hoc signiert, startet und ist im Idle
still (0,0 % CPU). **Nicht von Hand getestet:** die Drag-Gesten auf echter Hardware. API-Annahmen, die nur Hardware
bestätigen kann, sind mit `⚠️ VERIFIZIEREN` markiert (`grep -rn "VERIFIZIEREN" Sources`). Stand und offene Fragen:
`docs/stand.md`.

## Build und Start

```sh
cd app
swift build                                   # nur Command Line Tools, kein Xcode, kein XCTest
swift run Dropboard --selftest                # Logik-Assertions, kein Fenster; Exit 0 = alles PASS
swift run Dropboard                           # App (Handoff two-panels)
swift run Dropboard --handoff grow            # Handoff-Variante B
.build/debug/Dropboard --snapshot /tmp/db.png --snapshot-demo   # Offscreen-PNG ohne Fenster/Berechtigung
```

Beenden: Menüleisten-Symbol → „Dropboard beenden“ (oder Ctrl-C im Terminal, wird geloggt). Die App hat kein
Dock-Icon (`.accessory`) und aktiviert sich nie.

## Argumente

| Argument | Wirkung |
|---|---|
| `--handoff two-panels\|grow` | Übergabe der Drag-Session ans Board. Default `two-panels` (`DropboardConfig.defaultHandoff`), weil T4 auf Hardware offen ist. |
| `--board-dir <pfad>` | Anderer Board-Ordner statt `~/Library/Application Support/Dropboard/Boards/default` (Tests). |
| `--reduce-motion` | „Bewegung reduzieren“ erzwingen (zusätzlich zur Systemeinstellung, E2). |
| `--selftest` | Stop-Motion-Planer (55 Spike-Tests) + Layout + Store + Ansichtsmodus (47) + Einstellungen (42). Kein Fenster. Exit 0/1. |
| `--snapshot <pfad.png>` | Board mit den gespeicherten Bildern offscreen per `CALayer.render(in:)` in Backing-Scale als PNG, dazu das Eselsohr als `<pfad ohne .png>-ear.png`. Dann Ende. |
| `--snapshot-demo` | Mit `--snapshot`: 5 Platzhalterbilder (3 per Free-Slot-Finder, 2 per Cursor-Drop) plus ein offener Platzhalter in einem **temporären** Board (wird danach gelöscht; der echte Ordner bleibt unberührt). |
| `--snapshot-dimmed` | Mit `--snapshot`: abgedunkeltes Papier (Look während des Drags). |

## Ablage

```
~/Library/Application Support/Dropboard/Boards/default/
  board.json            {"version":1,"items":[{id,fileName,center{x,y},rotation,size{width,height},addedAt,source{route,originalPath,originalName,app}}]}
  images/<uuid>.<ext>   Bildkopien
  incoming/<uuid>/      Zielordner für File-Promises (Datei wird danach nach images/ verschoben)
  trash/<uuid>.<ext>    im Ansichtsmodus gelöschte Bilder (verschoben, nicht gelöscht; entsteht beim ersten Löschen)
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
| `EarPlacement.swift` | `EarCorner` (4 Ecken), `EarGeometry` (Eselsohr-Rahmen im visibleFrame, äußere Ecke, Anker fürs Aufblättern), `ExpandDelay` (150/300/500/800 ms, Standard 300) | neu (Schritt 8) |
| `BoardEditing.swift` | Ansichtsmodus-Logik: Treffer-Test (mit Rotation), Umsortieren/Löschen im Modell, Snap-Ziel, `ViewModeSequences` (Blatt auf/zu, 3 Frames), `BoardStore.moveImageToTrash` | neu (Schritt 7) |
| **Dropboard** (AppKit/QuartzCore) | | |
| `main.swift` | Argumente, `--selftest`, `--snapshot`, App-Start (`MainActor.assumeIsolated`) | Muster aus eselsohr-drop |
| `LaunchOptions.swift`, `DropboardConfig.swift` | Argumente; alle Verhaltens-Konstanten (E8 `dropCloseDelay`, E10 `defaultExpandDelayMs`, `defaultCorner`, Handoff-Default, Eselsohr-Geometrie, Watchdog) | neu / eselsohr-drop |
| `Settings.swift` | Einstellungen in `UserDefaults.standard`, Keys `dropboard.corner`, `dropboard.expandDelayMs`, `dropboard.launchAtLogin` (Spiegel) | neu (Schritt 8) |
| `StatusMenu.swift` | `StatusMenuController`: Menüleisten-Symbol (Template, programmatisch gezeichnet) und Menü; `StatusMenuHost` (= AppController) | neu (Schritt 8) |
| `HotKey.swift` | `GlobalHotKey` (Carbon `RegisterEventHotKey`, ohne Berechtigung), `HideHotKey` (⌃⌥⌘E) | neu (Schritt 8) |
| `LoginItem.swift` | „Beim Anmelden starten“ über `SMAppService.mainApp` | neu (Schritt 8) |
| `AppController.swift` | baut die Teile zusammen, System-Beobachter (Spaces, Aktivierung, Bildschirm); Aktionen der Menüleiste (Ecke, Verzögerung, Ausblenden, Beenden) | eselsohr-drop |
| `DragCoordinator.swift` | Zustandsautomat `idle → hovering → expanded → dropClosing/collapsing → idle` und `idle → viewing → viewClosing → idle`, Expand-Timer, Watchdog, Maus-Weiterleitung | eselsohr-drop/AppController |
| `BoardPresenter.swift` | Panels, Handoff two-panels/grow, Öffnen/Zuklappen (Realtime), sofortiges Schließen; Ansichtsmodus öffnen/schließen (Stop-Motion, `makeKey`) | eselsohr-drop |
| `BoardController.swift` | Dokument, Platzierung (Quick-Drop/Cursor), Platzhalter → Bild, Speichern; Treffer, Ziehen, Umsortieren, Löschen | neu |
| `ImageImporter.swift` | Drop-Annahme Promise → fileURL (synchron) → Bilddaten → URL (nur Log), Pasteboard-Logs | eselsohr-drop/DropSaver |
| `ImageDecoder.swift` | Bild lesen und auf Board-Größe rendern, im Hintergrund | board-paper/ImageLibrary.fit |
| `BoardScene.swift` | Layer-Baum: Papier, Noise, Abdunklung, Bild-/Platzhalter-Layer mit hartem Schatten | board-paper/BoardView |
| `Panels.swift` | `DropboardPanel` (Panel-Konfig), `DropTargetView` (Layer-Hosting + NSDraggingDestination, Maus → DragCoordinator) | eselsohr-drop/Panels |
| `Motion.swift` | **`RealtimeMotion`** und **`StopMotion`** (getrennt), `MotionPreferences` | stopmotion/Motion |
| `ViewMotion.swift` | **`StopMotionSheet`**: Stop-Motion-Maske über dem Papier, Aufblättern/Zuklappen im Ansichtsmodus | neu (Schritt 7) |
| `ViewModeController.swift` | Ansichtsmodus: Öffnen/Schließen, Auswahl, direktes Ziehen, Snap, Löschen, lokaler Key-Monitor, `[VIEW]`-Logs; `ViewModeStyle` | neu (Schritt 7) |
| `PaperStyle.swift`, `PaperArt.swift` | Look-Konstanten; Noise-Kachel/-Tiling, Eselsohr-Bitmap, Demo-Bilder, PNG-Export | board-paper |
| `Diagnostics.swift`, `Log.swift` | `[WIN]`/`[FOCUS]`-Logs; Logger, FileProbe | eselsohr-drop |
| `Snapshot.swift`, `SelfTest*.swift` | Offscreen-PNG (Eselsohr in der gespeicherten Ecke); Selftest (`SelfTestViewMode.swift` = Teil 4, Ansichtsmodus; `SelfTestSettings.swift` = Teil 5, Ecken/Einstellungen) | neu / stopmotion |

### Realtime vs. Stop-Motion

| Pfad | Typ | Wann | Wie |
|---|---|---|---|
| Realtime | `RealtimeMotion.reveal/collapse` | Aufblättern nach `Settings.expandDelayMs` (Standard 300 ms) Drag-Hover; Zuklappen ohne Drop | Maske auf dem Papier-Layer, Scale 0.001 ↔ 1 um die Eselsohr-Ecke, 200 ms, easeOut, kein Bounce. Maske wird danach entfernt. Reduce Motion: sofort. |
| keine Animation | `StopMotion.setModel` | Quick-Drop, Laden | Model-Wert hart gesetzt. |
| Stop-Motion | `StopMotion.apply` + `StopMotionSequences.drop` | nach dem Drop aufs Board | 2 Frames à 1/6 s (groß ohne Kipp + Jitter, dann final mit Kipp), `CAKeyframeAnimation` `.discrete`, Start sofort (E1). Board schließt nach `dropCloseDelay` ≈ 333 ms (E8). Reduce Motion: 1 Frame, schließt sofort. |

Jitter gibt es nur in `DragCoordinator.postDropMotionOptions()` (nur in der Phase `dropClosing`, nach dem Drop) und in
`ViewModeController.motionOptions` (Ansichtsmodus, nie während die Maus ein Bild zieht).
Das Board ist während des Drags abgedunkelt (Graphit 0,35 über dem Papier, unter den Bildern) und bleibt es bis zum Schließen.

### Ansichtsmodus (Schritt 7)

Klick aufs Eselsohr (kein Drag) öffnet das Board zum Betrachten, Umsortieren und Löschen. Export gehört nicht
zum Prototyp. Zustand im `DragCoordinator`: `idle → viewing → viewClosing → idle`; Interaktion in `ViewModeController`.

| Aktion | Verhalten | Pfad |
|---|---|---|
| Öffnen (Klick aufs Eselsohr) | Papier **nicht** abgedunkelt; Aufblättern aus der Eselsohr-Ecke in 3 harten Frames (`StopMotionSequences.reveal`: Maske 0.6 → 0.85 → 1.0, mit Jitter). Das Eselsohr liegt danach als Ecke über dem Board. | Stop-Motion (`StopMotionSheet`), Reduce Motion: sofort |
| Auswahl (Klick auf ein Bild) | dünner Graphit-Rahmen (1 pt, 85 %), kein Systemblau. Klick aufs Papier hebt die Auswahl auf. | keine Animation |
| Umsortieren (Bild ziehen) | ab 3 pt Bewegung folgt das Bild der Maus direkt (Model-Wert, keine Keyframes, kein Jitter) und liegt oben. Beim Loslassen: Snap aufs 24-pt-Grid (wie Drop, in der Ablagefläche), neue Zufallsrotation ±1–2°, `StopMotionSequences.move` (2–4 Frames, mit Jitter). Danach oben im Stapel, gespeichert. | Stop-Motion nach dem Loslassen |
| Löschen (Auswahl + Backspace/Entf) | `StopMotionSequences.delete` (2 Frames: kleiner, weg), Eintrag aus `board.json` (atomisch), Bilddatei nach `trash/`. Kein Undo. | Stop-Motion, Reduce Motion: sofort weg |
| Schließen (Esc oder Klick aufs Eselsohr) | reveal rückwärts, 3 Frames, Start sofort (E1): 0.85 → 0.6 → weg, dann `orderOut`. | Stop-Motion, Reduce Motion: sofort |
| Fremder Drag (Bild) während offen | landet per Drop an der Cursorposition (gesnappt, Stop-Motion-Drop mit Jitter), auch über dem Eselsohr; das Board **bleibt offen**. | Stop-Motion |

Fokus: Das Board-Panel wird per `makeKey()` key, die App wird nie aktiviert (kein `NSApp.activate`, kein
`makeKeyAndOrderFront`). Tasten kommen über einen lokalen Key-Monitor (Muster aus Spike eselsohr-drop), der für jedes
Panel der App greift. ⚠️ VERIFIZIEREN: dass `makeKey()` auf einem nicht aktivierenden Panel einer inaktiven App Tasten
liefert. Belegt ist nur, dass ein **Klick** das Panel key macht; der Klick aufs Eselsohr tut das bereits, deshalb
erreichen Esc/Backspace die App auch dann, wenn `makeKey()` nichts bewirkt (Log `[VIEW] Taste … fenster=ear`).
Alternativen, falls Tasten gar nicht ankommen, nach Fokusraub geordnet: (1) einmal ins Papier klicken (Panel wird key,
kein Fokusraub) – greift automatisch, weil jeder Klick auf ein Bild/Papier das Board key macht; (2) globaler Monitor –
braucht Bedienungshilfen-Berechtigung, verworfen; (3) `NSApp.activate()` nur für die Dauer des Ansichtsmodus und danach
die Ursprungs-App reaktivieren – echter Fokusraub (Menüleiste wechselt, Vollbild-Space-Risiko laut Report 02), nur als
letzter Ausweg. Umgesetzt ist (1) als Rückfall, (3) nicht.

## Menüleiste und Einstellungen (Schritt 8)

Ein Menüleisten-Symbol (Blatt mit Eselsohr, Template-Bild, folgt hell/dunkel der Menüleiste) macht die App ohne
Terminal bedienbar. Ein Klick öffnet das Menü; jede Einstellung ist ein weiterer Klick und wirkt sofort.
Nur Systemmenü-Darstellung (Häkchen), keine eigenen Farben, kein Systemblau in eigener UI. Die App wird dabei
nicht aktiviert (⚠️ VERIFIZIEREN, Test 8).

| Eintrag | Wirkung |
|---|---|
| Board öffnen | Ansichtsmodus – derselbe Weg wie ein Klick aufs Eselsohr (`DragCoordinator.openViewing`). Ist das Eselsohr ausgeblendet, liegt es für die Dauer des Ansichtsmodus als Ecke über dem Board (zum Schließen per Klick) und verschwindet danach wieder. |
| Eselsohr ausblenden (⌃⌥⌘E) | Häkchen = ausgeblendet. `orderOut` des Eselsohr-Panels (nicht `sharingType`, Report 02); Drags aufs Eselsohr gehen dann nicht. **Nicht gespeichert:** nach jedem Neustart ist es wieder sichtbar. Ein offener Ansichtsmodus/Drag wird vorher ohne Animation beendet. |
| Ecke ▸ Oben rechts / Oben links / Unten rechts / Unten links | Eselsohr springt sofort in die Ecke: 12 pt seitlich eingerückt, 2 pt unter der Menüleiste bzw. über dem Dock (`visibleFrame`). Die umgeknickte Ecke zeigt zur Bildschirmecke, der Falz zur Mitte; Aufblättern (Realtime und Ansichtsmodus) geht von dieser Ecke aus. Gespeichert. |
| Verzögerung bis Aufklappen ▸ 150 / 300 (Standard, E10) / 500 / 800 ms | Drag-Hover bis zum Expand; ab dem nächsten Drag. Gespeichert. |
| Beim Anmelden starten | `SMAppService.mainApp` register/unregister; Häkchen = `status == .enabled`, Strich = `.requiresApproval` (Klick öffnet Systemeinstellungen → Anmeldeobjekte). Außerhalb einer `.app` (`swift run`) deaktiviert: „(nur in Dropboard.app)“. ⚠️ VERIFIZIEREN mit der ad-hoc-signierten App; am besten nur aus `/Applications/Dropboard.app` einschalten (die Registrierung hängt am Bundle-Ort). |
| Board-Ordner im Finder zeigen | `NSWorkspace.activateFileViewerSelecting` auf den Board-Ordner (Finder kommt nach vorn, gewollt). |
| Über Dropboard ▸ | Untermenü: „Dropboard <Version> (Build <n>)“ aus der Info.plist, sonst „dev“; „Protokoll im Finder zeigen“. Bewusst kein Über-Fenster: das müsste die App aktivieren. |
| Dropboard beenden (⌘Q) | `NSApp.terminate`. ⌘Q greift nur bei offenem Menü (die App ist nie aktiv). |

**Hotkey ⌃⌥⌘E** (fest, kein Recorder): Carbon `RegisterEventHotKey` + `InstallEventHandler`
(kEventClassKeyboard/kEventHotKeyPressed) – braucht weder Bedienungshilfen noch Eingabeüberwachung
(⚠️ VERIFIZIEREN). Nicht ⌥⌘D: das ist der System-Kurzbefehl „Dock ein-/ausblenden“. ⌃⌥⌘E hat keine bekannte
Systembelegung (⚠️ VERIFIZIEREN unter Systemeinstellungen → Tastatur → Tastaturkurzbefehle). Ist die Kombination
schon von einer anderen App belegt, steht `registriert=false FEHLER …` im Log; das Menü funktioniert trotzdem.
Doppelte Auslösung innerhalb 300 ms (Hotkey + Menü-Tastenkürzel bei offenem Menü) wird ignoriert.

**Speicherung:** `UserDefaults.standard`, Keys `dropboard.corner` (`topRight|topLeft|bottomRight|bottomLeft`),
`dropboard.expandDelayMs` (nur 150/300/500/800, sonst Standard), `dropboard.launchAtLogin` (nur Spiegel des
`SMAppService`-Status). Domäne in der `.app`: `app.dropboard.Dropboard`; bei `swift run` eine eigene (Prozessname,
⚠️ VERIFIZIEREN) – Einstellungen aus `swift run` und `.app` sind getrennt. Lesen/Zurücksetzen:

```sh
defaults read app.dropboard.Dropboard                 # .app
defaults delete app.dropboard.Dropboard dropboard.corner
```

### Testschritte Menüleiste (Tag `[SETTINGS]`)

| # | Aktion | Erwartet (Log) | Prüfen (Auge) |
|---|---|---|---|
| 8 | Start (`swift run Dropboard` bzw. `open dist/Dropboard.app`) | `[SETTINGS] Start ecke=topRight verzögerung=300ms anmeldung(spiegel)=false version=dev …` (`.app`: `version=<X> (Build <n>) anmeldung=notRegistered`; `swift run`: `anmeldung=nur in Dropboard.app (…)`), `[SETTINGS] Menüleisten-Symbol angelegt button=true image=true template=true`, `[SETTINGS] Hotkey ⌃⌥⌘E (Eselsohr ausblenden) registriert=true (Carbon RegisterEventHotKey, ohne Berechtigung)` | Symbol in der Menüleiste (hell/dunkel passend); **keine** Berechtigungsabfrage; Klick öffnet das Menü, Menüleiste bleibt bei der vorderen App, kein `!!! DROPBOARD SELBST AKTIVIERT` |
| 8b | Menü → Board öffnen | `[SETTINGS] Menü: Board öffnen`, `[FOCUS] vor Board öffnen (Menü) …`, `[VIEW] Ansichtsmodus geöffnet grund=Menüleiste …` | wie Test 7; Esc oder Klick aufs Eselsohr schließt (7c/7d). **Befund**, falls Esc nicht ankommt (`boardKey=false`, kein Klick vorher) |
| 8c | ⌃⌥⌘E (TextEdit vorn), dann nochmal | `[SETTINGS] Eselsohr ausgeblendet quelle=Hotkey ⌃⌥⌘E visible=false (nicht gespeichert; …)`, dann `… eingeblendet … visible=true` | Eselsohr weg/wieder da; TextEdit bleibt vorn; Screenshot (⌘⇧3) ohne Eselsohr |
| 8d | Menü → Eselsohr ausblenden | `quelle=Menü`; Menü erneut öffnen: Häkchen gesetzt, rechts `⌃⌥⌘E` | wie 8c |
| 8e | ausgeblendet, App beenden und neu starten | kein Ausblenden-Eintrag; `[WIN] Start ear … visible=true` | Eselsohr wieder sichtbar |
| 8f | Ecke → je Unten links, Unten rechts, Oben links, Oben rechts | `[SETTINGS] Ecke topRight → bottomLeft ear=(12,<dock+2> 40x40) visibleFrame=(…) …`, `[WIN] Ecke geändert ear …` | Eselsohr sofort in der Ecke, 12 pt seitlich, knapp über dem Dock bzw. unter der Menüleiste; umgeknickte Ecke zeigt zur Bildschirmecke |
| 8g | je Ecke: Drag-Hover (5) und Klick (7) | wie 5/7 | Papier blättert **aus der gewählten Ecke** auf und klappt dorthin zu |
| 8h | Ecke wählen, App neu starten | `[SETTINGS] Start ecke=<gewählt> …` | Eselsohr in der gespeicherten Ecke; `--snapshot` schreibt `…-ear.png` gespiegelt (`ecke=<gewählt>`) |
| 8i | Verzögerung → 800 ms, dann Drag aufs Eselsohr | `[SETTINGS] Verzögerung bis Aufklappen 300ms → 800ms (ab dem nächsten Drag)`, `[HANDOFF] draggingEntered win=ear … → Expand-Timer 800ms` | Board öffnet spürbar später; Neustart: `verzögerung=800ms` |
| 8j | Beim Anmelden starten (aus `/Applications/Dropboard.app`) | `[SETTINGS] Beim Anmelden starten → true ok status=notRegistered→enabled app=/Applications/Dropboard.app` (oder `→requiresApproval` + Systemeinstellungen öffnen sich; oder `FEHLER …` – dann bleibt das Häkchen aus) | Häkchen; Eintrag unter Systemeinstellungen → Allgemein → Anmeldeobjekte; ab-/anmelden: Dropboard startet. Ausschalten: `→ false ok status=enabled→notRegistered` |
| 8k | Beim Anmelden starten unter `swift run` | – | Eintrag grau „(nur in Dropboard.app)“ |
| 8l | Board-Ordner im Finder zeigen | `[SETTINGS] Board-Ordner im Finder zeigen …/Boards/default` | Finder mit markiertem Ordner `default` |
| 8m | Über Dropboard | – | Untermenü „Dropboard <Version> (Build <n>)“ bzw. „Dropboard dev“ |
| 8n | Dropboard beenden | `[SETTINGS] Dropboard beenden (Menüleiste)` | Eselsohr und Symbol weg, Prozess beendet (`pgrep Dropboard` leer) |
| 8o | Hotkey-Konflikt (optional) | andere App mit ⌃⌥⌘E belegen, Dropboard starten: `registriert=false FEHLER RegisterEventHotKey OSStatus=-9878 (… belegt)` | Menü-Schalter funktioniert weiter |

## Manuelle Tests gegen die Interaktionstabelle

Vorher: Log mitlaufen lassen (`tail -f ~/Library/Logs/Dropboard/dropboard.log`). Je Test notieren: wer, Datum,
macOS-Version, Ergebnis, Logzeilen. Die erwarteten Zeilen sind Hypothesen, Abweichungen sind Befunde.

| # | Zeile der Interaktionstabelle / Schritt | Aktion | Erwartet (Log) | Prüfen (Auge) |
|---|---|---|---|---|
| 0 | Selftest/Snapshot | `swift run Dropboard --selftest`; `--snapshot /tmp/db.png --snapshot-demo`, dann mit `--snapshot-dimmed` | `185/185 PASS` (96 + 47 `view:` + 42 `settings:`), Exit 0; `[WIN] Snapshot Board geschrieben … items=5`, `[WIN] Snapshot Eselsohr geschrieben …-ear.png` | PNG: Off-White + Noise, harte Schatten 1–2 px unten rechts, Kipp ±1–2°, ein leeres Platzhalter-Rechteck, Eselsohr als Papiereck |
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
| 7 | Klick aufs Eselsohr (Schritt 7) | TextEdit vorn, Eselsohr anklicken | `[WIN] Klick auf ear ohne Drag → Ansichtsmodus`, `[FOCUS] nach Klick … NSApp.isActive=false earKey=true`, `[VIEW] Ansichtsmodus geöffnet grund=Klick aufs Eselsohr mode=two-panels items=N StopMotion reveal frames=3 duration=0.500s animated=true jitter=true reduceMotion=false abgedunkelt=false`, `[WIN] Ansichtsmodus offen board … visible=true key=true`, `[FOCUS] Ansichtsmodus offen frontmost=com.apple.TextEdit … NSApp.isActive=false keyWindow=board … boardKey=true` | Papier blättert in 3 harten Schritten aus der Ecke auf, nicht abgedunkelt; Eselsohr bleibt als Ecke sichtbar; Menüleiste bleibt TextEdit; kein `!!! DROPBOARD SELBST AKTIVIERT`. **Befund**, falls `boardKey=false` – dann 7c prüfen |
| 7b | Auswahl | Bild anklicken, dann Papier anklicken | `[VIEW] Auswahl id=… datei=… mitte=(…)`, dann `[VIEW] Auswahl aufgehoben (Klick aufs Papier)` | dünner Graphit-Rahmen, kein Blau; verschwindet wieder |
| 7c | Esc schließt | Esc drücken | `[VIEW] Taste Esc fenster=board NSApp.isActive=false` (bei `fenster=ear` wirkte `makeKey()` nicht, Esc kam über das Eselsohr), `[VIEW] Ansichtsmodus schließen grund=Esc StopMotion reveal rückwärts frames=3 duration=0.500s`, `[VIEW] Ansichtsmodus geschlossen grund=Esc offen=…ms schließen=~500ms`, `[FOCUS] nach Ansichtsmodus frontmost=com.apple.TextEdit NSApp.isActive=false keyWindow=nil` | 3 harte Frames zur Ecke, dann weg. Danach tippen: Text landet in TextEdit. **Befund**: `WARNUNG nach Ansichtsmodus: Eselsohr ist key` oder Tippen kommt nicht in TextEdit an |
| 7d | Klick aufs Eselsohr schließt | öffnen, Eselsohr erneut anklicken | `[VIEW] Ansichtsmodus schließen grund=Klick aufs Eselsohr …`, `… geschlossen grund=Klick aufs Eselsohr` | wie 7c |
| 7e | Umsortieren | Bild ziehen und loslassen | `[VIEW] Auswahl id=…`, `[VIEW] Umsortieren Start id=… von=(…) (Bild folgt der Maus direkt, ohne Jitter)`, beim Loslassen `[VIEW] Umsortieren id=… von=(…) losgelassen=(…) nach=(…) rotation=a°→b° StopMotion move frames=2 duration=0.333s animated=true jitter=true`, `[STORE] gespeichert items=N … (Umsortieren …)` | während des Ziehens klebt das Bild ohne Zittern/Verzögerung am Cursor und liegt oben; nach dem Loslassen 2 harte Frames auf den Grid-Punkt, neuer leichter Kipp. Neustart: Position, Kipp, Stapel bleiben |
| 7f | Löschen | Bild anklicken, Backspace (dann ein zweites mit Entf/fn-Backspace) | `[VIEW] Taste Backspace fenster=…`, `[VIEW] Löschen id=… taste=Backspace datei=<uuid>.<ext> StopMotion delete frames=2 duration=0.333s animated=true papierkorb=…/trash/<uuid>.<ext> items=N-1`, `[STORE] gespeichert items=N-1 … (Löschen …)` | 2 harte Frames (kleiner, weg); Datei in `trash/`, nicht mehr in `images/`; `board.json` ohne Eintrag. Backspace ohne Auswahl: `[VIEW] Backspace ohne Auswahl → nichts gelöscht` |
| 7g | Drop im Ansichtsmodus | Ansichtsmodus offen, Finder-Bild bzw. ⌘⇧4-Thumbnail aufs Board ziehen und loslassen | `[HANDOFF] neue Drag-Session seq=… (Ansichtsmodus)`, `[VIEW] fremder Drag draggingEntered win=board … bild=true → Drop an Cursor`, `[DROP] performDragOperation win=board art=Drop im Ansichtsmodus dropPos=…`, `[MOTION] StopMotion drop … frames=2 … jitter=true`, `[VIEW] Drop im Ansichtsmodus bilder=1 cursor=(…) → Board bleibt offen`; **kein** `Board geschlossen` | Bild an der Cursorposition, 2 Drop-Frames, Board bleibt offen; danach Esc schließt wie 7c |
| 7h | Reduce Motion | mit `--reduce-motion` 7, 7e, 7f, 7c | `reveal frames=1 duration=0.000s animated=false`, `move frames=1 … animated=false`, `delete frames=1 … animated=false`, `reveal rückwärts frames=1 … animated=false`, `schließen=0.…ms` | alles sofort, kein Zittern |
| 7i | grow | Start mit `--handoff grow`, 7–7g | `mode=grow`, `[VIEW] Taste Esc fenster=ear(grown)`, Klick auf die Eselsohr-Ecke schließt | wie two-panels; danach Eselsohr wieder 40×40 an seinem Platz |

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
- Ansichtsmodus, Fokus nach dem Schließen (⚠️ VERIFIZIEREN, Test 7c/7d): Ein Klick aufs Eselsohr macht es key (wie
  schon in Schritt 1–6). Bleibt danach ein Dropboard-Panel key (`WARNUNG nach Ansichtsmodus: Eselsohr ist key`), landen
  Tasten nicht in der Ursprungs-App. Gegenmaßnahme dann: `DropboardPanel.canBecomeKey` fürs Eselsohr `false` (Klicks
  kommen trotzdem an, `acceptsFirstMouse`), Tasten im Ansichtsmodus nur noch über das per `makeKey()` key gemachte Board.
- Ansichtsmodus: Umsortieren prüft keine Überlappung (bewusst: Moodboard, frei positionierbar; nur Grid-Snap und
  Ablagefläche). Bilder, die noch als Platzhalter auf ein Promise warten, sind nicht wählbar.
- Ansichtsmodus bei Bildschirmwechsel: wird ohne Animation beendet (`[VIEW] Ansichtsmodus sofort geschlossen`).

## App bauen und verteilen

Aus dem SwiftPM-Executable wird eine doppelklickbare `Dropboard.app` (plus `.zip` und `.dmg`). Nur auf dem Mac,
nur Command Line Tools (kein Xcode). Signatur **nur ad-hoc**, keine Notarisierung (es gibt keine Signier-Identität).

```sh
app/scripts/build-app.sh                  # baut nach app/dist/: Dropboard.app, Dropboard-<version>.zip/.dmg, Dropboard-README.md
app/scripts/build-app.sh --publish        # zusätzlich in die Dropbox (synct auf den Laptop), Muster wie nineTracker
app/scripts/build-app.sh --install        # zusätzlich nach /Applications (laufende Instanz wird per pkill beendet)
app/scripts/build-app.sh --version 0.2 --arm64-only --no-hardened-runtime   # Version fest, kein x86_64-Versuch, ohne Hardened Runtime
```

- **Version:** `--version X.Y[.Z]`, sonst aus `git describe --tags` (Tags `vX.Y`), sonst `0.1.<Commit-Zahl>`.
  Build-Nummer = `git rev-list --count HEAD`.
- **Architekturen:** arm64 immer; x86_64 wird per `swift build --triple x86_64-apple-macosx14.0` (eigener
  `--scratch-path` unter `.build/`) versucht und per `lipo` zu universal zusammengefügt. Schlägt das fehl: Warnung,
  weiter nur arm64. ⚠️ VERIFIZIEREN: Cross-Build mit reinen CLT ist ungetestet.
- **Bundle:** `Contents/MacOS/Dropboard`, `Contents/Info.plist` (Vorlage `app/Packaging/Info.plist`, `LSUIElement`,
  ab macOS 14), `Contents/Resources/AppIcon.icns` (per `sips`/`iconutil` aus `app/Packaging/AppIcon-1024.png`),
  `Contents/Resources/noise.png`.
- **Ressourcen:** `Bundle.module` wird nicht mehr benutzt (der SwiftPM-Accessor ruft in einer `.app` auf einem
  anderen Mac `fatalError`). `ResourceLocator.swift` sucht `noise.png` in `Contents/Resources`, im SwiftPM-Bundle
  in `Contents/Resources` und neben dem Executable (`swift build`/`swift run`); fehlt sie, gibt es Papier ohne
  Noise und eine Logzeile, keinen Absturz.
- **Signatur:** `codesign --force --sign - --timestamp=none --options runtime` (bei Fehler ohne Runtime), danach
  `codesign --verify --strict`. `spctl` meldet bei Ad-hoc „rejected“ – erwartet, nur informativ.
- **Dropbox (`--publish`):** `~/Library/CloudStorage/Dropbox/_PROJECTS/CLAUDE CODE/Dropboard/` mit
  `versions/v<version>/Dropboard-v<version>.app`, `Dropboard-latest.zip`, `Dropboard-latest.dmg`, `Dropboard-README.md`.
  Fehlt der Ordner `CLAUDE CODE`, bricht das Skript vor dem Build ab.
- **Erster Start auf einem anderen Mac:** siehe `app/Packaging/Zuerst-lesen.md` (liegt im DMG als „Zuerst lesen.txt“):
  Systemeinstellungen → Datenschutz & Sicherheit → „Trotzdem öffnen“, oder `xattr -dr com.apple.quarantine`.
- **Icon ändern:** `python3 app/Packaging/make_icon.py` (numpy, Pillow) schreibt `app/Packaging/AppIcon-1024.png` neu.
