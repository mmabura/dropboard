# Phase 3 – Verhaltens-Review gegen die Interaktionstabelle

Stand: 7. Okt. 2026 · Review-Sub-Agent (Opus 5.5) · Grundlage: nur `docs/briefing.md` und `app/Sources/**`

**Methode:** Statische Prüfung, weil die App hier nicht laufen kann (Linux). Für jeden Soll-Punkt wurde der Code-Pfad nachverfolgt (Ereignis → Methoden → sichtbares Ergebnis). Pfadangaben sind relativ zu `app/Sources/`, mit `Dropboard/` = App-Target und `DropboardCore/` = Logik-Target. Alles, was von WindowServer, Fokus, Rendering oder Wahrnehmung abhängt, ist als ❓ markiert.

**Legende:** ✅ erfüllt · ⚠️ abweichend · ❌ fehlt · ❓ nur auf Hardware prüfbar · Schwere: Hoch / Mittel / Niedrig

## Zählung

| ✅ erfüllt | ⚠️ abweichend | ❌ fehlt | ❓ Hardware | Summe |
|---|---|---|---|---|
| 49 | 9 | 4 | 12 | 74 |

Befunde: B1–B13 (Mittel: B1, B2, B3, B12 · Niedrig: B4–B11, B13). Kein Befund mit Schwere Hoch.

---

## 1. Eselsohr

| # | Soll (Briefing) | Ist (Code-Pfad) | Status | Befund |
|---|---|---|---|---|
| E-1 | „ca. 40 px“ | `earSize = 40` pt, `Dropboard/DropboardConfig.swift:23` → `ScreenGeometry.earFrame` `:51-54` → `DropboardCore/EarPlacement.swift:24-29` | ✅ | – |
| E-2 | „oben rechts“ (Standard) | `defaultCorner = .topRight` `DropboardConfig.swift:29`; `Settings.corner` fällt darauf zurück, `Dropboard/Settings.swift:32-35` | ✅ | – |
| E-3 | „knapp unter der Menüleiste, etwas vom Rand eingerückt“ | `visibleFrame.maxY − 2 pt` (unter der Menüleiste) und `maxX − 12 pt`, `EarPlacement.swift:26-27`, `DropboardConfig.swift:25-27`. Ob das von Mitteilungen verdeckt wird („Standardabstand testen“), ist nur auf dem Mac prüfbar. | ✅ | – |
| E-4 | „Immer sichtbar“, über allen Fenstern inkl. Fullscreen-Spaces | `DropboardPanel`: `.borderless, .nonactivatingPanel`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `level = .statusBar`, `Dropboard/Panels.swift:9-22`; `showEar()` → `orderFrontRegardless`, `Dropboard/BoardPresenter.swift:83-85`, `Dropboard/AppController.swift:67` | ❓ | – |
| E-5 | „gedämpft“ | Lasche `earBackHex 0xE5E3DD` mit Noise, Layer-`opacity 0.9`, `Dropboard/PaperStyle.swift:27-28`, `Dropboard/BoardPresenter.swift:279-288`. Ob das gedämpft genug wirkt, ist eine Sichtprüfung. | ❓ | – |
| E-6 | „kein Schatten“ | `hasShadow = false` `Panels.swift:16`; `PaperArt.earImage` zeichnet keinen Schatten, `Dropboard/PaperArt.swift:39-112`; Kommentar „gedämpft, kein Schatten“ `BoardPresenter.swift:285` | ✅ | – |
| E-7 | „still: keine Reaktion auf Drag-Start“ | Es gibt keinen globalen Drag- oder Event-Monitor (kein `addGlobalMonitor` im Code). `dragEntered` am Eselsohr setzt nur `phase = .hovering` und startet den Expand-Timer, das Eselsohr-Bild bleibt unverändert, `Dropboard/DragCoordinator.swift:177-213`. Sichtbar ist nur das systemeigene Copy-Badge am Cursor (Rückgabe `.copy`). | ✅ | – |
| E-8 | „keine Idle-Animation“ | Im Ruhezustand läuft weder ein Timer noch eine Animation. Der einzige wiederholende Timer ist der Watchdog, und der läuft nur in `.expanded`, `DragCoordinator.swift:415-426`. | ✅ | – |
| E-9 | „Position in allen vier Ecken wählbar“ | `EarCorner` (4 Fälle) `DropboardCore/EarPlacement.swift:11-18`; Menü „Ecke“ `Dropboard/StatusMenu.swift:92-102` → `AppController.applyCorner` `AppController.swift:170-181` → `BoardPresenter.setCorner` `:263-266`; Grafik gespiegelt `PaperArt.swift:47-49` | ✅ | – |
| E-10 | „Eselsohr: gleiches Papier“ | Die Lasche ist absichtlich als Rückseite gefärbt (`0xE5E3DD`, dunkler und kühler als das Board `0xF4F0E8`), `PaperStyle.swift:25-27`, `PaperArt.swift:31-32,61-62` | ⚠️ | **B13** |
| E-11 | (implizit) Eselsohr als Drop- und Klickziel ca. 40 px | Gezeichnet wird nur die Lasche, also das halbe Quadrat. Das Dreieck zur Bildschirmecke ist transparent, `PaperArt.swift:27-28,51-55`. Bei einem nicht-opaken, randlosen Panel ist auf dem Mac zu prüfen, ob transparente Pixel noch Drags und Klicks annehmen. Sonst ist die Trefferfläche nur halb so groß. | ❓ | – |

