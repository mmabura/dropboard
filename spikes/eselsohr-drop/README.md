# Spike: Eselsohr-Panel mit Drop-Test

Messinstrument für Phase 1, kein Produkt. Ein 40×40-pt-Eselsohr oben rechts (nicht aktivierendes `NSPanel`, Konfiguration nach Report 02) nimmt Drags an. Der Spike loggt Pasteboard-Typen, Quick-Drop, die Übergabe der Drag-Session an das Board (Risiko T4), den Fokus und den Fensterzustand.

Grundlage: `docs/phase0/01-drag-drop-screenshot-thumbnail.md`, `docs/phase0/02-window-level-fullscreen.md`, `docs/entscheidungen.md` (E4 ohne Sandbox, E9 SwiftPM, E10 300 ms).

**Status: nicht kompiliert.** Der Code ist im Linux-Container entstanden. Unsichere API-Annahmen sind im Code mit `⚠️ VERIFIZIEREN` markiert.

## Build und Start

```sh
cd spikes/eselsohr-drop
swift build -c debug
swift run eselsohr-drop -- --handoff two-panels    # Variante A (Default): zweites Board-Panel
swift run eselsohr-drop -- --handoff grow          # Variante B: Eselsohr-Panel wächst per setFrame
swift run eselsohr-drop -- --reject-drops          # performDragOperation gibt false zurück (Report 01, T4b)
```

Falls `swift run` das `--` durchreicht: Der Spike ignoriert es. Alternativ direkt `.build/debug/eselsohr-drop --handoff grow` starten.

Beenden: Ctrl-C im Terminal. Esc beendet nur, wenn ein Panel key ist (nach einem Klick aufs Eselsohr).

## Ausgaben

- Log: stdout und angehängt an `~/Library/Logs/DropboardSpike/eselsohr-drop.log`. Eine Zeile pro Ereignis mit ISO-Zeitstempel inkl. ms.
- Präfixe: `[PB]` Pasteboard, `[DROP]` Annahme/Sicherung, `[HANDOFF]` Expand/Drag-Übergang, `[FOCUS]` Fokus, `[WIN]` Fenster/Spaces.
- Gesicherte Drops: `~/Library/Application Support/DropboardSpike/Incoming/<uuid>/`.
- Reihenfolge der Sicherung (Report 01, Abschnitt 5): File-Promise (asynchron) → fileURL (synchron kopiert) → Bilddaten als PNG → Web-URL (nur geloggt).
- Lebensdauer der Quell-fileURL: `[DROP] Quelle t=0 / concludeDragOperation / +100ms / +1000ms / +2000ms / +5000ms exists=…`.

## Testprotokoll

Je Schritt notieren: wer, Datum, macOS-Version (steht in der ersten `[WIN] Start`-Zeile), Ergebnis (ja/nein/Beobachtung), relevante Logzeilen. Die „erwarteten“ Logzeilen sind Hypothesen aus den Reports, keine belegten Ergebnisse. Abweichungen sind das, was wir suchen.

Vorher: Speicherort für Screenshots auf „Schreibtisch“ stellen (⌘⇧5 → Optionen) und das schwebende Thumbnail aktivieren.

### A. Start, Fenster, Spaces (Report 02 T1/T2, Report 01 T5)

1. **Start** mit `--handoff two-panels` im Terminal.
   Erwartet: `[WIN] Start … activationPolicy=1`, `[WIN] Level-Referenz … statusBar=25 popUpMenu=101 screenSaver=1000 cgDraggingWindow=500`, `[WIN] Start ear … level=25 behavior=0x… onActiveSpace=true visible=true`, `[WIN] Start board … visible=false`, `[FOCUS] Start frontmost=<Terminal> NSApp.isActive=false`. Prüfen: Eselsohr ist sichtbar, kein Dock-Icon, ca. 12 pt vom rechten Rand, knapp unter der Menüleiste.
2. **Space-Wechsel**: Mit Ctrl-→ bzw. Wischen auf einen zweiten Schreibtisch wechseln und zurück, dann Mission Control öffnen.
   Erwartet: `[WIN] activeSpaceDidChange`, `[WIN] Space-Wechsel ear … onActiveSpace=true visible=true`, dazu die Zeile `+500ms`. Prüfen: Das Eselsohr wandert nicht mit, ist auf jedem Space da, erscheint nicht in ⌘-Tab.
