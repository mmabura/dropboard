# Phase 3 – Review Performance

Stand: 7. Okt. 2026 · Grundlage: `docs/briefing.md` und der Code unter `app/Sources/`, keine anderen Dokumente. Nur statische Analyse (Linux); die Zahlen in „Auswirkung“ sind grobe Schätzungen und müssen mit dem Messplan auf dem Mac mini bestätigt werden. Es wurde kein Code geändert.

Ziele aus dem Auftrag: Im Idle (Eselsohr sichtbar, kein Drag) praktisch 0 % CPU und keine periodischen Wakeups. Das Aufklappen startet weniger als 16 ms nach Ende der Verzögerung. Kein blockierendes I/O auf dem Main-Thread im Drop-Pfad.

## Kurzfazit

- **Idle ist statisch sauber.** Im Idle läuft kein wiederholender Timer, kein DisplayLink, keine Endlos-Animation und kein Polling. Der Watchdog-Timer (50 Hz) läuft nur in der Phase `expanded` (`DragCoordinator.swift:415-426`). Was im Idle bleibt, sind ereignisgetriebene Wakeups durch System-Notifications, und die schreiben jedes Mal eine Logzeile (P7).
- **Die größten Risiken liegen im Drag- und Drop-Pfad.** Das Diagnose-Logging liest den kompletten Inhalt des Drag-Pasteboards synchron, schon in `draggingEntered` (P1). Dazu kommt die PNG-Konvertierung von Bilddaten auf dem Main-Thread in `performDragOperation` (P2).
- **Das Speicherkonzept ist grundsätzlich gut.** Bilder werden auf Anzeigegröße × Backing-Scale gerendert und nicht in voller Auflösung gehalten. Der Dekodier-Weg dorthin ist aber teuer, und beim Start läuft er ohne Begrenzung parallel (P4).
- **Die Expand-Latenz lässt sich aus den vorhandenen Logs nur bis zum Beginn des Commits bestimmen.** Den ersten sichtbaren Frame loggt die App nicht (P6). Wo eine Logzeile ergänzt werden müsste, steht in P6.

## Befundtabelle