## 2. Drag + Hover auf dem Eselsohr

| # | Soll | Ist | Status | Befund |
|---|---|---|---|---|
| D-1 | Verzögerung bis Expand (Standard ca. 300 ms) | `scheduleExpand` → `perform(#selector(expandFired), afterDelay: settings.expandDelay)`, `DragCoordinator.swift:356-359`; Standard 300 ms, Auswahl 150/300/500/800, `DropboardCore/EarPlacement.swift:47-54`, `Settings.swift:38-51`. Abbruch bei `draggingExited` vor dem Expand: `DragCoordinator.swift:242-246`. | ✅ | – |
| D-2 | „in ca. 200 ms“ | `RealtimeMotion.duration = 0.2`, `Dropboard/Motion.swift:53,125` | ✅ | – |
| D-3 | „flüssig … Kein Bounce“ | `CABasicAnimation` auf `transform`, `timingFunction .easeOut`, kein Spring, `Motion.swift:121-128` | ✅ | – |
| D-4 | „vom Eck diagonal über den Bildschirm“, Scale/Mask vom Eselsohr | `openForDrag` → `RealtimeMotion.reveal(scene.sheet, from: anchor)`, `BoardPresenter.swift:116-137`. Die Maske skaliert von 0,001 auf 1 um den Anker, `Motion.swift:60-79,108-119`. Der Anker ist die äußere Eselsohr-Ecke, `BoardPresenter.swift:107-109`, `EarPlacement.swift:33-42`. | ✅ | – |
| D-5 | „Board wird als Overlay sichtbar“ | `scene.setDimmed(true)` vor dem Reveal, `BoardPresenter.swift:119`; das Board-Panel kommt per `orderFrontRegardless` nach vorn, `:125` | ✅ | – |
| D-6 | „Ursprungs-App bleibt aktiv“ | Nicht aktivierendes Panel, nie `NSApp.activate` oder `makeKeyAndOrderFront`, beim Drag-Expand kein `makeKey`, `BoardPresenter.swift:7,116-137`, `Panels.swift:10`. Ob der Fokus wirklich bleibt, zeigt erst das Fokus-Log (`Diagnostics.logFocus`) auf dem Mac. | ❓ | – |
| D-7 | Drag-Session geht nahtlos vom Eselsohr aufs Board über | two-panels: Das Board-Panel kommt über das Eselsohr; `dragEntered`/`dragUpdated` auf dem Board in `.expanded` geben `.copy` zurück, `DragCoordinator.swift:183-193,215-231`. Ob AppKit ein neu erschienenes Panel unter dem stillstehenden Cursor als Ziel erkennt, ist das offene Risiko T4 aus dem Code. | ❓ | – |
| D-8 | Nur Bilder lösen etwas aus (Priorität Bilder) | `looksLikeImage` ist false → Rückgabe `[]`, kein Expand: „Eselsohr bleibt still“, `DragCoordinator.swift:205-208`, `Dropboard/ImageImporter.swift:62-69` | ✅ | – |
| D-9 | „flüssig“ (Bildrate) | Die Maske läuft als Offscreen-Pass über den ganzen Bildschirm (Code-Hinweis V10, `Motion.swift:70-71`). Ob 200 ms ohne Ruckler laufen, misst erst der Performance-Review auf dem Mac. | ❓ | – |

## 3. Drop auf Board

| # | Soll | Ist | Status | Befund |
|---|---|---|---|---|
| B-1 | „Bild landet an der Cursorposition (unsichtbares Grid snappt)“ | `performDrop` → `presenter.boardPoint(fromScreen:)` → `board.place(.atCursor)`, `DragCoordinator.swift:300-305` → `BoardLayout.dropCenter` (Mittelpunkt auf 24-pt-Grid, auf die Ablagefläche mit 48 pt Rand begrenzt), `Dropboard/BoardController.swift:88-89`, `DropboardCore/BoardLayout.swift:94-108,32-34`. Am Bildschirmrand wird nach innen verschoben, das ist plausibel. | ✅ | – |
| B-2 | Grid „ist aber unsichtbar“ | Kein Grid-Layer im Layer-Baum, `Dropboard/BoardScene.swift:23-45` | ✅ | – |
| B-3 | „Overlay schließt sofort“ | Das Board bleibt nach dem Drop **333 ms** offen (`dropCloseDelay = 2 × 1/6 s`, `DropboardConfig.swift:18-20`; `perform(closeAfterDrop, afterDelay:)` `DragCoordinator.swift:306-308`). Danach blendet `closeImmediately` das Board ohne Zuklapp-Animation aus (`orderOut`), `DragCoordinator.swift:403-411`, `BoardPresenter.swift:156-179`. In diesen 333 ms bleibt das Papier abgedunkelt (`setDimmed(false)` kommt erst in `closeImmediately`, `:174`). Mit „Bewegung reduzieren“ schließt es nach 0 ms. | ⚠️ | **B1** |
| B-4 | (implizit) Während das Board sichtbar ist, „landet“ das Bild sichtbar | `place` legt zuerst einen **leeren Platzhalter** an (220×220 pt, `placeholderHex`), `BoardController.swift:85,96-101`, `BoardScene.swift:99-104`. Das echte Bild kommt erst nach asynchronem Dekodieren (`ImageImporter.swift:217-229`) bzw. nach Erfüllung des File-Promise (`:117-128`) per `setImage`, `BoardScene.swift:116-124`. Beim Screenshot-Thumbnail (Promise) und bei großen Dateien sieht man in den 333 ms wahrscheinlich nur ein leeres Papierrechteck. | ⚠️ | **B2** |
| B-5 | „Fokus bleibt in der Ursprungs-App“ | Keine Aktivierung im Drop-Pfad; Fokus-Log nach dem Drop und nach 500 ms, `DragCoordinator.swift:315-316` | ❓ | – |
| B-6 | Jitter nach dem Drop | `postDropMotionOptions()` → `jitter: phase == .dropClosing`. Die Phase wird vor `place` gesetzt, `DragCoordinator.swift:171-173,302-304` | ✅ | – |