3. **Vollbild-App (E6)**: Safari per grünem Button ins native Vollbild, dann in diesen Space wechseln.
   Erwartet: `[WIN] Space-Wechsel ear … onActiveSpace=true visible=true`. Prüfen: Das Eselsohr ist über der Vollbild-App sichtbar. `visibleFrame` notieren. Falls vorhanden, DaVinci Resolve im Vollbild genauso prüfen.
4. **Klick aufs Eselsohr** (ohne Drag).
   Erwartet: `[WIN] Klick auf ear ohne Drag → Ansichtsmodus würde öffnen`, `[FOCUS] nach Klick … NSApp.isActive=false earKey=true`. Danach Esc drücken: `[WIN] Esc – Spike beendet`. Neu starten. Auf `[FOCUS] App aktiviert: … !!! SPIKE SELBST AKTIVIERT` achten: Das wäre ein Befund.

### B. Quick-Drop: Drop direkt aufs Eselsohr, schneller als 300 ms (Report 01 T0–T3, T5)

Für jede Quelle: Ziehen, direkt aufs Eselsohr, sofort loslassen.

5. **Finder-Datei** (PNG, dann JPEG und HEIC).
   Erwartet: `[HANDOFF] neue Drag-Session`, `[PB] draggingEntered win=ear … draggingSource=nil (fremder Prozess) sourceOpMask=0x… types=[…]`, je Typ eine Zeile `[PB]   item0 public.file-url: … exists=true size=…B`, `[DROP] performDragOperation win=ear art=Quick-Drop`, `[DROP] Weg=fileURL kopiert in …ms`, `[FOCUS] nach Drop frontmost=com.apple.finder NSApp.isActive=false`, `[FOCUS] 500ms nach Drop …`. Prüfen: Datei liegt in `Incoming/<uuid>/`.
6. **Screenshot-Thumbnail**: ⌘⇧4 und einen Bereich wählen, dann das Thumbnail unten rechts sofort aufs Eselsohr ziehen. Wiederholen mit ⌘⇧3 und ⌘⇧5.
   Erwartet laut Report 01: Promise-Typen (`(Promise-Typ, Inhalt nicht gelesen)`), `promise0 fileNames=[…]`, `item… public.file-url: …/TemporaryItems/NSIRD_screencaptureui_…`, `[DROP] Weg=File-Promise`, `[DROP] Promise0 vollständig nach …ms | … size=…B` oder `Promise0 FEHLER`. Dazu die Zeilen `Quelle +100ms … +5000ms exists=…` (ab wann `false`?). Prüfen: Liegt der Screenshot zusätzlich auf dem Schreibtisch (Report 01 T4a)? Kommen Bilddaten-Typen (`public.png`/`public.tiff`) vor (V1)?
7. **Schicksal des Screenshots bei abgelehntem Drop** (Report 01 T4b/c): Spike mit `--reject-drops` starten, Thumbnail aufs Eselsohr ziehen.
   Erwartet: `[DROP] --reject-drops aktiv …`, `performDragOperation Rückgabe=false`. Prüfen: Springt das Thumbnail zurück? Liegt der Screenshot danach auf dem Schreibtisch? Gegenprobe: Screenshot machen, Thumbnail nicht anfassen.
8. **Safari-Bild** (Bild von einer Webseite ziehen).
   Erwartet: `[PB]`-Typenliste (V14), `[DROP] Weg=File-Promise`, danach `Promise0 vollständig …` mit Dateinamen.
9. **Chrome-Bild**.
   Erwartet: Typen wie `com.apple.pasteboard.promised-file-url`, `public.url`, Bild-UTI. Prüfen: Greift `Weg=File-Promise` (V13) oder der Fallback `Weg=Bilddaten …` bzw. `Weg=Web-URL nur geloggt`?
10. **Fokus beim Quick-Drop** (Report 01 T5, Report 02 T5): TextEdit öffnen, Cursor in ein Dokument setzen, ⌘⇧4, Thumbnail aufs Eselsohr ziehen, danach sofort weitertippen.
    Erwartet: `[FOCUS] nach Drop frontmost=com.apple.TextEdit NSApp.isActive=false earKey=false`, kein `[FOCUS] App aktiviert`. Prüfen: Die Menüleiste gehört weiter TextEdit, der Text landet in TextEdit. Dasselbe in Safari im Vollbild (Schritt 3), mit einem Safari-Bild als Quelle. Prüfen: kein Space-Sprung.