| ID | Schwere | Datei:Zeile | Befund | Auswirkung (grobe Größenordnung) | Vorschlag |
|---|---|---|---|---|---|
| P1 | Hoch | `ImageImporter.swift:241-257`, `:268`; Aufrufe `DragCoordinator.swift:203`, `:291`, `:346` | `dumpPasteboard` läuft bei jeder neuen Drag-Session in `draggingEntered` und noch einmal in `performDragOperation`. Die Funktion ruft für **jedes Item und jeden Typ** `item.data(forType:)` auf; nur Promise-Typen und `public.file-url` sind ausgenommen. Bei Browser-Drags (`public.tiff`, `public.png`, Webarchive) holt das den kompletten Bildinhalt synchron per IPC aus der Quell-App. Danach folgt eine Logzeile pro Typ. | Drags aus dem Finder: < 1–3 ms. Browser-Bild oder Screenshot mit TIFF/PNG-Daten: 4K-TIFF ≈ 33 MB, also **≈ 20–200 ms Main-Thread-Block**. Die Zeit liegt **vor** dem Start der Expand-Verzögerung (`scheduleExpand` erst in `:211`) und vor jeder Drop-Verarbeitung. Der Nutzer erlebt sie direkt als Verzögerung, und `draggingEntered` antwortet später. | In `draggingEntered` nur Typnamen loggen, keine Daten (`pb.types`). Bei Bildtypen höchstens die Größe aus `pasteboardItems` loggen, ohne `data(forType:)`. Den Daten-Dump ganz hinter ein Debug-Flag legen. In `performDragOperation` werden die Daten ohnehin in `writeImageData` gelesen; dort genügt ein Log mit `data.count`. |
| P2 | Hoch | `ImageImporter.swift:189-213`, besonders `:193` und `:202`; Aufruf `ImageImporter.swift:89` ← `DragCoordinator.swift:294` | Weg „Bilddaten“: TIFF, JPEG und HEIC werden mit `NSBitmapImageRep(data:)` **dekodiert und als PNG neu kodiert**, synchron auf dem Main-Thread in `performDragOperation`. Danach wird die Datei atomisch geschrieben. Erst dann legt `place()` den Platzhalter an (`DragCoordinator.swift:304`/`:310`). | 4K-TIFF/JPEG → PNG: **≈ 100–400 ms Block**. In dieser Zeit erscheint kein Platzhalter, der Stop-Motion-Drop startet später, und das Board schließt später (`perform(... afterDelay:)` in `:308` wird erst danach eingeplant). Aus JPEG/HEIC entsteht nebenbei eine 3–10× größere PNG-Datei. | Im Main-Thread nur `pb.data(forType:)` lesen (nötig, solange die Drag-Session lebt). Die Rohdaten unverändert mit passender Endung (`.tiff`/`.jpg`/`.heic`) auf einer Hintergrund-Queue schreiben. Den Platzhalter sofort anlegen, dekodieren wie bei `decode()`. Den PNG-Zwang aufgeben, denn ImageIO liest alle Formate. |
| P3 | Mittel | `ImageImporter.swift:161-186`, besonders `:175` | Weg „fileURL“: `FileManager.copyItem` läuft synchron in `performDragOperation`. Die Begründung im Code steht in `:160` (Temp-Datei des Thumbnails lebt nur kurz). | Auf demselben APFS-Volume ist die Kopie ein Clone, **< 1 ms**. Von einem externen Volume, einem Netzlaufwerk oder einer iCloud-Datei, die noch nicht lokal ist: **10 ms bis Sekunden** Block, danach erst der Platzhalter. | Synchron nur das Nötigste: Bei Pfaden unter `TemporaryItems`/`/var/folders` sofort clonen (`copyItem` auf demselben Volume ist ein Clone). Alles andere auf eine Hintergrund-Queue verlegen, mit Platzhalter wie beim Promise-Weg. Oder zuerst `clonefile` versuchen und bei Fehlschlag asynchron kopieren. |
| P4 | Mittel | `ImageDecoder.swift:21-43` (`:23`, `:40`), `:51`; Start: `BoardController.swift:57-77` (`:69`) | (a) Dekodiert wird mit `CGImageSourceCreateImageAtIndex` plus `ctx.draw` in voller Quellauflösung. Erst danach wird auf ca. 440 px herunterskaliert, statt die Thumbnail-API mit `kCGImageSourceThumbnailMaxPixelSize` zu nutzen. (b) Beim Start schickt `loadFromDisk` **für jedes Item sofort einen Block** auf `DispatchQueue.global(qos: .userInitiated)`. Die Parallelität ist nicht begrenzt, und jedes Ergebnis wird einzeln per `Task { @MainActor }` committet. | Pro 4K-Quelle ≈ 33 MB temporär (3840×2160×4) und ≈ 50–150 ms CPU. Beim Start mit 20 Bildern laufen bis zu ~10 parallel: **Spitze ≈ 300+ MB Footprint**, mehrere Hundert ms Volllast auf allen Kernen und viele Threads. Ein Drag direkt nach dem Login konkurriert damit um die CPU. Nebenbei wird die EXIF-Orientierung nicht beachtet (`:20`). | `CGImageSourceCreateThumbnailAtIndex` mit `kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceThumbnailMaxPixelSize = longestEdge × scale` und `kCGImageSourceCreateThumbnailWithTransform` (behebt auch EXIF). Eine eigene `OperationQueue` mit `maxConcurrentOperationCount = 2…3` und `.utility` für das Laden beim Start. Ergebnisse gebündelt setzen, zum Beispiel alle 100 ms ein Commit. |
| P5 | Mittel | `Motion.swift:60-79` (reveal), `:85-100` (collapse), `:108-119` (Maske); Aufruf `BoardPresenter.swift:124`, `:132`, `:148` | Aufblättern und Zuklappen nutzen eine **Maske über das ganze Papier** (`content.mask`, Bildschirmgröße). Der Code weiß, dass das einen Offscreen-Pass kostet (`:71`), und entfernt die Maske nach 250 ms (`:74-77`). Beim Zuklappen bleibt sie bis zum `orderOut`. Jeder Frame rendert das ganze Blatt (Papier, Noise-Textur, Abdunklung, alle Bilder mit Schatten) offscreen in voller Backing-Auflösung. | 4K @2x: Offscreen-Target ≈ 3840×2160×4 ≈ **33 MB**, 12–24 Frames pro Aufklappen (60/120 Hz). Der erste Frame muss das Target anlegen, deshalb sind **+1–5 ms bis zum ersten Frame** und GPU-Last im WindowServer möglich. Auf dem M4 wohl kein Ruckeln, aber unnötig. | Das Rechteck wächst achsenparallel aus der Ecke. Das geht ohne Maske: das Blatt in einen Container-Layer mit `masksToBounds = true` hängen, dessen `bounds`/`position` vom Anker aus animieren und das Blatt per Gegen-`position` stehen lassen. Rechteckiges Clipping per Scissor braucht keinen Offscreen-Pass. Die Stop-Motion-Maske im Ansichtsmodus (`ViewMotion.swift:28-39`, gedreht) darf bleiben. |
| P6 | Mittel | `DragCoordinator.swift:365-384` (`:367`, `:376-382`); `Diagnostics.swift:12-30` | **Messlücke und Logging vor dem Commit.** Das Log hört bei `dauer(orderFront/setFrame)` auf, also beim synchronen Teil. Den CA-Commit und den ersten sichtbaren Frame loggt die App nicht. Außerdem laufen in `expandFired` **vor** dem impliziten Commit (der erst am Ende des Run-Loop-Durchlaufs passiert) `logFocus` (NSWorkspace-Abfrage), drei bis vier `Log.line` mit Datei- und stdout-Schreibzugriffen und `logWindows` (pro Panel `isOnActiveSpace` und `screen`, also WindowServer-Abfragen). | Geschätzt **0,5–3 ms** zusätzlich vor dem ersten Frame. Ohne Log-Punkt lässt sich das Ziel „< 16 ms nach Verzögerungsende“ nur als Untergrenze messen. | **Logzeilen ergänzen (Befund, nicht selbst geändert):** (1) In `DragCoordinator.swift` direkt nach `presenter.openForDrag(...)` (`:377`): `CATransaction.flush()` und dann `Log.line("[HANDOFF]", "Expand commit +\(Log.ms(since: expandAt))ms")`. (2) In `Motion.swift:72` der Reveal-Animation einen `CAAnimationDelegate` geben und in `animationDidStart` `Log.line("[MOTION]", "reveal gestartet +…ms")` loggen. (3) `logFocus("vor Expand")` und `logWindows("nach Expand")` per `afterDelay(0)` nach den Commit verschieben. Für den Start zusätzlich in `BoardController.swift:69-76` einen Zähler mitführen und die Zeile `[STORE] alle Bilder dekodiert n=… in …ms` loggen. |
| P7 | Niedrig | `Log.swift:41-48`, `:21-31`; Idle-Auslöser `AppController.swift:95-106`, `Motion.swift:36-46` | `Log.line` schreibt **synchron** auf stdout und in die Datei, mit Lock und `ISO8601DateFormatter`, auf dem Main-Thread. Das passiert in allen heißen Pfaden: pro Drag 15–40 Zeilen, dazu FileProbe-`stat`s. Im Idle schreibt jeder App-Wechsel des Nutzers (`didActivateApplication`) eine Zeile, jeder Space-Wechsel vier Zeilen samt WindowServer-Abfragen. Die Logdatei wird nie rotiert. | Pro Zeile ≈ 20–100 µs, pro Drag ≈ 1–4 ms. Im Idle **keine periodischen** Wakeups, aber bei jedem App- und Space-Wechsel ein Wakeup mit Datei-I/O. Die Logdatei wächst unbegrenzt (MB pro Woche bei intensiver Nutzung). | Für Release-Builds `os_log`/`Logger` verwenden: asynchron, mit Rate-Limit und vom System rotiert. Datei-Log und Fokus- und Space-Beobachter nur hinter einem Debug-Flag. Mindestens rotieren, zum Beispiel ab 5 MB. |
| P8 | Niedrig | `DragCoordinator.swift:415-421`, `:428-459` (`:442`); `DropboardConfig.swift:32` | Der Watchdog-Timer läuft mit 20 ms (50 Hz) ohne `tolerance` und ruft pro Tick `NSEvent.pressedMouseButtons`/`mouseLocation` ab. Es gibt keine Höchstlaufzeit: Wenn `dropReceived == true` ist, ohne dass `performDragOperation` ankommt (`prepareForDragOperation` ohne folgendes `perform`, `:263`), bleibt die Phase `expanded` und der Timer läuft dauerhaft (`:442` kehrt nur zurück). | Normalfall: nur während des offenen Boards, < 0,5 % CPU. Im Randfall dauerhaft **50 Wakeups/s** und ein offenes Board. | `timer.tolerance = 0.005` setzen. Eine harte Obergrenze einführen, zum Beispiel nach 3 s mit `dropReceived` und ohne `performDragOperation` zuklappen und `stopPolling()`. Der Messplan (Schritt 11) prüft, ob die App nach Interaktion zum Idle-Wert zurückkehrt. |
| P9 | Niedrig | `Log.swift:77-87`; Aufruf `ImageImporter.swift:80` | `FileProbe.scheduleLifetimeChecks` plant nach jedem Drop vier verzögerte Blöcke ein (0,1 / 1 / 2 / 5 s), jeder mit `stat` und Logzeile. Das ist ein Diagnose-Rest aus dem Spike. | 4 Wakeups über 5 s nach jedem Drop, vernachlässigbare CPU. Verfälscht aber Idle-Messungen direkt nach einem Drop. | Entfernen oder hinter ein Debug-Flag legen. |
| P10 | Niedrig | `BoardController.swift:233-241`; `BoardStore.swift:69-72`, `:82-87`; Aufrufe `:141`, `:177`, `:203` | `save()` kodiert bei jedem Import, Umsortieren und Löschen das **ganze Dokument** als JSON mit `.prettyPrinted` und `.sortedKeys` und schreibt es atomisch, synchron auf dem Main-Thread. Bei Promise-Drops mit mehreren Dateien wird pro Datei gespeichert. | 100 Items ≈ 40 KB: ≈ 1–3 ms. 1000 Items: ≈ 10–30 ms Block. Im Prototyp unkritisch. | Kodieren auf dem Main-Thread (ein Snapshot des Werts), Schreiben auf einer seriellen Hintergrund-Queue, zusammengefasst (Debounce ~200 ms). `.prettyPrinted` nur im Debug-Build. |
| P11 | Niedrig | `AppController.swift:44-70` (`:66-67`, `:127`); `BoardScene.swift:62-65`; `PaperArt.swift:16-25`; `StatusMenu.swift:156`, `:183-185`; `BoardController.swift:64-67` | Startpfad, alles synchron vor dem Erscheinen des Eselsohrs: Die Noise-Textur wird einmal auf volle Bildschirm-Pixelgröße gekachelt (3840×2160). Das Board-Panel in Bildschirmgröße wird angelegt (`defer: false`). `loadFromDisk` (JSON plus ein eigener CA-Commit pro Platzhalter) läuft **vor** `showEar()`. `SMAppService.mainApp.status` (XPC) wird zweimal gerufen, in der .app bei jedem Öffnen des Menüs erneut. | Noise-Kachelung ≈ 5–20 ms, SMAppService ≈ 5–50 ms je Aufruf, N Platzhalter-Commits ≈ N × 0,05 ms. Das Eselsohr erscheint geschätzt 50–150 ms später als nötig. Einmalig, unkritisch. | `presenter.showEar()` vor `loadFromDisk()` ziehen. Platzhalter in einer gemeinsamen `StopMotion.batch`-Transaktion anlegen. Den Login-Status nur einmal abfragen und an `StatusMenuController` weitergeben. Die Noise-Kachel als `CALayer.contents` mit `contentsGravity`/Pattern-Farbe statt als vorgerendertes Vollbild-Bitmap verwenden (spart auch ≈ 8–15 MB). |
| P12 | Niedrig | `BoardPresenter.swift:126-134` (`:133`), `:161-170` (`:162`) | Nur bei Handoff `grow` (nicht Standard): Jedes Aufklappen und Zuklappen vergrößert das Eselsohr-Panel per `setFrame(..., display: true)` auf Bildschirmgröße und zurück. Der WindowServer muss die Fensterfläche jedes Mal neu anlegen. | Geschätzt **+2–10 ms** pro Expand gegenüber `two-panels`, bei dem das Board-Panel vorab existiert. | Aus Performance-Sicht bei `two-panels` bleiben (Standard, `DropboardConfig.swift:13`). Falls `grow` gewählt wird, mit Schritt 8 separat messen. |
| P13 | Niedrig | `ImageDecoder.swift:35-37`; `PaperArt.swift:19-21`; `BoardScene.swift:62-65`, `:109`, `:120` | Speicher und Pixelformat. Item-Bitmaps liegen als sRGB RGBA `premultipliedLast` vor, die Noise als `DeviceGray` ohne Alpha in Bildschirmgröße. ⚠️ VERIFIZIEREN: ob Core Animation diese Formate beim Commit konvertiert (`CA::Render::copy_image`/`convert` im `sample`). Alle Item-Bitmaps und die Vollbild-Noise bleiben dauerhaft im Prozess, auch bei geschlossenem Board. Das ist so gewollt, damit das Aufklappen schnell bleibt. | Pro Bild ≈ 0,2–0,8 MB (220 pt @2x), dazu die Kopie im Render-Server. 100 Bilder ≈ 40–80 MB, Noise ≈ 8 MB (4K) bis 15 MB (5K-Skalierung). Für den Prototyp angemessen, **downsampling ist vorhanden**. | Bitmaps in `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little` (BGRA, natives CA-Format) erzeugen. Bei sehr vielen Items erst über ~300 Bilder an Auslagern denken. |
| P14 | Niedrig | `DragCoordinator.swift:356-359`; projektweit kein `ProcessInfo.beginActivity` | Die Expand-Verzögerung läuft über `perform(_:afterDelay:inModes:)`. Während eines Drags gibt es keine Aktivitäts-Assertion (`.userInitiated`/`.latencyCritical`). Die App ist im Hintergrund (`.accessory`, nie aktiv). Timer-Coalescing oder App Nap könnten den Expand-Timer verspäten. | Erwartet 0–2 ms, weil das Eselsohr sichtbar ist und App Nap dann normalerweise nicht greift. Im ungünstigen Fall **10–100+ ms** Verspätung. | Messen (Schritt 7, „Timer-Verspätung“). Liegt sie über 5 ms, in `draggingEntered` eine `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], …)` öffnen und in `idle` wieder beenden. |