## 4. Quick-Drop aufs Eselsohr

| # | Soll | Ist | Status | Befund |
|---|---|---|---|---|
| Q-1 | „Bild landet automatisch an der nächsten freien Stelle“ | `performDrop` in `.hovering`/`.idle` → `board.place(.nextFreeSlot)`, `DragCoordinator.swift:309-312` → `freeSlot` (Lesereihenfolge, Platzhalter reservieren Platz), `BoardController.swift:216-231`, `BoardLayout.swift:59-81`. Der Expand-Timer wird in `prepareDrop` abgebrochen, `DragCoordinator.swift:262-267`. | ✅ | – |
| Q-2 | „Keine Animation“ | `dropMotion: nil` → `StopMotion.setModel` (hart gesetzt), Board wird nicht gezeigt, `BoardController.swift:105-110`, `Motion.swift:147-154` | ✅ | – |

## 5. Maus verlässt Board ohne Drop / Esc

| # | Soll | Ist | Status | Befund |
|---|---|---|---|---|
| V-1 | „Maus verlässt Board ohne Drop → Overlay klappt zu“ | Das Board deckt den **ganzen Bildschirm** ab, auch die Menüleiste (`boardFrame = screen.frame`, `DropboardConfig.swift:57`; Level `.statusBar`). `collapse` wird nur ausgelöst, wenn `draggingExited` meldet, dass der Cursor außerhalb von `boardFrame` liegt, `DragCoordinator.swift:254-259`. Mit einem Monitor ist das nicht erreichbar. Gleichzeitig nimmt das Board überall Drops an (`dragUpdated` → `.copy`, `:215-231`), Loslassen ist also immer ein Drop. Nach einem versehentlichen Expand geht es nur per Esc zurück. | ⚠️ | **B3** |
| V-2 | „Esc → Overlay klappt flüssig zu“ | Während des Drags gibt es keine eigene Tastenbehandlung; der Code verlässt sich darauf, dass das System den Drag abbricht. Dann kommt `draggingExited` mit dem Cursor im Board, eine Karenz von **300 ms** (`exitInsideGrace`, `DropboardConfig.swift:37`, `DragCoordinator.swift:443-446`) oder `draggingEnded` ohne Drop (`:332-334`), danach 200 ms Zuklappen. Bis das Zuklappen beginnt, können bis zu 300 ms vergehen. | ⚠️ | **B4** |
| V-3 | „klappt flüssig zu“ (Realtime, ca. 200 ms, zum Eselsohr) | `collapse` → `presenter.collapse` → `RealtimeMotion.collapse(to: anchor)`: Maske von Identität auf 0,001 in 200 ms mit easeOut, danach `closeImmediately`, `DragCoordinator.swift:387-400`, `BoardPresenter.swift:141-153`, `Motion.swift:85-100` | ✅ | – |
| V-4 | „nichts passiert“ | Keiner der Zuklapp-Pfade ruft `place` oder `save` auf, `DragCoordinator.swift:387-400` | ✅ | – |
| V-5 | (implizit) Maustaste losgelassen, aber kein Drop zugestellt | Watchdog: Maustaste 500 ms lang oben → `collapse`, `DragCoordinator.swift:447-458`, `DropboardConfig.swift:34` | ✅ | – |

## 6. Klick aufs Eselsohr: Ansichtsmodus

