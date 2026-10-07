# Drag-and-Drop vom macOS-Screenshot-Thumbnail (plus Finder und Browser) in ein nicht-aktivierendes NSPanel

> Phase-0-Recherche · Stand 7. Okt. 2026 · Recherche-Agent (Opus 5.5), Linux-Container, **nichts davon wurde auf einem Mac getestet**.
> Inline-Marker „⚠️ V*n*“ verweisen auf die Liste im Abschnitt „⚠️ VERIFIZIEREN“.

## Ergebnis

Das Screenshot-Thumbnail lässt sich per Drag-and-Drop empfangen. Mehrere unabhängige Entwickler-Berichte von 2026 (macOS 26) zeigen allerdings: Das Thumbnail bietet **ein File-Promise und zusätzlich eine fileURL auf eine private Kopie in `/var/folders/…/T/TemporaryItems/NSIRD_screencaptureui_*/`**. macOS löscht diese Kopie kurz nach dem Ende des Drags. Robust ist deshalb nur dieser Weg: in `performDragOperation(_:)` sofort annehmen, also entweder das Promise mit `NSFilePromiseReceiver.receivePromisedFiles(atDestination:options:operationQueue:reader:)` in einen App-eigenen Ordner schreiben lassen oder die fileURL noch während des Drops synchron kopieren. Die View registriert dafür `NSFilePromiseReceiver.readableDraggedTypes` plus `.fileURL` und Bildtypen. Apple empfiehlt, Promises vor fileURLs auszuwerten. Promises werden asynchron erfüllt, und der Reader-Block kann mit Fehler und ohne oder mit unvollständiger Datei zurückkommen. Für die Annahme selbst braucht es nach allem, was dokumentiert ist, **keine Accessibility- und keine Input-Monitoring-Berechtigung**. Das ist nur durch Abwesenheit belegt (⚠️ V9). Ein nicht-aktivierendes NSPanel kann Drops annehmen, ohne dass die App aktiv wird. Belegt ist das nur durch Drittprojekte, nicht durch Apple (⚠️ V6). Achtung: `NSPanel.hidesOnDeactivate` ist standardmäßig `YES` und muss bei Dropboard auf `NO` gesetzt werden.

## Details

### 1. Welche Pasteboard-Typen liefert das Screenshot-Thumbnail?

- **File-Promise**: Mehrere Projekte haben unabhängig voneinander das Thumbnail als Promise identifiziert.
  - dynamic-island-mac PR #7: „The thumbnail is a promised file, and the island only opened for plain files, so the drop fell through to the window behind.“ Die Drop-Zone registriert dort danach u. a. `com.apple.NSFilePromiseItemMetaData`, `com.apple.pasteboard.promised-file-url`, `com.apple.pasteboard.promised-file-content-type`, `NSPromiseContentsPboardType` sowie `.fileURL`, `.png`, `.tiff`, `public.jpeg` und `public.heic`. [Q14, Q15]
  - edith PR #763: „Drops that offer file promises, like the screenshot thumbnail, now write into Edith's own drop folder instead of pasting a temporary path that disappears.“ [Q11]
  - argmax PR #152: Das Thumbnail „advertises Apple UTIs and file promises“. [Q16]