**Anzahl:** Hoch 2 · Mittel 4 · Niedrig 8 · gesamt 14.

### Positiv bestätigt (kein Befund)

- Im Idle gibt es keinen wiederholenden Timer, keinen DisplayLink und keine Endlos-Animation. Die Stop-Motion-Animationen laufen als `CAKeyframeAnimation` mit fester Dauer im Render-Server (`Motion.swift:158-185`). Aufräum-Delays sind One-Shots (`Motion.swift:14-20`).
- Das Mausknopf- und Maus-Polling läuft nur in `expanded` und wird in `collapse`, `performDrop`, `endAllImmediately` und `pollTick` beendet (`DragCoordinator.swift:390`, `:301`, `:131`, `:429`).
- Harte Schatten haben einen expliziten `shadowPath` (`BoardScene.swift:172`, `:122`) und damit keinen Offscreen-Schattenpass.
- Das Board-Panel wird bei `two-panels` vorab erzeugt (`BoardPresenter.swift:58-64`). Der Expand kostet nur `orderFrontRegardless` plus Maske.
- Bilder werden auf einer Hintergrund-Queue dekodiert und auf Anzeigegröße × Backing-Scale gerendert, ohne Vollauflösung als Layer-Inhalt (`ImageDecoder.swift:33-42`, `:51`).
- Die Noise-Textur wird nur bei Größen- oder Skalierungswechsel neu gekachelt (`BoardScene.swift:49`, `:62`).
- Das Logging von `draggingUpdated` ist auf eine Zeile pro 250 ms gedrosselt (`DragCoordinator.swift:224`, `DropboardConfig.swift:39`).