| # | Soll | Ist | Status | Befund |
|---|---|---|---|---|
| A-1 | „Klick aufs Eselsohr (kein Drag) → Board öffnet sich im Ansichtsmodus“ | `DropTargetView.mouseDown` → `coordinator.mouseDown` → `openViewing`, `Panels.swift:58`, `DragCoordinator.swift:60-68,92-100`. Hinweis: Das Board öffnet schon beim Drücken der Maustaste (mouseDown), nicht erst beim Loslassen. | ✅ | – |
| A-2 | „Aufblättern im Ansichtsmodus: 3 Frames“ | `openForViewing` → `ViewModeSequences.open` = `reveal` (Scale 0,6 → 0,85 → 1,0) → `StopMotionSheet.play` (discrete) aus der Eselsohr-Ecke, `BoardPresenter.swift:194-226`, `DropboardCore/BoardEditing.swift:59-61`, `DropboardCore/StopMotion/Sequences.swift:26-31`, `Dropboard/ViewMotion.swift:23-40` | ✅ | – |
| A-3 | „betrachten“ | Board ohne Abdunklung, alle Items sichtbar, `BoardPresenter.swift:198` | ✅ | – |
| A-4 | „umsortieren“ | mouseDown → Treffer und Auswahl; mouseDragged ab 3 pt → das Bild folgt der Maus direkt; mouseUp → Snap aufs Grid, neue Rotation, Stop-Motion-`move` (2–4 Frames), speichern. `Dropboard/ViewModeController.swift:112-164`, `BoardController.swift:151-179`. Ob `mouseDragged`/`mouseUp` auf einem nicht aktivierenden Panel ankommen, ist im Code als „⚠️ VERIFIZIEREN“ markiert, `Panels.swift:59-62`. | ❓ | – |
| A-5 | „löschen“ | Backspace/Entf → `deleteSelected` → `board.deleteItem` (Stop-Motion `delete`, 2 Frames) → aus `board.json` entfernt, Datei nach `trash/`, `ViewModeController.swift:183-197,219-233`, `BoardController.swift:183-212`, `BoardEditing.swift:91-128`. Funktioniert nur, wenn ein Panel key ist (siehe A-7). | ✅ | – |
| A-6 | „exportieren“ | Im ganzen Code gibt es weder Export noch PNG/PDF-Ausgabe oder Ordner-Export. Nur „Board-Ordner im Finder zeigen“, `StatusMenu.swift:121`. | ❌ | **B5** |
| A-7 | „Schließen per Esc“ | Lokaler Key-Monitor (keyCode 53) → `closeViewing`, `ViewModeController.swift:201-209,219-233`. Das setzt voraus, dass ein Dropboard-Panel key ist (`board?.makeKey()`, `BoardPresenter.swift:207-210`, im Code als „⚠️ VERIFIZIEREN“ markiert). | ❓ | – |
| A-8 | „Schließen per … Klick aufs Eselsohr“ | Das Eselsohr liegt über dem Board (`ear.orderFrontRegardless()` nach dem Board, `BoardPresenter.swift:206`). In `.viewing` prüft `isOnEar` den Klick → `closeViewing`, `DragCoordinator.swift:68-71`, `BoardPresenter.swift:256-258` | ✅ | – |
| A-9 | Zuklappen im Ansichtsmodus stepped | `ViewModeSequences.close` (0,85 → 0,6 → weg, 3 Frames), danach `orderOut`, `BoardEditing.swift:67-78`, `BoardPresenter.swift:231-252` | ✅ | – |
| A-10 | Fokus nach dem Ansichtsmodus zurück bei der Ursprungs-App (Designregel „Fluss nie unterbrechen“) | Das Board wird per `makeKey` key, aber beim Schließen gibt der Code den Key-Status nicht aktiv zurück. Er protokolliert nur eine Warnung, falls das Eselsohr key bleibt, `ViewModeController.swift:100-108`. Tastendrücke könnten danach bei Dropboard landen. | ❓ | – |

## 7. Look: Papier

| # | Soll | Ist | Status | Befund |
|---|---|---|---|---|
| L-1 | „warmes Off-White, kein reines Weiß“ | `paperHex 0xF4F0E8`, `PaperStyle.swift:8`, `BoardScene.swift:28` | ✅ | – |
| L-2 | Noise „bei 100 % Zoom gerade sichtbar“ | `noise.png` (256×256, 8-bit Graustufen) einmal gekachelt, Layer-`opacity 0.05`, `PaperStyle.swift:12`, `BoardScene.swift:30,62-65`, `PaperArt.swift:9-25`. Ob sie „gerade sichtbar“ ist, ist eine Sichtprüfung. | ❓ | – |
| L-3 | „Flach: keine Vignette, kein Verlauf“ | Nur Volltonfarbe plus Noise plus optionale Abdunklung, kein Gradient-Layer, `BoardScene.swift:23-45` | ✅ | – |
| L-4 | „harter kleiner Schatten (1–2 px Versatz, kein Blur)“ | `shadowRadius 0`, `shadowOffset (1.5, −1.5)`, `shadowOpacity 0.45`, Graphit, expliziter `shadowPath`, `PaperStyle.swift:18-20`, `BoardScene.swift:162-181` | ✅ | – |
| L-5 | „minimale Zufallsrotation von ±1–2°“ | `tiltRange 1.0...2.0` mit zufälligem Vorzeichen, `BoardLayout.swift:32-34,119-122`; bei jedem Ablegen und Umsortieren, `BoardController.swift:93,132,171` | ✅ | – |
| L-6 | „Overlay-Hintergrund während des Drags: abgedunkeltes Papier statt schwarzer Transparenz“ | `dimLayer` in Graphit `0x3A2E22`, `opacity 0.35`, zwischen Papier und Bildern, nur beim Drag-Expand, `BoardScene.swift:31-37,73-76`, `BoardPresenter.swift:119,174,198` | ✅ | – |
| L-7 | Typografie: Monospace oder unregelmäßige Serifenlose, Graphit statt Schwarz | Die eigene UI enthält keinen Text (keine `NSFont`-Nutzung). Das Menüleisten-Menü ist das Systemmenü. Damit nicht anwendbar, kein Verstoß. | ✅ | – |
| L-8 | „Keine Systemblau-Akzente“ | Auswahlrahmen 1 pt Graphit (`ViewModeStyle`), `ViewModeController.swift:5-8`, `BoardScene.swift:134-142`; Menüleisten-Symbol als Template-Bild, `StatusMenu.swift:254-288`. Die Hervorhebung im Systemmenü gehört nicht zur eigenen UI. | ✅ | – |
| L-9 | „Textur … als eine einzelne PNG-Noise-Ebene, nicht prozedural“ | `Resources/noise.png`, geladen über `PaperArt.loadNoiseTile`, `PaperArt.swift:9-13` | ✅ | – |