- **fileURL auf eine temporäre Kopie**: Laut edith PR #763 bietet das Thumbnail „a URL into a private TemporaryItems copy that is deleted when the drag ends“. [Q11] Terminals, die nur Dateipfade lesen, erhalten tatsächlich einen Pfad wie `/var/folders/…/TemporaryItems/NSIRD_screencaptureui_Z9ThME/Screenshot 2026-07-24 at 22.00.42.png` (claude-code #80980, Darwin 25.5.0; ebenso #53631, Darwin 25.4.0). [Q12, Q13] Die Datei verschwindet „soon after the drop, often before the agent reads it“ (crystal PR #107). [Q17] In claude-code #80980 funktionierte synchrones Lesen beim Drop, asynchrones Lesen danach schlug mit ENOENT fehl. [Q12]
- **Bilddaten (public.png/tiff) direkt auf dem Pasteboard**: Kein Bericht belegt, dass das Thumbnail rohe Bilddaten anbietet. ⚠️ V1
- **Metadaten-Typ**: `com.apple.NSFilePromiseItemMetaData` ist eine Property List mit Schlüsseln wie `com.apple.pasteboard.promised-file-content-type`. Apple hat ihn nicht dokumentiert, und die Forumsfrage dazu von 2018 blieb unbeantwortet. [Q8] Auf diese Rohtypen sollte man sich nicht verlassen. Stattdessen `NSFilePromiseReceiver.readableDraggedTypes` verwenden (siehe 2).
- **Herstellerberichte von Yoink, Dropover oder CleanShot**: Ich habe keine abrufbare technische Aussage gefunden. Die gefundenen Release-Notes erwähnen das Screenshot-Thumbnail nicht. ⚠️ V2
- **Regressionen**: Ein Issue im Sapphire-Projekt (macOS 26.0) meldet, dass der Drop des Thumbnails in eine Notch-Drop-Zone „not recognized or saved“ wird. Die Ursache wird dort nicht genannt und es gibt keinen Fix. [Q10] Laut Suchergebnis-Snippets gibt es Apple-Community-Threads, nach denen der Drag vom Thumbnail seit macOS Tahoe teilweise nicht mehr funktioniert. Die Seiten waren nicht abrufbar (Egress blockiert). ⚠️ V3

### 2. File-Promises korrekt empfangen

- **Registrierung**: „A view must register what types it accepts via `NSView.registerForDraggedTypes(_:)`. Use that class method to get the file promise drag types that `NSFilePromiseReceiver` can accept … If you don't register all these drag types, you might not be notified about some file promise drags.“ Gemeint ist `NSFilePromiseReceiver.readableDraggedTypes`, das sowohl item-basierte (`NSFilePromiseProvider`) als auch ältere, nicht item-basierte Promises abdeckt. [Q2] Die Registrierung macht die View automatisch zum Kandidaten für das Ziel eines Drags. [Q7]
- **Auslesen**: `NSFilePromiseReceiver` implementiert `NSPasteboardReading`. Man erhält die Receiver über `draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)` oder über `enumerateDraggingItems(…classes: [NSFilePromiseReceiver.self]…)`. Ein nicht item-basierter Source kann mehrere Dateien in einem Item versprechen, deshalb liefern `fileNames` und `fileTypes` Arrays. [Q1]
- **Erfüllen**: `receivePromisedFiles(atDestination:options:operationQueue:reader:)`. Apple dazu: „Call this method only when you're accepting the file promise. All file promise receivers in a drag must specify the same destination location. The options dictionary is ignored for now. The reader block is called on the supplied operationQueue when the promised file is ready to be read.“ [Q3]
- **Asynchron**: Apple empfiehlt eine Hintergrund-Queue, „Avoid blocking the main thread while waiting for the file promise to be written (which can be a long process)“. Bei einem `NSFilePromiseProvider` als Quelle ist der Reader-Aufruf in eine File-Coordination-Leseoperation eingebettet. [Q3] Das Apple-Sample zeigt bis zur Erfüllung einen Spinner. [Q4]
- **Fehlerfall**: „If writing the promised file fails, the reader block is still called with a non-nil error. There may be nothing in fileURL, or there may be a partial or corrupt file.“ [Q3]
- **Zeitpunkt**: Die alte Promise-API verlangt, dass das Ziel die Dateien „only within `performDragOperation:`“ anfordert, „or else the source may create the files in the incorrect location“. [Q6] edith PR #763 berichtet, dass AppKit Promises nur während eines Drops annimmt: Ein Cmd-V auf ein Pasteboard mit Promise löste dort eine Exception aus. [Q11] Für `receivePromisedFiles` ist die Bindung an `performDragOperation` nur indirekt belegt. ⚠️ V4
- **Zielordner**: Er muss ein Verzeichnis sein, und alle Receiver eines Drags müssen dasselbe Ziel bekommen. [Q3] Was bei Namenskollisionen im Zielordner passiert, ist nicht dokumentiert. ⚠️ V5 Ein Projekt verwendet pro Drop einen frischen Unterordner `Application Support/<app>/Incoming/<uuid>/`. [Q9]
- **Konsequenz für Dropboard**: Weil das Promise asynchron erfüllt wird, kann die Datei beim Quick-Drop oder beim Drop aufs Board noch fehlen, wenn das Overlay schon schließt. Das Board braucht deshalb einen Platzhalter-Zustand für das Bild, bis der Reader-Block ankommt. Das ist eine Designentscheidung für Phase 1 und 2, keine API-Frage.