---

## Messplan Mac mini

Voraussetzungen: macOS 26.5.1, M4, 4K @2x, nur Command Line Tools. Alle Befehle laufen in `zsh`/`bash`. Gesten macht Max von Hand, sie sind mit **[Max]** markiert. Während der Idle-Messungen darf niemand Maus oder Tastatur benutzen, denn jeder App-Wechsel erzeugt eine Logzeile und einen Wakeup (P7).

Zeitstempel im Log haben das Format `2026-10-07T12:34:56.789+02:00` (ms, lokale Zeitzone). Die Auswertungen unten rechnen mit der Uhrzeit des Tages in ms und gelten deshalb nicht über Mitternacht.

**1. Umgebung und Hilfsfunktionen setzen** (einmal pro Shell)

```sh
mkdir -p /tmp/dbperf
# Binärpfad: .app bevorzugt, sonst SwiftPM-Release-Build
APPB=/Applications/Dropboard.app              # oder: <repo>/app/dist/Dropboard.app
BIN="$APPB/Contents/MacOS/Dropboard"          # ohne .app: <repo>/app/.build/release/Dropboard  (vorher: swift build -c release)
LOG=~/Library/Logs/Dropboard/dropboard.log
now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000'; }
iso2ms() { perl -MTime::Local -ne 'if(/^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)\.(\d{3})/){print timelocal($6,$5,$4,$3,$2-1,$1)*1000+$7,"\n"}'; }
cpu_s() { ps -o time= -p "$1" | perl -ne 's/\s//g; $s=0; $s=$s*60+$_ for split /:/; print "$s\n"'; }
start_db() {  # $@ = Startargumente, setzt PID und L0
  pkill -x Dropboard; sleep 1; touch "$LOG"; L0=$(wc -l < "$LOG"); T0=$(now_ms)
  "$BIN" "$@" >/dev/null 2>&1 &      # über SSH stattdessen: launchctl asuser $(id -u) "$BIN" "$@" >/dev/null 2>&1 &
  until tail -n +$((L0+1)) "$LOG" | grep -q '\[WIN\] Start ear'; do sleep 0.05; done
  PID=$(pgrep -nx Dropboard); echo "PID=$PID"; }
```