## 8. Motion: zwei Animationspfade

| # | Soll | Ist | Status | Befund |
|---|---|---|---|---|
| M-1 | „Beide Pfade im Code klar getrennt und benannt“ | `RealtimeMotion` (`CABasicAnimation`) vs. `StopMotion` (`CAKeyframeAnimation .discrete`), ohne gemeinsamen Code, `Motion.swift:5-9,49-129,131-193`; `StopMotionSheet` gehört ausdrücklich zum Stop-Motion-Pfad, `ViewMotion.swift:5-12` | ✅ | – |
| M-2 | „6 fps (ca. 167 ms pro Frame), stepped, keine Easing-Kurven“ | `StopMotionClock.fps = 6`, `frameDuration = 1/6`, `DropboardCore/StopMotion/Basics.swift:9-12`; `calculationMode = .discrete`, gleichmäßige `keyTimes`, `Motion.swift:178-185`, `DropboardCore/StopMotion/Planner.swift:98-99` | ✅ | – |
| M-3 | „Drop: 2 Frames (groß, dann final mit Schatten und Kipp)“ | Frame 0: Scale 1,08, Rotation 0, mit Jitter; Frame 1: Ziel mit Kipp, `Sequences.swift:17-23`. **Der Schatten ist aber in beiden Frames da**: Er hängt fest am Layer (`makeItemLayer`, `BoardScene.swift:168-172`), und `Pose` hat kein Schatten-Feld (`Basics.swift:44-56`). | ⚠️ | **B6** |
| M-4 | „Aufblättern im Ansichtsmodus: 3 Frames“ | siehe A-2 | ✅ | – |
| M-5 | „Umsortieren, Löschen, Tab-Wechsel: stepped“ | `move` (2–4 Frames, 120 pt pro Frame) und `delete` (2 Frames), `Sequences.swift:33-56`. Tabs gibt es noch nicht (Multi-Board kommt laut Briefing nach dem Prototyp). | ✅ | – |
| M-6 | „0,5–1 px Positions-Jitter, minimal variierende Rotation“ | `minOffset 0.5`, `maxOffset 1.0` in **pt**, auf Device-Pixel gerundet. Auf Retina (2×) sind das 1–2 px, `Basics.swift:65-89`. Rotation ±0,3°, `:68`. Im Ansichtsmodus dreht der Jitter die **bildschirmgroße Blatt-Maske** um ±0,3° um die Eselsohr-Ecke. An der fernen Kante sind das mehrere pt (bei 1500 pt Abstand ca. 8 pt), `ViewMotion.swift:29-30`. | ⚠️ | **B7** |
| M-7 | „Jitter … nie während eines Drags“ | Drag-Expand: Realtime-Pfad ohne Jitter. Jitter beim Drop nur in `.dropClosing`, `DragCoordinator.swift:171-173`. Ziehen im Ansichtsmodus: Das Model wird direkt gesetzt, laufende Keyframes werden entfernt, `ViewModeController.swift:123-139`, `BoardScene.swift:146-153`, `BoardController.swift:161-164`. Der letzte Frame ist immer exakt, ohne Jitter, `Planner.swift:84-86`. | ✅ | – |
| M-8 | „Timer-basierter globaler Ticker oder `CAKeyframeAnimation` mit `.discrete`“ | `CAKeyframeAnimation` `.discrete`, kein Ticker; Model-Wert vorher auf den Endzustand, `Motion.swift:156-176` | ✅ | – |
| M-9 | „Bewegung reduzieren“: ohne Jitter und Zwischenframes | `MotionPreferences` (Systemwert plus Notification plus `--reduce-motion`), `Motion.swift:22-47`. Planer: 1 Frame, kein Zufall, `Planner.swift:68-71`. Realtime-Reveal und -Collapse sofort, `Motion.swift:61-64,87-90`. Drop-Close nach 0 ms, `DragCoordinator.swift:306`. Ansichtsmodus sofort, `BoardEditing.swift:71-73`. | ✅ | – |

## 9. Speicherung und Herkunft