### C. Expand und Übergabe an das Board (Report 02 T4, Report 01 T6)

Den Drag aufs Eselsohr führen und dort **mindestens 300 ms still halten**. Dann zuerst **ohne Mausbewegung** 1–2 s warten und erst danach bewegen.

11. **two-panels, Finder-Datei**, Drop mitten auf dem Board.
    Erwartet: `[FOCUS] vor Expand`, `[HANDOFF] Expand ausgelöst mode=two-panels … dauer(orderFront/setFrame)=…ms`, `[WIN] nach Expand board … visible=true level=25`. Kernfrage: Kommt `[HANDOFF] draggingEntered win=board +…ms nach Expand mausBewegtSeitExpand=false`, also ohne Mausbewegung? Oder erst nach `[HANDOFF] erste Mausbewegung nach Expand`? Oder `WARNUNG: 1000ms nach Expand kein Drag-Ereignis auf dem Board`? Ebenso notieren: `draggingExited win=ear …`. Beim Drop: `[DROP] performDragOperation win=board art=Board-Drop dropPos=(x,y) cursor=(x,y)`, `[HANDOFF] Board geschlossen grund=nach Drop`, `[FOCUS] nach Drop`, `[FOCUS] 500ms nach Drop`. Prüfen: Zeigt der Cursor das Kopieren-Badge?
12. **two-panels, Screenshot-Thumbnail** als Quelle. Wie Schritt 11, zusätzlich `Weg=File-Promise` und `Promise0 vollständig` nach dem Schließen des Boards.
13. **two-panels, Safari-Bild und Chrome-Bild** als Quelle. Wie Schritt 11.
14. **Abbruch ohne Drop (two-panels)**:
    a) Expand auslösen, dann Esc drücken, während die Maustaste noch gedrückt ist.
    Erwartet: `draggingExited win=board`, dann `Cursor noch im Board-Frame …` oder `draggingEnded … dropEmpfangen=false`, `Board geschlossen grund=…`.
    b) Expand auslösen, Drag auf einen zweiten Monitor ziehen (falls vorhanden).
    Erwartet: `Board geschlossen grund=Maus hat Board verlassen`.
    c) Kurz übers Eselsohr ziehen (unter 300 ms) und weiterziehen.
    Erwartet: `draggingExited win=ear vor Expand → Expand abgebrochen`, kein Expand.
    d) Expand auslösen, Thumbnail-Drag wieder zur Ecke unten rechts zurückziehen und dort loslassen.
    Erwartet: Das ist ein Drop aufs Board (es deckt den ganzen Bildschirm ab), oder bei Verlust des Ziels `Maustaste losgelassen (Polling)` → `Board geschlossen grund=Maustaste losgelassen, kein Drop …`.
15. **grow**: Spike mit `--handoff grow` neu starten und die Schritte 11, 12 und 14a wiederholen.
    Erwartet: `Expand ausgelöst mode=grow`, danach `draggingUpdated (erstes nach Expand) win=ear(grown) … mausBewegtSeitExpand=…`. Prüfen: Kommen Updates auch, wenn der Cursor in die neu gewachsene Fläche (Bildschirmmitte) wandert? Gibt es direkt nach Expand ein `draggingExited win=ear(grown)`? Drop in der Bildschirmmitte: `performDragOperation win=ear(grown) art=Board-Drop`. Danach `Board geschlossen`, und das Eselsohr ist wieder 40×40.
16. **Vollbild + Expand**: Schritt 11 und 15 in Safari im Vollbild wiederholen, mit einem Safari-Bild als Quelle.
    Erwartet: `[WIN] nach Expand board … onActiveSpace=true visible=true`, `[FOCUS] nach Drop frontmost=com.apple.Safari`, kein Space-Sprung, die Menüleiste bleibt Safari. Falls vorhanden, mit DaVinci Resolve wiederholen.

### Nicht abgedeckt

- Report 02 T2 als volle Matrix (Level, Klasse, Policy, Behavior): Der Spike hat nur die empfohlene Konfiguration, keine Schalter.
- Report 01 T3 Teil 2 (`receivePromisedFiles` außerhalb von `performDragOperation`, Namenskollisionen), T7 (Sandbox), T8 (TCC-Reset).
- Report 02 T6–T10 (Notch/Monitore, Stage Manager, System-UI, Screenshots, TCC).
- Animation und Stop-Motion: bewusst nicht enthalten.