**2. Test-Boards erzeugen** (4K-Rauschbild als Worst Case für das Dekodieren, per APFS-Clone vervielfacht)

```sh
python3 - <<'EOF'
import os, zlib, struct
W,H=3840,2160
def ch(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
raw=b''.join(b'\x00'+os.urandom(W*3) for _ in range(H))
open('/tmp/dbperf/src4k.png','wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',W,H,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,1))+ch(b'IEND',b''))
EOF
for N in 0 20 100; do python3 - $N <<'EOF'
import sys, os, json, uuid
n=int(sys.argv[1]); d=f'/tmp/dbperf/board{n}'; os.makedirs(d+'/images',exist_ok=True); items=[]
for i in range(n):
    u=str(uuid.uuid4()).upper(); fn=u+'.png'
    os.system(f'cp -c /tmp/dbperf/src4k.png {d}/images/{fn}')
    items.append({"id":u,"fileName":fn,"center":{"x":150+(i%12)*140,"y":150+(i//12)*100},"rotation":1.5,
                  "size":{"width":220,"height":124},"addedAt":"2026-10-07T10:00:00Z","source":{"route":"perftest"}})
json.dump({"version":1,"items":items},open(d+'/board.json','w'))
EOF
done; ls /tmp/dbperf
```

**3. Startzeit** (je dreimal, Median verwenden)

```sh
for N in 0 20; do for i in 1 2 3; do
  start_db --board-dir /tmp/dbperf/board$N
  TE=$(tail -n +$((L0+1)) "$LOG" | grep -m1 '\[WIN\] Start ear' | iso2ms)
  TS=$(tail -n +$((L0+1)) "$LOG" | grep -m1 '\[WIN\] Start Dropboard' | iso2ms)
  echo "board$N: Prozessstart→Eselsohr sichtbar=$((TE-T0)) ms  davon didFinishLaunching→Eselsohr=$((TE-TS)) ms"
  tail -n +$((L0+1)) "$LOG" | grep -m1 'geladen items='
done; done
```