| # | Soll | Ist | Status | Befund |
|---|---|---|---|---|
| S-1 | „Bilder als Kopie in einem App-eigenen Ordner“ | `~/Library/Application Support/Dropboard/Boards/default/images/<uuid>.<ext>`, `DropboardCore/BoardStore.swift:14-35`. fileURL wird kopiert (`ImageImporter.swift:161-186`), Promise-Dateien aus `incoming/` verschoben (`:134-158`), Bilddaten als PNG geschrieben (`:189-213`). | ✅ | – |
| S-2 | „Board-Layout als JSON daneben“ | `board.json` wird atomisch geschrieben (ISO 8601, sortierte Keys), `BoardStore.swift:69-72,82-93`; Speichern nach jeder Änderung, `BoardController.swift:140-141,177,203,233-241` | ✅ | – |
| S-3 | „Quell-App“ mitschreiben | `source.app` = Bundle-ID der **vordersten** App zum Drop-Zeitpunkt, `DragCoordinator.swift:293`, `DropboardCore/BoardModel.swift:53-54`. Beim Screenshot-Thumbnail ist das vermutlich nicht die eigentliche Quelle, sondern die gerade aktive App. | ❓ | – |
| S-4 | „Dateipfad bzw. URL“ mitschreiben | `originalPath` nur beim Weg fileURL, `ImageImporter.swift:181`. Bei Browser-Bildern (Weg imageData) wird die Herkunfts-URL nicht gespeichert (`:208`, `originalName: nil`). Reine Bild-URLs werden nur geloggt, nicht importiert, `:91-93`. | ⚠️ | **B8** |
| S-5 | „Zeitstempel“ | `addedAt` auf ganze Sekunden, `BoardModel.swift:74-75,125-130`, gesetzt in `BoardController.swift:94,138` | ✅ | – |

## 10. Einstellungen und Ausblenden („Features nach dem Prototyp“)

| # | Soll | Ist | Status | Befund |
|---|---|---|---|---|
| X-1 | „Ecke (vier Positionen …)“ | Menü „Ecke“ wirkt sofort und wird gespeichert, `StatusMenu.swift:92-102,199-203`, `Settings.swift:32-35` | ✅ | – |
| X-2 | „… Einrückung“ | Fest: `earInset = 12`, `earEdgeGap = 2`, `DropboardConfig.swift:25-27`. Keine Einstellung. | ❌ | **B9** |
| X-3 | „Verzögerung bis Expand (Standard ca. 300 ms)“ | Menü „Verzögerung bis Aufklappen“ (150/300/500/800, Standard markiert), `StatusMenu.swift:104-114,205-208`, `AppController.swift:183-187` | ✅ | – |
| X-4 | „Overlay-Deckkraft“ | Fest: `dimOpacity = 0.35`, `PaperStyle.swift:15`. Keine Einstellung. | ❌ | **B10** |
| X-5 | „Ausblenden-Hotkey“ (als Einstellung) | Globaler Carbon-Hotkey **fest auf ⌃⌥⌘E**, nicht änderbar, `Dropboard/HotKey.swift:6-22`, Registrierung `AppController.swift:137-144`. Ob die Registrierung auf macOS 26 ohne Rückfrage klappt, ist im Code als „⚠️ VERIFIZIEREN“ markiert. | ⚠️ | **B11** |
| X-6 | „Menüleisten-Schalter, der das Eselsohr temporär versteckt“ | Menüpunkt „Eselsohr ausblenden“ → `toggleEarHidden` → `endAllImmediately` + `orderOut`, `StatusMenu.swift:84-88,194-197`, `AppController.swift:154-168`, `BoardPresenter.swift:89-96`. Bewusst nicht gespeichert, `Settings.swift:13`. | ✅ | – |

## 11. Mehrere Monitore

| # | Soll | Ist | Status | Befund |
|---|---|---|---|---|
| K-1 | „Das Board expandiert auf dem Bildschirm, auf dem der Drag läuft“ | Es gibt nur ein Eselsohr, und das Board liegt auf dessen Bildschirm (`boardFrame(screen)`, `BoardPresenter.swift:41`, `DropboardConfig.swift:57`). Weil der Drag das Eselsohr erreichen muss, stimmt das implizit. | ✅ | – |
| K-2 | „Ein Eselsohr pro Bildschirm oder nur auf dem Hauptbildschirm, als Einstellung“ | Genau ein Eselsohr, und zwar auf dem Bildschirm, **unter dem beim Start die Maus lag**, nicht auf dem Hauptbildschirm: `ScreenGeometry.screenUnderMouse()`, `AppController.swift:44`, `DropboardConfig.swift:71-74`. Bei Bildschirmänderungen bleibt es auf `ear.screen`, `AppController.swift:109-119`. Keine Einstellung. | ❌ | **B12** |

---

## Befundliste