### 3. Empfang in einem nicht-aktivierenden NSPanel

- Apple beschreibt `NSWindow.StyleMask.nonactivatingPanel` so: „The window is a panel or a subclass of NSPanel that does not activate the owning app.“ [Q19]
- Die Drag-Destination-Messages kommen bei der View oder dem Fenster an, das für die Typen registriert ist, „as an image enters, moves around inside, and then exits or is released within the destination's boundaries“. [Q18] Weder `NSDraggingDestination` noch der Programming Guide [Q20] knüpfen den Empfang daran, dass die App aktiv oder das Fenster key ist. Ein ausdrückliches Apple-Statement „Drops in inaktive Apps oder nicht-aktivierende Panels funktionieren“ habe ich aber nicht gefunden. ⚠️ V6
- Praxisbeleg aus einem Drittprojekt (box4dd PR #12): „The panel stays `.nonactivatingPanel`: even while key, box4dd never becomes the active app … a drag hovering over it … never call it, so the app in front keeps the keys.“ [Q21] Dasselbe Projekt nimmt File-Promises von Mail, Photos und Browsern an. [Q9]
- **Stolperfalle `hidesOnDeactivate`**: „Onscreen panels … are removed from the screen when the application isn't active … the NSPanel implementation of the same method returns YES.“ [Q22] Da Dropboard nie aktiv sein soll, muss `hidesOnDeactivate = false` gesetzt werden. Sonst kann das Eselsohr verschwinden, sobald die App einmal aktiv war und dann deaktiviert wird (z. B. nach dem Ansichtsmodus). Wie sich ein Panel verhält, das nie aktiviert wurde, ist nicht belegt. ⚠️ V7
- Ob ein `performDragOperation` die App beim Drop dennoch kurz aktiviert, ist nicht belegt. Laut box4dd nicht. ⚠️ V6
- Zum Wechsel der Drag-Session vom kleinen Eselsohr-Panel ins wachsende Board-Panel liegt keine Quelle vor. Das gehört ins Window-Level-Thema und in Spike 1. ⚠️ V8

### 4. Sandbox und Schicksal der Original-Screenshot-Datei

- **Nicht sandboxed** (Developer-ID-Verteilung): Es gibt keine Sandbox-Einschränkung. Die Datei muss nur vor der Löschung durch macOS kopiert sein (siehe 1).
- **Mit App Sandbox**: Quinn (Apple DTS) schreibt: „Sandboxed apps have to be careful when accessing files that are dropped on to them. That drop represents a dynamic extension to the sandbox.“ [Q23] Apples Dokumentation zum Dateizugriff nennt die automatische Security-Scope-Erweiterung ausdrücklich nur für Open/Save-Panels und für Drops auf das Dock-Icon, nicht für Drops in ein Fenster. [Q24] Ein Forumsbeitrag (QuinceyMorris, kein Apple-Mitarbeiter) vermutet, dass Pasteboard-URLs bereits security-scoped sind, und hält einen Aufruf von `startAccessingSecurityScopedResource()` für möglicherweise nötig. [Q25] Bei Drops aus Mail in eine sandboxed Catalyst-App gibt es Berichte über „Failed to get a sandbox extension“, und die Bookmark-Entitlements halfen dort nicht (unbeantwortet). [Q26] Für File-Promises schreibt die Quelle in einen Zielordner, den der Empfänger bestimmt. In der Sandbox muss das ein Ordner im Container sein. Ob dafür ein Entitlement nötig ist, ist nicht belegt. ⚠️ V10
- **Empfehlung**: Den Prototyp **ohne App Sandbox** bauen. Die Sandbox ist nur für den Mac App Store Pflicht, und das Briefing fordert keinen App-Store-Vertrieb. Den Sandbox-Fall separat testen (Testplan T7).
- **Original-Screenshot**: Laut claude-code #80980 gilt: „the thumbnail drag consumes the capture — no fallback copy is saved to the screenshot folder“. [Q12] dynamic-island-mac PR #7 bestätigt sinngemäß, dass macOS die temporäre Datei löscht und die App deshalb selbst kopiert. [Q14] Wenn Dropboard den Drop annimmt, landet der Screenshot also **nicht** zusätzlich auf dem Schreibtisch. Die Kopie im App-Ordner ist dann die einzige Kopie. Das ist nur durch einen Drittbericht belegt. ⚠️ V11 Was bei einem abgelehnten Drop passiert (`performDragOperation` gibt `false` zurück), ist unklar: Schnellt das Thumbnail zurück, und wird der Screenshot dann normal gespeichert? ⚠️ V12

### 5. Empfohlene Reihenfolge der Typ-Auswertung

Apple sagt im Sample „Supporting Drag and Drop Through File Promises“: „Handle file promises before handling URLs, because the file promise generally represents the higher-quality image and should take precedence when both types are supported.“ Danach fileURLs, „in case the app from which a user drags the image doesn't provide file promises.“ [Q4] Finder liefert laut demselben Sample nur die fileURL ohne Promise, ebenso ein Mail-Anhang. Safari und Photos liefern Promises. [Q4]

Vorgeschlagene Reihenfolge pro Dragging-Item, auf Basis von Apple [Q4] und box4dd PR #15 [Q9]:

1. **File-Promise** (`NSFilePromiseReceiver`) → asynchron in `<App-Ordner>/Incoming/<uuid>/` empfangen. Das deckt Screenshot-Thumbnail, Safari, Chrome und Photos ab.
2. **fileURL** → **synchron in `performDragOperation`** in den App-Ordner kopieren. Das deckt Finder ab und dient als Fallback für das Thumbnail, falls das Promise fehlschlägt. Die Datei in `TemporaryItems/NSIRD_screencaptureui_*` existiert nur kurz. [Q11, Q12, Q17] box4dd behandelt URLs in `~/Library` oder `.photoslibrary` als App-interne Kopie und zieht dort das Promise vor. [Q9]
3. **Bilddaten** (`public.png`, `public.tiff`, `public.jpeg`, `public.heic`) → direkt als Datei schreiben.
4. **Web-URL** (`public.url`) → nur bei Bild-URLs herunterladen. Das ist Priorität 2 und für den Prototyp optional.

Hinweise zu Browsern:
- **Chrome** schreibt laut Quellcode (`web_drag_source_mac.mm`) u. a. `NSPasteboardTypeURL`, den UTI des Dateityps mit den Dateiinhalten, `kPasteboardTypeFileURLPromise`, `kPasteboardTypeFilePromiseContent`, `NSPasteboardTypeHTML` und `NSPasteboardTypeString`. Chrome nutzt bewusst **nicht** `NSFilePromiseProvider` („Its design is fundamentally broken…“), sondern die alte, nicht item-basierte Promise-API. Das Promise wird per IPC synchron erfüllt. [Q27] Laut Apple akzeptiert `NSFilePromiseReceiver` auch nicht item-basierte Promises. [Q2] Chrome-Drops sollten also über Schritt 1 laufen. Ob der Receiver für Chrome korrekt auflöst, ist nicht getestet. ⚠️ V13
- **Safari**: Laut Apple-Sample kommen Bild-Drags aus Safari über `NSFilePromiseReceiver` herein. [Q4] Welche Typen Safari genau anbietet, ist nicht belegt. ⚠️ V14
- **Firefox**: Ein Bugzilla-Eintrag (1450419) zu unvollständiger Promise-Unterstützung existiert laut Suche, war aber nicht abrufbar. ⚠️ V15
- **Icon statt Bild**: Bei Photos und „Recents“ übernehmen manche Apps fälschlich das Icon der Datei statt des Bildes, weil sie eine Bildrepräsentation vor dem Promise oder der fileURL lesen. [Q28] Das stützt die Regel „Promise und fileURL vor Bilddaten“.

### 6. Accessibility und Input Monitoring

- Die Annahme eines Drops läuft über `registerForDraggedTypes(_:)` und `NSDraggingDestination`. Weder diese API-Dokumentation [Q7, Q18] noch das Apple-Sample [Q4] noch die Doku zu `NSFilePromiseReceiver` [Q1–Q3] erwähnt eine TCC-Berechtigung.
- Eine Berechtigung nennt Apple nur für die **globale** Event-Überwachung: „Key-related events may only be monitored if accessibility is enabled or if your application is trusted for accessibility access“ (`NSEvent.addGlobalMonitorForEvents`). [Q29] Dropboard braucht das für den Drop nicht, weil das Eselsohr selbst das Drop-Ziel ist (Briefing).
- Die Erwartung „keine Berechtigung nötig“ ist plausibel, aber **nur durch Abwesenheit belegt**. Ein positives Apple-Statement fehlt. ⚠️ V9 Hinweis: dynamic-island-mac fragt zwar Accessibility ab, laut PR aber für eine andere Funktion und nicht für den Drop. [Q14]

## Offene Punkte

1. Die genaue Typ-Liste des Thumbnails auf der Ziel-macOS-Version (26 bzw. 27). Bietet es auch Bilddaten an? Ist die Reihenfolge der Typen stabil? (V1, V3)
2. Wie lange existiert die temporäre fileURL nach dem Drop? Reicht ein synchrones Kopieren in `performDragOperation` immer? (Q12 legt es nahe.)
3. Ob das Thumbnail beim Annehmen den Screenshot „verbraucht“ und was bei einem abgelehnten Drop passiert. (V11, V12)
4. Verhalten von `receivePromisedFiles` außerhalb von `performDragOperation`, bei Namenskollisionen und bei sehr großen Dateien. (V4, V5)
5. Drop in ein nicht-aktivierendes, borderless, transparentes NSPanel ohne Aktivierung der App, auch über Fullscreen-Spaces. (V6, V7)
6. Übergabe der Drag-Session vom Eselsohr-Panel an das Board-Panel. (V8, gehört zu Spike 1 und zum Window-Level-Report)
7. Sandbox-Variante: Werden Entitlements gebraucht? (V10)
8. Typen aus Safari, Chrome und Firefox, und ob `NSFilePromiseReceiver` Chromes alte Promise-API korrekt auflöst. (V13–V15)
9. Keine TCC-Abfrage beim Drop. (V9)
10. Technische Aussagen von Yoink, Dropover oder CleanShot wurden nicht gefunden. (V2)

## ⚠️ VERIFIZIEREN

- **V1** Das Screenshot-Thumbnail legt keine rohen Bilddaten (`public.png`/`public.tiff`) aufs Drag-Pasteboard, nur Promise und fileURL. Dazu gibt es keinen Beleg.
- **V2** Kein Hersteller (Yoink, Dropover, CleanShot) hat öffentlich beschrieben, wie er das Thumbnail empfängt. Es wurde nichts Abrufbares gefunden.
- **V3** Regression seit macOS Tahoe beim Drag vom Thumbnail. Das ist nur aus Suchergebnis-Snippets zu discussions.apple.com bekannt, die Seiten waren blockiert.
- **V4** `receivePromisedFiles` muss in `performDragOperation` aufgerufen werden. Explizit dokumentiert ist das nur für die alte Promise-API [Q6], sonst gibt es nur einen indirekten Drittbeleg [Q11].
- **V5** Verhalten bei Namenskollisionen im Zielordner von `receivePromisedFiles` (überschreiben, umbenennen oder Fehler).
- **V6** Ein nicht-aktivierendes NSPanel empfängt Drops vollständig, auch `performDragOperation`, ohne die App zu aktivieren. Belegt ist das nur durch ein Drittprojekt [Q21].
- **V7** Verhalten von `hidesOnDeactivate` (Standard `YES`) bei einer App, die nie aktiviert wurde, und ob `false` für Dropboard ausreicht.
- **V8** Die Drag-Session geht nahtlos vom Eselsohr-Panel ins wachsende Board-Panel über.
- **V9** Für den Drop-Empfang ist keine Accessibility- oder Input-Monitoring-Berechtigung nötig. Belegt ist das nur dadurch, dass die Dokumentation nichts erwähnt.
- **V10** Entitlements oder Sandbox-Verhalten für fileURL-Drops und Promise-Ziele bei aktivierter App Sandbox.
- **V11** Das Annehmen des Thumbnail-Drops „verbraucht“ den Screenshot, es wird keine Kopie auf dem Schreibtisch bzw. im Screenshot-Ordner gespeichert. Das stammt aus einer Drittquelle [Q12].
- **V12** Verhalten des Thumbnails, wenn der Drop abgelehnt wird.
- **V13** `NSFilePromiseReceiver` löst Chromes nicht item-basierte Promises (`kPasteboardTypeFileURLPromise`) korrekt auf.
- **V14** Genaue Pasteboard-Typen eines Bild-Drags aus Safari.
- **V15** Firefox-Bild-Drags und Promise-Unterstützung (Bugzilla 1450419 nicht abrufbar).

## Testplan macOS

Voraussetzung: ein Mac mit der Ziel-macOS-Version, Xcode, Testbilder (PNG, JPEG, HEIC), Safari, Chrome und optional Firefox. Protokoll je Schritt: macOS-Version, Quelle, Ergebnis.

- **T0 Typen logging ohne eigenen Code**: Mit dem Open-Source-Tool `dragdrop-tester` [Q30] die angebotenen Typen und Daten für jede Quelle protokollieren: Thumbnail nach Cmd-Shift-3, Cmd-Shift-4 und Cmd-Shift-5, Finder-PNG, -JPEG und -HEIC, Safari-Bild, Chrome-Bild, Photos. Für das Thumbnail die Typ-Liste und den Pfad aus `public.file-url` notieren. → klärt V1, V3, V14, V15
- **T1 Logging-Spike** (Teil von Spike 1, kein Produktionscode hier): Eine View im Eselsohr-Panel registriert `NSFilePromiseReceiver.readableDraggedTypes` plus `.fileURL`, `.png`, `.tiff` und `.URL`. Geloggt wird in `draggingEntered` und in `performDragOperation`: `draggingPasteboard.types`, für jedes `pasteboardItem` dessen `types`, außerdem die Ergebnisse von `readObjects(forClasses:)` für `NSFilePromiseReceiver` (`fileNames`, `fileTypes`) und `NSURL`.
- **T2 Lebensdauer der Temp-Datei**: Beim Thumbnail-Drop die fileURL lesen. `FileManager.fileExists` prüfen: in `performDragOperation`, in `concludeDragOperation`, nach 100 ms, nach 1 s und nach 5 s. → Offener Punkt 2
- **T3 Promise-Timing**: `receivePromisedFiles` in `performDragOperation` mit einer Hintergrund-`OperationQueue` und einem frischen `Incoming/<uuid>/`-Ordner aufrufen. Die Zeit bis zum Reader-Callback, die Dateigröße und den Fehler protokollieren. Dasselbe absichtlich in `concludeDragOperation` bzw. nach dem Drop versuchen. Zweimal denselben Dateinamen in denselben Ordner promisen. → V4, V5
- **T4 Schicksal des Screenshots**: Screenshot-Speicherort auf Schreibtisch stellen. (a) Thumbnail in Dropboard ablegen, angenommen. (b) Drop absichtlich ablehnen (`performDragOperation` gibt `false` zurück). (c) Thumbnail nicht anfassen. In allen drei Fällen den Schreibtisch und den App-Ordner prüfen. → V11, V12
- **T5 Nicht-aktivierend**: Panel mit `[.borderless, .nonactivatingPanel]`, `hidesOnDeactivate = false`, hohem Level und `canJoinAllSpaces` bzw. `fullScreenAuxiliary`. Vor und nach dem Drop `NSWorkspace.shared.frontmostApplication` und `NSApp.isActive` loggen und prüfen, ob die Menüleiste der Quell-App bleibt. Jeweils einmal mit TextEdit im Fenster, mit einer App im Vollbild (z. B. DaVinci Resolve) und mit dem Thumbnail als Quelle testen. Danach einmal den Ansichtsmodus per Klick aktivieren, zu einer anderen App wechseln und prüfen, ob das Eselsohr sichtbar bleibt. → V6, V7
- **T6 Panel-Übergabe**: Drag aufs Eselsohr, dann das Board-Panel unter dem Cursor vergrößern bzw. einblenden. Loggen, ob das Board `draggingEntered` erhält und den Drop bekommt. → V8
- **T7 Sandbox-Variante**: Dasselbe Spike-Target mit aktivierter App Sandbox und ohne weitere Entitlements bauen. T1 bis T3 für das Thumbnail, eine Finder-Datei aus `~/Pictures` und Safari wiederholen. Console.app nach „sandbox“ und „extension“ filtern. → V10
- **T8 TCC**: Auf einem sauberen Benutzerkonto oder nach `tccutil reset Accessibility <bundle-id>` und `tccutil reset ListenEvent <bundle-id>` die Drops aus T1 wiederholen. Prüfen, dass kein Systemdialog erscheint und die App unter Datenschutz → Bedienungshilfen bzw. Eingabeüberwachung nicht auftaucht. → V9
- **T9 Browser**: Bild aus Chrome, Safari und Firefox ziehen. Prüfen, ob der Pfad über `NSFilePromiseReceiver` greift, welcher Dateiname entsteht und ob als Fallback Bilddaten oder URL greifen. → V13–V15

## Quellen

Alle Seiten wurden am 7. Okt. 2026 abgerufen. Apple-Seiten rendern per JavaScript, daher wurde die JSON-Variante (`/tutorials/data/documentation/…json`) abgerufen, wo angegeben.

- [Q1] Apple: NSFilePromiseReceiver (JSON) – https://developer.apple.com/tutorials/data/documentation/appkit/nsfilepromisereceiver.json
- [Q2] Apple: NSFilePromiseReceiver.readableDraggedTypes (JSON) – https://developer.apple.com/tutorials/data/documentation/appkit/nsfilepromisereceiver/readabledraggedtypes.json
- [Q3] Apple: receivePromisedFiles(atDestination:options:operationQueue:reader:) (JSON) – https://developer.apple.com/tutorials/data/documentation/appkit/nsfilepromisereceiver/receivepromisedfiles(atdestination:options:operationqueue:reader:).json
- [Q4] Apple Sample: Supporting Drag and Drop Through File Promises (JSON) – https://developer.apple.com/tutorials/data/documentation/appkit/supporting-drag-and-drop-through-file-promises.json
- [Q5] Apple: NSPasteboard.PasteboardType.filePromise (JSON; seit 10.14 deprecated, Verweis auf `kPasteboardTypeFileURLPromise`) – https://developer.apple.com/tutorials/data/documentation/appkit/nspasteboard/pasteboardtype/filepromise.json
- [Q6] Apple Archive: Drag and Drop Programming Topics – Dragging Files – https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Tasks/DraggingFiles.html
- [Q7] Apple: NSView.registerForDraggedTypes(_:) (JSON) – https://developer.apple.com/tutorials/data/documentation/appkit/nsview/registerfordraggedtypes(_:).json
- [Q8] Apple Developer Forums: NSFilePromiseItemMetaData on pasteboard – https://developer.apple.com/forums/thread/108902
- [Q9] GitHub phuocphn/box4dd PR #15 „File promises: Mail and Photos drops“ – https://github.com/phuocphn/box4dd/pull/15
- [Q10] GitHub cshariq/Sapphire Issue #124 – https://github.com/cshariq/Sapphire/issues/124
- [Q11] GitHub pulkitxm/edith PR #763 „keep screenshot thumbnail drops attached in the terminal“ – https://github.com/pulkitxm/edith/pull/763 (sowie /files)
- [Q12] GitHub anthropics/claude-code Issue #80980 „Dragging the macOS screenshot floating thumbnail silently discards the image“ – https://github.com/anthropics/claude-code/issues/80980
- [Q13] GitHub anthropics/claude-code Issue #53631 – https://github.com/anthropics/claude-code/issues/53631
- [Q14] GitHub samidun26/dynamic-island-mac PR #7 – https://github.com/samidun26/dynamic-island-mac/pull/7
- [Q15] dieselbe PR, Dateiansicht (`ShelfDrop.swift`) – https://github.com/samidun26/dynamic-island-mac/pull/7/files
- [Q16] GitHub adamthuvesen/argmax PR #152 – https://github.com/adamthuvesen/argmax/pull/152
- [Q17] GitHub gabalexander/crystal PR #107 – https://github.com/gabalexander/crystal/pull/107
- [Q18] Apple: NSDraggingDestination (JSON) – https://developer.apple.com/tutorials/data/documentation/appkit/nsdraggingdestination.json ; performDragOperation(_:) – https://developer.apple.com/tutorials/data/documentation/appkit/nsdraggingdestination/performdragoperation(_:).json
- [Q19] Apple: NSWindow.StyleMask.nonactivatingPanel (JSON) – https://developer.apple.com/tutorials/data/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel.json
- [Q20] Apple Archive: Receiving Drag Operations – https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Tasks/acceptingdrags.html
- [Q21] GitHub phuocphn/box4dd PR #12 – https://github.com/phuocphn/box4dd/pull/12
- [Q22] Apple Archive: How Panels Work – https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/WinPanel/Concepts/UsingPanels.html (Überblick: https://developer.apple.com/tutorials/data/documentation/appkit/nspanel.json)
- [Q23] Apple Developer Forums: Drop file not found on MacBook Air (Antwort Quinn, DTS) – https://developer.apple.com/forums/thread/794845
- [Q24] Apple: Accessing files from the macOS App Sandbox (JSON) – https://developer.apple.com/tutorials/data/documentation/security/accessing-files-from-the-macos-app-sandbox.json
- [Q25] Apple Developer Forums: NSPasteboard Copy Dragged and Dropped File – https://developer.apple.com/forums/thread/77926
- [Q26] Apple Developer Forums: Drag-and-drop mail attachment to Mac Catalyst app – „Failed to get a sandbox extension“ – https://developer.apple.com/forums/thread/729485
- [Q27] Chromium-Quellcode `content/app_shim_remote_cocoa/web_drag_source_mac.mm` (GitHub-Mirror) – https://raw.githubusercontent.com/chromium/chromium/main/content/app_shim_remote_cocoa/web_drag_source_mac.mm
- [Q28] GitHub anthropics/claude-code Issue #85306 – https://github.com/anthropics/claude-code/issues/85306
- [Q29] Apple: NSEvent.addGlobalMonitorForEvents(matching:handler:) (JSON) – https://developer.apple.com/tutorials/data/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:).json
- [Q30] GitHub digitalmoksha/dragdrop-tester – https://github.com/digitalmoksha/dragdrop-tester

Ebenfalls abgerufen, aber ohne verwertbaren Inhalt für die Kernfragen: Apple Forums 769049 (verweist nur auf das Sample Q4), 802279 (Dateinamen-Regression bei `NSItemProvider` in macOS 26, laut Thread in macOS 27 behoben; betrifft SwiftUI/`FileRepresentation`, nicht direkt AppKit-Promises), 773939, 30577; GitHub Blaizzy/nativ PR #643; openai/codex Issue #25637 (Simulator-Thumbnail, gleiches Muster „Temp-Datei weg beim späteren Lesen“).

Nicht abrufbar (Egress blockiert), daher nicht als Beleg verwendet: discussions.apple.com (Threads 256163081, 256136592), support.apple.com/102646, 9to5mac.com, cloudy.dev, wadetregaskis.com, christiantietze.de, bugzilla.mozilla.org, forum.xojo.com, chromium.googlesource.com. Die Apple-Core-Services-JSON-Seiten zu `kPasteboardTypeFileURLPromise` und `kPasteboardTypeFilePromiseContent` lieferten 404.