Erwartet und Grenzen: Leeres Board: Start bis Eselsohr **< 250 ms**, `didFinishLaunching` bis Eselsohr **< 60 ms**. Mit 20 Bildern: dieselben Grenzen, weil das Dekodieren asynchron läuft. Liegt der Wert mit 20 Bildern über 300 ms, ist P11 bestätigt. Liegt `didFinishLaunching` bis Eselsohr über 60 ms, sind P11 (Noise, SMAppService) die Kandidaten. Bei Start über `launchctl asuser`/`open` kommen ≈ 50–150 ms LaunchServices dazu; diese Startart im Protokoll vermerken.

**4. Spitzenlast beim Start mit 20 und 100 Bildern** (P4)

```sh
start_db --board-dir /tmp/dbperf/board20
top -l 15 -s 1 -pid $PID -stats pid,command,cpu,threads,mem > /tmp/dbperf/top-start20.txt
awk -v p=$PID '$1==p{print}' /tmp/dbperf/top-start20.txt
footprint $PID 2>/dev/null | grep -iE 'footprint|phys' | head -3 || vmmap --summary $PID | grep -i 'Physical footprint'
# dasselbe mit board100
```

Erwartet und Grenzen: CPU fällt innerhalb **≤ 2 s** auf ≈ 0 %. Threads liegen dauerhaft unter 15. Footprint nach dem Einschwingen: board0 **< 50 MB**, board20 **< 80 MB**, board100 **< 200 MB**. Sind in den ersten Sekunden mehr als 15 Threads oder ein MEM-Spitzenwert über 300 MB zu sehen, ist P4 bestätigt.

**5. Idle-CPU über 60 s** (Eselsohr sichtbar, kein Drag, niemand an der Maus; App läuft seit mindestens 10 s)

```sh
start_db --board-dir /tmp/dbperf/board20; sleep 10
C0=$(cpu_s $PID); N0=$(wc -l < "$LOG"); sleep 60; C1=$(cpu_s $PID); N1=$(wc -l < "$LOG")
perl -e "printf \"Idle CPU-Mittel 60 s: %.3f %% (CPU-Zeit %.3f s)  neue Logzeilen: %d\n\", ($C1-$C0)/60*100, $C1-$C0, $N1-$N0"
ps -o pid,%cpu,time,rss,vsz -p $PID
```

Grenzen: CPU-Mittel **< 0,1 %** gilt als bestanden, ab **0,5 %** als Befund. CPU-Zeit in 60 s unter 0,06 s. Neue Logzeilen im Idle: **0**.

**6. Wakeups und CPU pro Sekunde mit `top`** (gleiche Bedingungen, 60 Intervalle)

```sh
top -l 61 -s 1 -c d -pid $PID -stats pid,command,cpu,idlew,csw,threads,mem > /tmp/dbperf/top-idle.txt
awk -v p=$PID '$1==p{n++; if(n>1){c+=$3; if($3>mx)mx=$3; w+=$4; s+=$5; m++}} END{printf "CPU Mittel %.2f %%  Max %.2f %%  idlew/s %.2f  csw/s %.1f  (n=%d)\n",c/m,mx,w/m,s/m,m}' /tmp/dbperf/top-idle.txt
```

Grenzen: CPU-Mittel **< 0,1 %**, Max **< 1 %**. `idlew` im Mittel **< 1/s** (Ziel 0). Kein regelmäßiges Muster, etwa alle 20 ms (50/s → P8) oder jede Sekunde. Hinweis: Steigt `idlew` von Zeile zu Zeile stetig an, zählt `top` kumulativ. Dann die Differenz (letzte minus zweite Zeile) durch 59 teilen.

**7. `sample` im Idle** (10 s, Intervall 1 ms)

```sh
sample $PID 10 1 -file /tmp/dbperf/sample-idle.txt
grep -A25 'Sort by top of stack' /tmp/dbperf/sample-idle.txt
grep -cE 'DragCoordinator|pollTick|Log\.line|BoardScene|ImageDecoder|CA::Transaction::commit' /tmp/dbperf/sample-idle.txt
```

Erwartet: Unter „Sort by top of stack“ liegen praktisch alle Samples in `mach_msg2_trap` (Main-Thread im Run-Loop) sowie in `__workq_kernreturn`/`__psynch_cvwait`. Der zweite `grep` liefert **0**. Jeder Treffer auf `pollTick` deutet auf einen nicht gestoppten Watchdog (P8), jeder auf `Log.line` auf Logging im Idle (P7).

**8. Expand-Latenz** (aus vorhandenen Logzeilen; Start mit board20 und Standard `two-panels`)

```sh
start_db --board-dir /tmp/dbperf/board20; LX=$(wc -l < "$LOG")
```

**[Max]**: (a) Fünfmal eine Bilddatei aus dem Finder (zum Beispiel `/tmp/dbperf/src4k.png`) aufs Eselsohr ziehen, still halten, bis das Board offen ist (~1 s), dann aus dem Board herausziehen (Zuklappen). (b) Zweimal dasselbe mit einem Bild aus Safari. (c) Einmal mit dem Screenshot-Thumbnail (⇧⌘4, dann das Thumbnail ziehen). Jeweils 3 s Pause dazwischen.