| ID | Schwere | Punkt | Befund | Vorschlag |
|---|---|---|---|---|
| **B1** | Mittel | B-3 | Nach einem Board-Drop bleibt das Overlay 333 ms abgedunkelt sichtbar und verschwindet dann hart. Das Briefing verlangt „schließt sofort“. Allerdings fordert das Briefing selbst auch „Drop: 2 Frames“ (2 × 167 ms), die nur bei offenem Board sichtbar sein können. Der Code entscheidet diesen Widerspruch zugunsten der Frames (E8). | Produktentscheidung einholen. Variante a: sofort schließen und die Drop-Frames erst beim nächsten Öffnen zeigen bzw. weglassen. Variante b: nur 1 Frame (≈167 ms) stehen lassen und die Abdunklung sofort beim Drop entfernen, damit es nicht „hängt“. |
| **B2** | Mittel | B-4 | Die Drop-Frames zeigen einen leeren 220×220-Platzhalter statt des Bildes, solange Dekodieren bzw. Promise nicht fertig sind. Beim Screenshot-Thumbnail (Promise) ist das wahrscheinlich der Normalfall, dann sieht der Nutzer nie „sein“ Bild landen. | Bei fileURL und Bilddaten synchron dekodieren (oder ein Vorschaubild aus `NSDraggingItem`/`draggingImage` nehmen), bevor die Drop-Sequenz startet. Bei Promises das Drag-Image als vorläufigen Inhalt nutzen. Auf dem Mac messen: Zeit von performDrop bis `setImage`. |
| **B3** | Mittel | V-1 | Das Board ist bildschirmfüllend und nimmt überall Drops an. „Maus verlässt Board“ ist mit einem Monitor nicht erreichbar, und jedes Loslassen nach einem versehentlichen Expand legt das Bild ab. Abbrechen geht nur per Esc. | Eine Abbruchzone festlegen (z. B. Cursor zurück aufs Eselsohr, Menüleistenstreifen oder Bildschirmrand gilt als „verlassen“ → `collapse` und Drop ablehnen) oder das Board nicht bis über die Menüleiste ziehen. Verhalten mit dem Product Owner klären. |
| **B4** | Niedrig | V-2 | Esc während eines Drags wird nur indirekt erkannt. Bis das Zuklappen beginnt, können bis zu 300 ms (`exitInsideGrace`) vergehen; dazu kommen 200 ms Animation. | Auf dem Mac loggen, ob `draggingEnded` zuverlässig sofort kommt. Wenn ja, `exitInsideGrace` senken (z. B. 100 ms) bzw. bei `draggingEnded` sofort zuklappen (passiert schon). |
| **B5** | Niedrig | A-6 | Export (PNG/PDF/Ordner) fehlt komplett. Die Interaktionstabelle nennt „exportieren“, der Prototyp-Umfang verschiebt Export aber ausdrücklich nach hinten. | Für den Prototyp okay. In der Doku „Export: später“ festhalten; keine Fix-Gruppe in Phase 4 nötig. |
| **B6** | Niedrig | M-3 | Drop-Frame 0 hat schon einen Schatten. Laut Briefing kommt der Schatten erst im finalen Frame („final mit Schatten und Kipp“). | `shadowOpacity` als Keyframe-Spur mitführen (Frame 0 = 0, Frame 1 = `PaperStyle.shadowOpacity`), z. B. über ein Feld in `Pose` oder eine eigene Keyframe-Animation in `StopMotion.apply`. |
| **B7** | Niedrig | M-6 | Der Jitter wird in pt gerechnet (0,5–1 pt = 1–2 Device-px auf Retina). Im Ansichtsmodus verschiebt der ±0,3°-Rotations-Jitter der bildschirmgroßen Maske die ferne Papierkante um mehrere pt; das ist mehr als „minimal“. | Klären, ob „px“ pt meint. Für die Blatt-Maske den Rotations-Jitter abschalten oder auf ≈0,03° begrenzen und nur Positions-Jitter nutzen. |
| **B8** | Niedrig | S-4 | Herkunfts-URL bei Browser-Bildern wird nicht gespeichert; Bild-URLs werden nicht importiert. | Beim Weg imageData zusätzlich `pb.string(forType: .URL)` bzw. `public.url` in `ItemSource` speichern (z. B. ein neues Feld `originalURL`). Laut Briefing ist das ein Feature nach dem Prototyp. |
| **B9** | Niedrig | X-2 | Die Einrückung des Eselsohrs ist nicht einstellbar. | Untermenü „Abstand“ (z. B. 8/12/24 pt) in `Settings`. |
| **B10** | Niedrig | X-4 | Die Overlay-Deckkraft ist nicht einstellbar. | `dimOpacity` in `Settings` übernehmen, Menü mit 3–4 Stufen. |
| **B11** | Niedrig | X-5 | Der Ausblenden-Hotkey ist fest (⌃⌥⌘E), es gibt keinen Recorder. | Für den Prototyp-Schritt 8 vertretbar; Recorder später. |
| **B12** | Mittel | K-2 | Das Eselsohr landet auf dem Bildschirm, unter dem beim Start die Maus lag. Das ist nicht deterministisch, nicht der Hauptbildschirm, und es gibt keine Option „pro Bildschirm“. | Standard: `NSScreen.screens.first` (Hauptbildschirm mit Menüleiste) statt Maus-Bildschirm. Später eine Einstellung „Eselsohr: Hauptbildschirm / jeder Bildschirm“ mit je einem Eselsohr-Panel und Board pro Bildschirm. |
| **B13** | Niedrig | E-10 | Die Eselsohr-Lasche ist dunkler und kühler als das Board (Papier-Rückseite) statt „gleiches Papier“. | Gestalterisch begründbar. Mit dem Product Owner abnehmen lassen oder die Farbe auf `paperHex` setzen und die Rückseite nur über Falzband und Haarstrich andeuten. |

---

## Abweichungen, die bewusst wirken

Diese Punkte weichen vom Wortlaut des Briefings ab, sind im Code aber als Konstante oder Kommentar ausdrücklich begründet. Sie sind deshalb wahrscheinlich gewollt und brauchen eine Abnahme, nicht unbedingt einen Fix.

1. **Drop-Close nach 333 ms statt „sofort“ (B1):** `DropboardConfig.dropCloseDelay` mit Kommentar „E8: Board bleibt für die 2 Drop-Frames sichtbar“, `DropboardConfig.swift:18-20`; Reduce Motion → 0 ms. Löst den Widerspruch im Briefing zwischen Interaktionstabelle und Motion-Tabelle.
2. **Nach dem Drop kein Realtime-Zuklappen, sondern hartes `orderOut`:** `closeAfterDrop`, Kommentar „ohne Realtime-Animation ausblenden“, `DragCoordinator.swift:402-411`. Passt dazu, dass Realtime laut Briefing nur für „Zuklappen ohne Drop“ gilt.
3. **Eselsohr als Papier-Rückseite (B13):** `PaperStyle.swift:25-27` dokumentiert v1 → v2 mit Begründung („wirkte wie flaches Dreieck“).
4. **Rotations-Jitter der Blatt-Maske im Ansichtsmodus (Teil von B7):** Kommentar „gewollt: Papier zittert“, `ViewMotion.swift:29-30`.
5. **Fester Hotkey ⌃⌥⌘E (B11):** Kommentar „im Prototyp fest, kein Recorder“ mit Kollisionsbegründung (⌥⌘D = Dock), `HotKey.swift:6-9`.
6. **Ausblenden nicht gespeichert:** `Settings.swift:13` („nach jedem Neustart wieder sichtbar, sonst vergisst man es“).
7. **Löschen verschiebt nach `trash/` statt hart zu löschen:** `BoardEditing.swift:91-93`; kein Undo, `BoardController.swift:181`.
8. **Ansichtsmodus ohne Abdunklung:** `BoardPresenter.swift:198`. Das Briefing nennt Abdunklung nur „während des Drags“.
9. **Ziehen im Ansichtsmodus folgt der Maus direkt, ohne Stop-Motion:** `ViewModeController.swift:14-17`. Das ist eine Auslegung von „Jitter nie während eines Drags“ gegenüber „alles im Ansichtsmodus stepped“; nach dem Loslassen ist es wieder stepped.
10. **Verzögerung nur aus festen Stufen (150/300/500/800 ms):** `EarPlacement.swift:45-54`; ungültige Werte fallen auf 300 ms zurück.
11. **Web-URLs nur geloggt, kein Download:** `ImageImporter.swift:26,91-93`, entspricht „Priorität im Prototyp: Bilder“.
12. **Jitter nur auf Zwischenframes, der Endframe ist exakt:** `Planner.swift:84-86`. Das Briefing erlaubt Jitter („darf“), verlangt ihn aber nicht auf jedem Frame.
13. **Umsortieren würfelt die Rotation neu:** `BoardController.swift:166-171`, analog zu „beim Ablegen minimale Zufallsrotation“.
14. **Ablage begrenzt auf `visibleFrame` minus 48 pt Rand:** `LayoutMetrics.standard`, `BoardLayout.swift:32-34`, `DropboardConfig.swift:64-68`. Drops am Rand landen deshalb leicht eingerückt neben dem Cursor.
15. **Handoff-Variante two-panels als Standard, grow als Alternative:** `DropboardConfig.swift:4-13` (Risiko T4 im Code offen benannt).
16. **Export, Overlay-Deckkraft, Einrückung, Multi-Monitor-Option fehlen (B5, B9, B10, B12):** Laut Briefing stehen sie unter „Features nach dem Prototyp“; der Prototyp-Schritt 8 nennt nur Ecke, Verzögerung und Ausblenden-Hotkey. Ausnahme bei B12: Die Wahl des Maus-Bildschirms statt des Hauptbildschirms wirkt **nicht** bewusst.

## Auf dem Mac gezielt prüfen (❓-Punkte)

E-4 Sichtbarkeit über Fullscreen-Spaces · E-5 gedämpft · E-11 Trefferfläche der transparenten Eselsohr-Hälfte · D-6/B-5 Fokus bleibt bei der Ursprungs-App (`[FOCUS]`-Log) · D-7 Handoff Eselsohr → Board ohne Mausbewegung (`[HANDOFF]`-Log) · D-9 Bildrate des Masken-Reveals · A-4 `mouseDragged`/`mouseUp` auf dem nicht aktivierenden Panel · A-7 Esc nach `makeKey()` · A-10 Key-Fenster nach dem Schließen · L-2 Noise-Sichtbarkeit bei 100 % · S-3 `source.app` beim Screenshot-Thumbnail.