```sh
tail -n +$((LX+1)) "$LOG" | perl -ne '
 next unless /T(\d\d):(\d\d):(\d\d)\.(\d{3})/; $t=(($1*60+$2)*60+$3)*1000+$4;
 if (/\[HANDOFF\] neue Drag-Session/) { $s=$t }
 elsif (/\[HANDOFF\] draggingEntered win=ear pos=.*Expand-Timer (\d+)ms/) { $c=$t; $d=$1 }
 elsif (/\[FOCUS\] vor Expand/) { $f=$t }
 elsif (/dauer\(orderFront\/setFrame\)=([\d.]+)ms/) { $o=$1 }
 elsif (/\[WIN\] nach Expand board/) {
   printf "Expand #%d: PB-Dump=%s ms | Timer-Verspaetung=%d ms | open sync=%s ms | expandFired->Commit-Start=%d ms | SUMME nach Verzoegerungsende=%d ms\n",
     ++$n, (defined $s ? $c-$s : "-"), $f-$c-$d, $o, $t-$f, ($f-$c-$d)+($t-$f); undef $s }
 elsif (/\[HANDOFF\] draggingEntered win=board \+([\d.]+)ms/) { print "   Handoff: Board erreicht +$1 ms nach Expand\n" }
 elsif (/zuklappen=([\d.]+)ms/) { print "   Zuklappen: $1 ms\n" }'
```

So sind die Werte definiert, alle Zeitstempel mit ms-Auflösung:
- **PB-Dump** ist die Zeit von `[HANDOFF] neue Drag-Session` (`DragCoordinator.swift:202`) bis `[HANDOFF] draggingEntered win=ear … → Expand-Timer` (`:210`). Das ist die Zeit für `dumpPasteboard` und `looksLikeImage`, die **vor** dem Start der Verzögerung liegt (P1).
- **Timer-Verspätung** ist T(`[FOCUS] vor Expand`, `:367`) minus T(`Expand-Timer`-Zeile) minus Verzögerung (P14).
- **open sync** ist der Wert `dauer(orderFront/setFrame)` aus `[HANDOFF] Expand ausgelöst` (`:378`).
- **expandFired→Commit-Start** ist die Zeit von T(`[FOCUS] vor Expand`) bis T(`[WIN] nach Expand board`, `:382`), der letzten synchronen Aktion vor dem impliziten CA-Commit (P6). Der erste sichtbare Frame folgt frühestens danach, plus Commit-Dauer, plus höchstens ein Vsync (16,7 ms bei 60 Hz).

Grenzen: Timer-Verspätung im Mittel **≤ 5 ms** (max 10). Open sync **≤ 3 ms** (der erste Expand nach dem Start darf bis 10 ms). ExpandFired→Commit-Start **≤ 5 ms**. **SUMME (Expand-Start nach Verzögerungsende) < 16 ms**. PB-Dump: Finder **≤ 3 ms**. Liegen Safari oder Screenshot über 10 ms, ist P1 bestätigt. Zuklappen: **200–230 ms**. Wenn die Summe unter 16 ms liegt, ist das nur eine Untergrenze für den ersten sichtbaren Frame. Die exakte Messung braucht die Logzeilen aus P6 (`Expand commit +…ms` und `reveal gestartet +…ms`). Grenze dann: `reveal gestartet` **≤ 16 ms** nach `Expand ausgelöst`.

**9. Drop-Pfad** (Main-Thread-Block in `performDragOperation`)

```sh
LD=$(wc -l < "$LOG")
```

**[Max]**: Je einmal (a) eine Finder-Datei aufs offene Board, (b) eine Finder-Datei direkt aufs Eselsohr (Quick-Drop), (c) ein Safari-Bild aufs Board, (d) ein Screenshot-Thumbnail aufs Board, (e) eine Datei von einem externen Volume oder aus iCloud Drive, falls vorhanden. Jeweils 5 s Pause.

```sh
tail -n +$((LD+1)) "$LOG" | perl -ne '
 next unless /T(\d\d):(\d\d):(\d\d)\.(\d{3})/; $t=(($1*60+$2)*60+$3)*1000+$4;
 if (/\[DROP\] performDragOperation win=\S+ art=(.*?) dropPos/) { $p=$t; $a=$1; $w="" }
 elsif (/Weg=(fileURL|Bilddaten)\b.*? in ([\d.]+)ms/) { $w="Weg=$1 $2 ms" }
 elsif (/Weg=File-Promise/) { $w="Weg=File-Promise" }
 elsif (/\[DROP\] performDragOperation R\S*=(\w+) bilder=(\d+)/) { printf "Drop [%s]: Main-Thread in performDragOperation=%d ms  %s\n", $a, $t-$p, $w }
 elsif (/Promise\d+ vollst\S* nach ([\d.]+)ms/) { print "   Promise-Datei da nach $1 ms (Hintergrund)\n" }
 elsif (/\[DROP\] dekodiert id=\S+ in ([\d.]+)ms/) { print "   Dekodieren (Hintergrund) $1 ms\n" }
 elsif (/\[STORE\] gespeichert items=(\d+) in ([\d.]+)ms/) { print "   JSON speichern (Main) $2 ms bei $1 Items\n" }
 elsif (/Board geschlossen grund=nach Drop offen=([\d.]+)ms/) { print "   Board zu, offen insgesamt $1 ms\n" }'
```

Grenzen: Main-Thread in `performDragOperation` für Finder-Dateien auf demselben Volume **≤ 16 ms**. Für Safari und Bilddaten gilt dieselbe Grenze; ein Wert über 16 ms bestätigt P1/P2, ein Wert über 100 ms ist deutlich spürbar. Externe oder iCloud-Dateien über 16 ms bestätigen P3. Das Dekodieren einer 4K-Quelle im Hintergrund **≤ 150 ms**; mehr spricht für den Thumbnail-Weg aus P4. JSON speichern **≤ 5 ms** bei 20 Items.

**10. Optional: Last bei gehaltenem Drag** (Watchdog mit 50 Hz und Maske)

**[Max]**: Ein Finder-Bild aufs Eselsohr ziehen und ~10 s still über dem offenen Board halten, nicht loslassen. Der Orchestrator startet sofort nach dem Aufklappen:

```sh
sample $PID 5 1 -file /tmp/dbperf/sample-drag.txt; grep -c pollTick /tmp/dbperf/sample-drag.txt
top -l 6 -s 1 -pid $PID -stats pid,cpu,idlew | tail -5
```

Erwartet: CPU **< 2 %**. Die Wakeups liegen bei ≈ 50/s (Watchdog, bekannt, nur während des Drags). In `sample-drag.txt` gibt es keine Treffer auf `copy_image`/`convert`; gibt es welche, ist P13 bestätigt.

**11. Rückkehr zum Idle nach Interaktion** (nach den Schritten 8 bis 10, ohne Neustart)

**[Max]**: Zusätzlich einmal per Klick aufs Eselsohr den Ansichtsmodus öffnen, ein Bild verschieben und mit Esc schließen. Danach Hände weg von Maus und Tastatur.

```sh
sleep 10   # FileProbe-Nachläufer (P9) abklingen lassen
C0=$(cpu_s $PID); N0=$(wc -l < "$LOG"); sleep 30; C1=$(cpu_s $PID); N1=$(wc -l < "$LOG")
perl -e "printf \"Idle nach Interaktion: %.3f %% CPU, neue Logzeilen %d\n\", ($C1-$C0)/30*100, $N1-$N0"
top -l 11 -s 1 -c d -pid $PID -stats pid,cpu,idlew | tail -10
```

Grenzen: Dieselben Werte wie in Schritt 5 und 6 (**< 0,1 % CPU**, **idlew < 1/s**, **0 Logzeilen**). Sind es ≈ 50 Wakeups/s, läuft der Watchdog noch (P8).

**12. Speicher im Ruhezustand nach Bildanzahl** (P13)

```sh
for N in 0 20 100; do start_db --board-dir /tmp/dbperf/board$N; sleep 8
  echo "board$N: $(vmmap --summary $PID 2>/dev/null | grep -i 'Physical footprint:' | head -1)  rss=$(ps -o rss= -p $PID) KB"; done
pkill -x Dropboard
```

Grenzen: Der Zuwachs pro Bild ist (board100 − board0) / 100 und sollte **≤ 1,5 MB/Bild** sein. Mit 4K-Quellen in Vollauflösung wären es ≈ 33 MB/Bild; das würde fehlendes Downsampling zeigen. board0 **< 50 MB**.

**13. Optional, nur mit `sudo` ohne Passwortabfrage:** Wakeups pro Sekunde nach Art.

```sh
sudo powermetrics --samplers tasks --show-process-energy -i 1000 -n 30 | grep -E 'Dropboard|Name'
```

Erwartet: Bei Dropboard liegen „Intr Wakeups/s“ und „Idle Wakeups/s“ bei ≈ 0 und „CPU ms/s“ bei < 1.

### Auswertung für den Orchestrator (Zusammenfassung der Grenzen)

| Messgröße | Bestanden | Befund ab |
|---|---|---|
| Idle-CPU-Mittel (60 s) | < 0,1 % | ≥ 0,5 % |
| Idle-Wakeups (`idlew`) | < 1/s | ≥ 5/s oder periodisches Muster |
| Neue Logzeilen im Idle | 0 | ≥ 1 ohne Nutzeraktion |
| Start → Eselsohr sichtbar | < 250 ms | ≥ 400 ms |
| Expand: Timer-Verspätung | ≤ 5 ms | > 10 ms |
| Expand: Summe nach Verzögerungsende (bis Commit-Start) | < 16 ms | ≥ 16 ms |
| PB-Dump in `draggingEntered` | ≤ 3 ms | > 10 ms |
| Main-Thread in `performDragOperation` | ≤ 16 ms | > 50 ms |
| Zuklappen | 200–230 ms | > 260 ms |
| Footprint-Zuwachs pro Bild | ≤ 1,5 MB | > 5 MB |
