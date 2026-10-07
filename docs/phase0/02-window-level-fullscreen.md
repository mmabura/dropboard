# Window-Level, Collection-Behavior und Panel-Konfiguration für Eselsohr und Board über Fullscreen-Spaces

> Phase-0-Report · Sub-Agent „Window-Level/Fullscreen“ · Stand 2026-10-07
> Recherche ohne macOS-Zugriff (Linux-Container). **Nichts davon ist auf echter Hardware getestet.** Jede Verhaltensaussage stützt sich auf Dokumentation, Berichte Dritter oder gelesenen Fremdcode; der Nachweis steht im Testplan.
> Apple-Dokumentation wurde über die JSON-Variante abgerufen (`https://developer.apple.com/tutorials/data/documentation/<pfad>.json`), weil die HTML-Seiten per JS rendern. In den Quellen steht jeweils die normale Doku-URL; der Inhalt stammt aus der JSON-Variante.

## Ergebnis

1. **Level:** Ob ein Fenster in einem fremden Fullscreen-Space erscheint, hängt nach den gefundenen Belegen **nicht vom Level ab**, sondern davon, ob es eine **`NSPanel` mit `.nonactivatingPanel`** ist und welche Collection-Behavior es hat. Es gibt Berichte, dass schon `.floating` reicht (macOS 26). Das Level bestimmt nur die Reihenfolge innerhalb des Space. Empfehlung: **`.statusBar` (25)** für Eselsohr und Board. Das liegt über der Menüleiste (24) und klar unter Pop-up-Menüs (101) und unter dem Level für gezogene Fenster (`kCGDraggingWindowLevel`, 500). **`.screenSaver` (1000) und höher meiden**, weil dann vermutlich das Drag-Bild hinter dem Board verschwindet (⚠️).
2. **Collection-Behavior:** Empfohlen ist **`[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`**. Dieselbe Kombination verwenden boring.notch und NotchDrop, das Briefing ebenso. Laut Header schließen sich gegenseitig aus: `managed`/`transient`/`stationary`, `participatesInCycle`/`ignoresCycle` und `fullScreenPrimary`/`fullScreenAuxiliary`/`fullScreenNone`. Ob sich `canJoinAllSpaces` und `moveToActiveSpace` ausschließen, ist inhaltlich naheliegend, aber nicht belegt (⚠️). Variante zum Testen: `.canJoinAllApplications` (ab macOS 13). Apple empfiehlt es ausdrücklich „for floating windows and system overlays“.
3. **Panel:** `NSPanel`-Subklasse mit `styleMask: [.borderless, .nonactivatingPanel]`, **bereits im Initializer gesetzt** (nachträgliches Setzen gilt als wirkungslos, ⚠️). Dazu `hidesOnDeactivate = false` (Default bei NSPanel ist `true`), `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false` und `canBecomeMain → false`. `canBecomeKey` beim Eselsohr `true` (für Esc im Ansichtsmodus), beim Board während des Drags egal. Einblenden mit **`orderFrontRegardless()`**, nie mit `makeKeyAndOrderFront`/`NSApp.activate`. Activation-Policy **`.accessory` (LSUIElement=1)** wird empfohlen. Laut einem Bericht (macOS 26) ist sie für die Fullscreen-Sichtbarkeit nicht zwingend, solange das Panel `.nonactivatingPanel` hat.
4. **Drag-Übergang:** Dass ein Fenster, das *während* einer laufenden Drag-Session erscheint oder wächst, sofort `draggingEntered` bekommt, ist **nicht belegt** (⚠️). Das ist das größte offene Risiko. Bevorzugter Entwurf: **zwei Panels**. Das Board-Panel wird beim Expand sofort in voller Endgröße und über dem Eselsohr per `orderFrontRegardless()` eingeblendet. Die 200-ms-Aufblätter-Animation läuft nur im Layer (Maske/Scale), **nicht** über `setFrame`. Ein dauerhaft bildschirmgroßes, transparentes Fenster ist zu vermeiden, weil das Durchklicken transparenter Bereiche nachweislich regressionsanfällig ist (macOS 14, 26.3 RC).
5. **Berechtigungen:** Für Panels, Level, Spaces und Drop-Ziel ist **keine** Accessibility-, Input-Monitoring- oder Screen-Recording-Berechtigung nötig. Belegt ist das nur indirekt (⚠️ für den Negativnachweis). **`sharingType = .none` ist laut Apple ein Legacy-Wert und wird nicht mehr zuverlässig beachtet.** Für „Ausblenden“ also `orderOut(_:)` verwenden, nicht `sharingType`.

## Details

### 1. Window-Level

**Offizielle Ordnung und Zahlenwerte.**
- `NSWindow.Level` ist laut Apple „mapped … to corresponding elements in CGWindowLevelKey“. Ebenfalls laut Apple gilt: „even the bottom window in a level will obscure the top window of the next level down“ [A1].
- Die Zahlenwerte stehen nicht in der Online-Doku, sondern in `CGWindowLevel.h` (Mirror des macOS-11.3-SDK, inoffiziell, alt) [G13]: Normal 0, Floating 3, TornOffMenu 3, ModalPanel 8, Utility 19, Dock 20, **MainMenu 24**, **Status 25**, **PopUpMenu 101**, Overlay 102, Help 200, **Dragging 500**, **ScreenSaver 1000**, AssistiveTechHigh 1500, Maximum = INT32_MAX−16, Cursor = Maximum−1.
- Dass die Werte auf macOS 14/15/26 unverändert sind: ⚠️ VERIFIZIEREN (zur Laufzeit per `NSWindow.Level.statusBar.rawValue` ausgeben).
- `CGWindowLevelForKey(_:)` ist laut Apple „not recommended for use in applications“ [A2]. Also besser die `NSWindow.Level`-Konstanten verwenden, ggf. `NSWindow.Level(rawValue:)` mit Offset (wie `.mainMenu + 3` bei boring.notch [G3]).

**Welche Level sind über Fullscreen-Spaces sichtbar?** Die Belege sprechen dafür, dass das Level dafür **nicht** entscheidet:
- Apple-Forum 2015 (El Capitan, alt): Ein `NSWindow` (kein Panel) auf `kCGMaximumWindowLevel` mit `[.canJoinAllSpaces, .fullScreenAuxiliary]` war auf allen Spaces sichtbar, **aber nicht über Fullscreen-Apps** [F1].
- tinkertanker/classroom-widgets PR #162 (21.09.2026, laut PR auf macOS 26 manuell getestet): Ein `.floating`-`NSPanel` mit `[.canJoinAllSpaces, .fullScreenAuxiliary]` in einer `.regular`-App erschien **nicht** über fremden Fullscreen-Spaces. Erst `.nonactivatingPanel` in der Style-Mask behob das, bei weiterhin `.floating` und `.regular` [G9].
- SpeakType (Swift-Version, Code gelesen): `NSPanel` mit `[.nonactivatingPanel, .fullSizeContentView, .borderless]`, `level = .floating`, `[.canJoinAllSpaces, .fullScreenAuxiliary]` [G2]. Der PR #142 desselben Projekts (Tauri-Neubau, getestet laut PR auf macOS 26.6.2) hebt dagegen auf `NSStatusWindowLevel` an. Begründung dort: Floating sei „insufficient for full-screen app visibility“. Außerdem: „a plain `NSWindow` of an inactive app is kept out whatever its flags say“ [G1].
- **Widerspruch:** Bei SpeakType-Swift und classroom-widgets reicht `.floating`, laut SpeakType-PR #142 nicht. Ursache unklar, möglicherweise Tauri-spezifisch. → Testplan T2.
- opentypeless Issue #128 (macOS 14.8): „Only NSPanel is allowed to be drawn over full screen windows.“ Der Vorschlag dort: `NSMainMenuWindowLevel + 1`, nonactivating, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true` [G10]. Das ist ein Issue-Vorschlag, keine verifizierte Lösung.

**Nebenwirkungen je Level** (abgeleitet aus der Level-Ordnung; das Verhalten der System-UI ist nicht dokumentiert):

| Level | Wert | Über Menüleiste? | Über Pop-up-/Kontextmenüs? | Über Drag-Bild? | Bewertung |
|---|---|---|---|---|---|
| `.floating` | 3 | nein | nein | nein | reicht laut [G9][G2] für Fullscreen, liegt aber unter der Menüleiste und unter Utility/Dock-Level |
| `.mainMenu + 1` / `.statusBar` | 25 | ja (bei Überlappung) | nein | nein | **Empfehlung** |
| `.popUpMenu` | 101 | ja | gleichauf/darüber, verdeckt ggf. Menüs | nein | unnötig hoch |
| `.screenSaver` | 1000 | ja | ja | **vermutlich ja**, weil > Dragging 500 (⚠️) | für das Board ungeeignet |
| `CGShieldingWindowLevel()` / Maximum | sehr hoch | – | – | – | Apple rät ab („not recommended“) [A3]; über Max-Level kein Fullscreen-Gewinn [F1] |

- Mitteilungsbanner, Screenshot-UI (Thumbnail, ⌘⇧5-Leiste), Mission Control und Control Center: Die Levels dieser Systemprozesse sind **nicht dokumentiert** (⚠️ VERIFIZIEREN).
- Dass Pop-up-Menüs auf `kCGPopUpMenuWindowLevel` (101) liegen, folgt nur aus dem Namen der Konstante (⚠️).
- Dass das Drag-Bild auf `kCGDraggingWindowLevel` (500) gezeichnet wird, folgt ebenfalls nur aus dem Namen (⚠️). Die Doku sagt nur „The level for a window being dragged“ [A4].
- Bei `.statusBar` liegt das Eselsohr ohnehin knapp *unter* der Menüleiste und überlappt sie nicht. Relevant wird das nur, wenn die Menüleiste im Fullscreen-Space von oben einfährt.
- **Board über der Menüleiste?** Ob das Board die Menüleiste überdecken soll (`screen.frame`) oder nicht (`visibleFrame`), ist eine Designentscheidung. Bei `.statusBar` überdeckt ein `frame`-großes Board die Menüleiste.
- **Displays, die von einer App „captured“ sind** (`CGDisplayCapture`, z. B. manche Spiele oder Player): Dort liegt ein Shield-Window darüber, und das Eselsohr ist nicht sichtbar. Apple rät ausdrücklich davon ab, Fenster darüber zu legen [A3][A5]. Ob DaVinci Resolve in irgendeinem Modus capturet, ist unbekannt (⚠️, Testplan T3).

### 2. Collection-Behavior

Apple-Doku zu den einzelnen Flags [A6–A12]:
- `canJoinAllSpaces`: „The window can appear in all spaces. The menu bar behaves this way.“
- `fullScreenAuxiliary`: „The window displays on the same space as the full screen window.“
- `stationary`: „Mission Control doesn’t affect the window, so it stays visible and stationary, like the desktop window.“
- `transient`: „floats in Spaces and hides in Mission Control“. Default, wenn das Level ≠ normal ist.
- `ignoresCycle`: nicht Teil von „Cycle Through Windows“.
- `moveToActiveSpace`: „When the window becomes active, move it to the active space instead of switching spaces.“
- **`canJoinAllApplications`** (macOS 13+): „don’t participate in Stage Manager layout but can join the windows of other apps in full screen spaces when eligible. **Use this collection behavior for floating windows and system overlays.**“ Laut Doku schließt es `primary`/`auxiliary` aus [A12].

Ausschlüsse laut `NSWindow.h`-Kommentaren (SDK-11.3-Mirror [G14]; die aktuelle Online-Doku sagt das nur für `primary`/`auxiliary`/`canJoinAllApplications` [A6]):
- höchstens eines von `Managed`/`Transient`/`Stationary`,
- höchstens eines von `ParticipatesInCycle`/`IgnoresCycle`,
- höchstens eines von `FullScreenPrimary`/`FullScreenAuxiliary`/`FullScreenNone`,
- höchstens eines von `FullScreenAllowsTiling`/`DisallowsTiling` („or an assertion will be raised“).
- **`canJoinAllSpaces` vs. `moveToActiveSpace`:** Im Header steht dazu kein Kommentar. Logisch widersprechen sich die beiden, und eine Exception wird oft behauptet, ist hier aber nicht belegt (⚠️ VERIFIZIEREN). Für Dropboard ist `moveToActiveSpace` ohnehin falsch, weil das Eselsohr *dauerhaft* auf jedem Space sein soll.
- Verhältnis von `canJoinAllApplications` zu `fullScreenAuxiliary`: Die Doku nennt `fullScreen*` die „more specific behavior just for full screen mode“ [A8]. Ob die Kombination erlaubt ist oder etwas ändert, ist ungeklärt (⚠️, T2-Variante).

Verifizierte Beispiele (Code gelesen):
- **boring.notch**, `BoringNotchWindow`: `NSPanel`, `[.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]`, `level = .mainMenu + 3`, `isFloatingPanel = true`, `canBecomeKey/Main → false` [G3]. Die Style-Mask beim Erzeugen ist `[.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]`, eingeblendet wird mit `orderFrontRegardless()` [G5]. **Zusätzlich** steckt boring.notch die Fenster per **privater CGS-API** in einen eigenen Space mit Max-Level (`CGSSpaceCreate`, `CGSSpaceSetAbsoluteLevel`, `CGSAddWindowsToSpaces`) [G6][G7]. Damit ist nicht belegt, dass bei boring.notch die öffentliche API allein die Fullscreen-Sichtbarkeit trägt. Private API ist für Dropboard keine Option (App-Review/Stabilität); sie wird nur als letzter Ausweg vermerkt.
- **NotchDrop** (Lakr233): **`NSWindow`** (kein Panel), `[.borderless, .fullSizeContentView]`, `[.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]`, `level = .statusBar + 8`, App per `NSApp.setActivationPolicy(.accessory)` [G11][G12]. Ob NotchDrop über fremden Fullscreen-Spaces erscheint, ist nicht belegt (⚠️). Falls ja, deutet das darauf hin, dass `.accessory` ein `NSWindow` ebenfalls zulässt.
- **DynamicNotchKit**: `NSPanel`, `level = .screenSaver`, `[.canJoinAllSpaces, .stationary]` ohne `fullScreenAuxiliary` [G8]. Es ist kein Drop-Ziel, deshalb ist der hohe Level dort unproblematisch.

**LSUIElement / `.accessory`:**
- Apple-Doku: `.accessory` „doesn’t appear in the Dock and doesn’t have a menu bar … corresponds to … `LSUIElement` … `1`“ [A13].
- Belege für die Wirkung auf Fullscreen: Im Apple-Forum (ca. 2017, alt) half `LSUIElement` einem Statusmenü-Popover über Fullscreen-Apps. Quinn (DTS) empfahl, Statusitems in eine separate LSUIElement-App auszulagern [F5]. Ein Apple-Forum-Post von 2016 berichtet, dass LSUIElement-Statusfenster über Fullscreen-Safari-Videos gezeichnet werden [F4].
- Gegenbeleg zur Notwendigkeit: classroom-widgets (macOS 26) bleibt `.regular` und funktioniert mit `.nonactivatingPanel` [G9].
- **Empfehlung:** `.accessory`/`LSUIElement=1`, weil es zum Produkt passt (kein Dock-Icon; Einstellungen später über einen Menüleisten-Schalter) und eine zusätzliche Sicherheitsmarge schafft. → T2 prüft beide Policies.

**Ein Panel pro Bildschirm:** Ein Fenster liegt immer auf genau einem Bildschirm. Ein Eselsohr pro Bildschirm bedeutet also ein Panel pro `NSScreen`.

### 3. NSPanel-Konfiguration und Fokus

| Eigenschaft | Wert | Beleg |
|---|---|---|
| Klasse | `NSPanel`-Subklasse | `.nonactivatingPanel` ist „Valid only for an instance of NSPanel or its subclasses; not valid for a window“ [A14]. Electron meldet auf `NSWindow` „NSWindow does not support nonactivating panel styleMask 0x80“ [G15] |
| `styleMask` | `[.borderless, .nonactivatingPanel]` **im `init`** | `.nonactivatingPanel`: „does not activate the owning app“ [A15]. Dass ein *nachträgliches* Setzen wirkungslos ist, behaupten ältere cocoa-dev-Threads; Quelle nicht abrufbar (⚠️) |
| `hidesOnDeactivate` | `false` | „default value for NSPanel is true“ [A16] |
| `isFloatingPanel` | weglassen oder **vor** `level` setzen | Die Doku nennt als Bedingung u. a. „hides when the app is deactivated“ [A17], was hier nicht zutrifft. Dass das Setzen den Level auf `.floating` zurücksetzt, ist nicht belegt (⚠️). Deshalb `level` zuletzt setzen |
| `level` | `.statusBar` | s. o. |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` | s. o. |
| `isOpaque` / `backgroundColor` / `hasShadow` | `false` / `.clear` / `false` | Apple-Doku [A18]. Die Kombination ist in allen gelesenen Beispielen gleich [G2][G3][G11] |
| `canBecomeKey` | Eselsohr: Override `true` (Ansichtsmodus, Esc). Board: `true` im Ansichtsmodus, im Drag nicht nötig | Borderless kann ohne Override nicht key werden [A19][A20] |
| `canBecomeMain` | `false` | Ein Panel kann laut Doku ohnehin nicht main werden [A21] |
| `becomesKeyOnlyIfNeeded` | `true` (optional) | Bei nonactivating Panels wird das Panel nur key, „if the hit view returns true from needsPanelToBecomeKey“ [A22][A23] |
| `ignoresMouseEvents` | **`false`** auf allen Drop-Zielen | Doku: „transparent to mouse events“ [A24]. Dass ein solches Fenster dann auch kein Drop-Ziel ist, ist plausibel, aber nicht belegt (⚠️) |
| `isMovable` | `false` | „A nonmovable window will not be moved or resized by the system in response to a display reconfiguration“ [A25] |
| `animationBehavior` | `.none` | Die eigene Realtime-Animation soll nicht mit der AppKit-Automatik kollidieren [A26] |
| Einblenden | `orderFrontRegardless()` | „Moves the window to the front of its level, even if its application isn’t active, **without changing either the key window or the main window**“ [A27] |
| Drop-Registrierung | `registerForDraggedTypes(_:)` auf Fenster oder View | „automatically makes it a candidate destination“ [A28][A29] |

**Ursprungs-App bleibt aktiv:**
- `.nonactivatingPanel` plus `orderFrontRegardless()` plus kein Aufruf von `NSApp.activate()`/`makeKeyAndOrderFront` ergibt kein Aktivieren.
- SpeakType-PR #142 beschreibt genau diese Falle: Der Aufruf `makeKeyAndOrderFront:` gefolgt von `activateIgnoringOtherApps:` „switched the user to whichever Space the main window was on and dismissed the full screen app’s menu bar“ [G1].
- classroom-widgets: Klick auf ein nonactivating Panel über einer Fullscreen-App „no longer activates … and yanks the user back“ [G9].
- Dass die Annahme eines **Drops** selbst die Ziel-App nicht aktiviert, ist nicht dokumentiert (⚠️, T5). Seit macOS 14 ist Aktivierung kooperativ, `activate()` ist nur eine Anfrage [A30]. Dropboard soll sie nie stellen.

### 4. Drag-Session-Übergang (Eselsohr → Board)

Belegt ist:
- `draggingEntered` wird gesendet, wenn der Cursor „enters the destination’s bounds rectangle (view) or its frame rectangle (window)“ [A31].
- „Only one destination at a time receives a sequence of draggingUpdated messages. If the mouse pointer is within the bounds of two overlapping views that are both valid destinations, the uppermost view receives these messages“ [A32].
- `draggingExited` gilt für das Verlassen von Bounds bzw. Frame [A33].
- Bei Spring-Loading gilt: „the view beneath the cursor during a drag receives priority“ [A34].
- Der Apple-Leitfaden „Dragging Destinations“ (Stand 2012) sagt dazu nur allgemein „As the image is dragged into the destination’s boundaries, the destination is sent a draggingEntered: message“ [A35].
- Hover-Erkennung **nicht** über `NSTrackingArea` mit `.enabledDuringMouseDrag` lösen. Seit macOS 13.2 kommen dabei keine Enter/Exit-Events während eines Drags an (FB11973492, 2025 noch offen). Workaround laut Thread: `registerForDraggedTypes` plus `draggingEntered`/`draggingExited` [F6]. Das passt zum Briefing.

**Nicht belegt** (keine Apple-Aussage, kein gelesener Fremdcode, der genau das tut):
- ob ein Fenster, das **während** einer laufenden Drag-Session neu eingeblendet wird (`orderFrontRegardless`), beim nächsten Mausereignis als Ziel erkannt wird und `draggingEntered` erhält,
- ob ein Fenster, das per `setFrame` unter dem Cursor wächst, neue Bereiche sofort als Drop-Fläche hat.

Indizien:
- Finder-Spring-Loading öffnet Fenster während eines Drags, die danach Drop-Ziel sind. Das ist Apple-eigenes Verhalten, ohne Doku zum Mechanismus.
- boring.notch und NotchDrop umgehen die Frage. Ihr Fenster hat eine **feste Größe**, nur der SwiftUI-Inhalt wächst [G2][G5][G11]. boring.notch erkennt das Hineinziehen per globalem Maus-Monitor plus `NSPasteboard(name: .drag).changeCount` [G4], nicht über `draggingEntered`.

Abwägung:

| Variante | Pro | Contra |
|---|---|---|
| **A: Zwei Panels.** Board wird in Endgröße über dem Eselsohr eingeblendet; Animation nur im Layer | Ein `orderFront` statt 12 Frame-Änderungen in 200 ms; klarer Übergang Eselsohr-`draggingExited` → Board-`draggingEntered` | Ob das Board-Ziel sofort greift, ist ⚠️ |
| **B: Ein Panel, `setFrame` wächst** | Die Drag-Session bleibt beim selben Ziel-Fenster | `setFrame` pro Animationsframe auf einem Bildschirm-großen Fenster belastet den Window-Server (Ruckeln möglich). Hit-Region während des Wachsens ⚠️ |
| **C: Ein dauerhaft bildschirmgroßes, transparentes Panel** (wie NotchDrop/boring.notch, nur größer) | Ziel steht immer fest | Durchklicken transparenter Pixel ist nicht dokumentiert und regressionsanfällig: Sonoma verlor Click-through nach Redraws [F9]; macOS 26.3 RC fing Klicks im ganzen transparenten Fenster ab, „any third-party app that uses full-screen overlay windows blocks system interactions“ (in 26.3 final behoben, laut einem Nutzer in 26.4 beta wieder da) [F8]. **Nicht verwenden** |

**Empfehlung:** Variante A als Standard im Spike, B als Fallback, beide in T4 messen. Zusätzlich das Board-Panel bei App-Start einmal erzeugen und sofort wieder `orderOut`, damit beim Expand keine Fenster-Erzeugungskosten anfallen (Annahme, ⚠️).

### 5. Mehrere Monitore, Menüleiste, Notch

- **Board-Bildschirm:** Am einfachsten der Bildschirm des Eselsohr-Panels, das `draggingEntered` erhalten hat (`window.screen`). Ein Drag-Hover auf dem Eselsohr findet zwangsläufig auf dessen Bildschirm statt.
- Allgemein: `NSEvent.mouseLocation` liefert Bildschirmkoordinaten „regardless of the current event“ [A36]; dazu `NSScreen.screens` nach `frame.contains` filtern [A37].
- `NSScreen.main` ist **nicht** geeignet. Es ist „the screen containing the window that is currently receiving keyboard events“ [A38], also der Bildschirm der Ursprungs-App.
- `NSScreen.screens` nicht cachen, stattdessen auf `NSApplication.didChangeScreenParametersNotification` reagieren [A37][A39].
- **„Displays have separate Spaces“:** abfragbar über `NSScreen.screensHaveSeparateSpaces` [A40]. Wie sich `canJoinAllSpaces`-Panels verhalten, wenn die Option aus ist und eine App auf einem Bildschirm im Vollbild läuft, ist nicht dokumentiert (⚠️, T6).
- **Menüleiste und Notch:**
  - `visibleFrame` schließt Dock und Menüleiste aus und soll nicht gecacht werden [A41]. Die Menüleistenhöhe ergibt sich damit als `frame.maxY − visibleFrame.maxY`, aber nur, wenn das Dock nicht oben liegt und die Menüleiste nicht automatisch ausgeblendet wird (⚠️).
  - `safeAreaInsets` (macOS 12+) gibt den von der Kameraaussparung verdeckten Bereich an [A42]. `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` liefern die nutzbaren Flächen links und rechts der Notch [A43][A44].
  - In einem **fremden Fullscreen-Space** ist die Menüleiste ausgeblendet. Was `visibleFrame` dann für unseren (inaktiven) Prozess liefert, ist nicht belegt (⚠️, T6).
  - Empfehlung: den Abstand von oben aus `max(safeAreaInsets.top, frame.maxY − visibleFrame.maxY)` plus Einrückung berechnen und in T6 prüfen.
- Das Eselsohr bei `activeSpaceDidChangeNotification` [A45] und `NSWindow.didChangeScreenNotification` [A46] neu positionieren. boring.notch macht das für die Bildschirmzuordnung genauso [G5].

### 6. Sichtbarkeit in Screenshots (`sharingType`)

- Aktuelle Apple-Doku: `NSWindow.SharingType.none` ist „**A legacy constant that macOS no longer uses.** … Don’t use this value to hide or omit content from being captured. Instead, use FairPlay Streaming“ [A47].
- Der alte Header beschrieb die Wirkung noch als „content cannot be captured“ [G14].
- Berichte:
  - Laut Apple-Forum (Ed Ford, DTS) verhindert `.none` Screenshots, aber keine Bildschirmaufnahme. Empfohlen wird Automatic Assessment Configuration [F7].
  - Im ScreenCaptureKit-Sample war ein `.none`-Fenster zunächst unsichtbar und tauchte nach einem Filterwechsel doch auf (Nov. 2025, FB21115847) [F10].
  - Ein Tauri-Issue berichtet, dass ScreenCaptureKit das Flag ab macOS 15 ignoriert [G16] (Sekundärquelle, ohne Apple-Link).
- **Fazit:** Für die spätere Ausblenden-Funktion nicht auf `sharingType` setzen, sondern das Panel per `orderOut(_:)` wirklich ausblenden (bzw. `alphaValue = 0` plus `ignoresMouseEvents`, ⚠️ ob dann noch erfasst). Das ist auch das, was das Briefing will (Hotkey/Menüleisten-Schalter).
- boring.notch schaltet `sharingType` je nach Einstellung zwischen `.none` und `.readWrite` um [G5]. Ob das bei boring.notch auf macOS 15+ wirkt, ist nicht belegt.

### 7. Berechtigungen

- Für Fenster, Level, Collection-Behavior, `orderFrontRegardless` und `NSDraggingDestination` erwähnt keine der abgerufenen Apple-Seiten eine Berechtigung [A1–A35]. Ein formaler Negativbeleg ist das nicht (⚠️).
- `addGlobalMonitorForEvents`: nur **Key-Events** brauchen Accessibility, Maus-Events nicht [A48]. Dropboard braucht laut Briefing gar keinen globalen Monitor.
- Achtung für später: Ein Ausblenden-Hotkey über einen globalen Key-Monitor *würde* Accessibility erfordern [A48]. Alternativen (z. B. Carbon `RegisterEventHotKey`) gehören nicht zu diesem Report (⚠️).
- Screen Recording ist nur für Bildschirminhalte anderer Apps nötig (ScreenCaptureKit). Dropboard liest keine.
- Den Inhalt des Drops liefert die Drag-Pasteboard. Sandbox- und File-Promise-Fragen behandelt der Report zum Screenshot-Thumbnail.

## Offene Punkte

1. **Drag-Übergang** zwischen zwei Fenstern bzw. in ein wachsendes Fenster während einer laufenden Session: Es gibt keine Doku und kein gelesenes Beispiel. Größtes Risiko für die Kern-Interaktion. (T4)
2. **`.floating` vs. `.statusBar`** für die Fullscreen-Sichtbarkeit: Die Belege widersprechen sich ([G9][G2] vs. [G1]). (T2)
3. **Activation-Policy:** Ist `.accessory` nötig oder reicht `.regular` + `.nonactivatingPanel` auf macOS 14/15/26? (T2)
4. **`canJoinAllApplications`** (macOS 13+): Ändert es etwas bei Fullscreen und Stage Manager, und ist es mit `fullScreenAuxiliary` kombinierbar? (T2, T7)
5. **DaVinci Resolve:** Ist der Resolve-Vollbildmodus ein nativer Fullscreen-Space oder ein eigenes Vollbildfenster bzw. eine Display-Capture? Davon hängt ab, ob das Eselsohr sichtbar ist. (T3)
6. **Level der System-UI** (Mitteilungsbanner, Screenshot-Thumbnail, ⌘⇧5-Leiste, Control Center, Mission Control) relativ zu `.statusBar`. (T8)
7. **Menüleistenhöhe/`visibleFrame`** in fremden Fullscreen-Spaces und mit automatisch ausgeblendeter Menüleiste; Verhalten mit „Displays have separate Spaces“ aus. (T6)
8. **Fokus nach dem Drop:** Bleibt die Ursprungs-App wirklich aktiv und key? (T5)
9. `sharingType`-Wirkung auf macOS 14/15/26 nur für die Doku; für das Produkt ist `orderOut` geplant. (T9)
10. Stabilität des Durchklickens transparenter Bereiche (relevant nur, wenn doch Variante C), Regressionen in 26.3 RC und 26.4 beta [F8].

## ⚠️ VERIFIZIEREN

1. Die Zahlenwerte der Window-Levels (aus dem SDK-11.3-Header-Mirror) gelten unverändert auf macOS 14/15/26.
2. Pop-up- und Kontextmenüs liegen auf `kCGPopUpMenuWindowLevel` (101), über `.statusBar`.
3. Das Drag-Bild wird auf `kCGDraggingWindowLevel` (500) gezeichnet; ein Board auf `.screenSaver` (1000) würde es verdecken.
4. Die Levels von Mitteilungsbannern, Screenshot-UI, Control Center und Mission Control sind unbekannt.
5. Ob DaVinci Resolve im Vollbild einen nativen Fullscreen-Space nutzt (oder ein Display capturet).
6. `canJoinAllSpaces` und `moveToActiveSpace` schließen sich aus (Exception?).
7. Ob `canJoinAllApplications` mit `fullScreenAuxiliary` kombinierbar ist und was es bei Fullscreen/Stage Manager ändert.
8. `.nonactivatingPanel` wirkt nur, wenn es im Initializer gesetzt wird (nachträgliches Setzen wirkungslos).
9. Setzen von `isFloatingPanel = true` setzt den Level auf `.floating` zurück.
10. Ein Fenster mit `ignoresMouseEvents = true` ist auch kein Drop-Ziel.
11. Ein während einer laufenden Drag-Session eingeblendetes Panel erhält beim nächsten Mausereignis `draggingEntered` (Variante A).
12. Ein per `setFrame` wachsendes Panel ist sofort in der neuen Fläche Drop-Ziel (Variante B).
13. Vorab erzeugte und per `orderOut` versteckte Board-Panels verkürzen die Expand-Latenz.
14. Ob NotchDrop (`NSWindow` + `.accessory`) tatsächlich über fremden Fullscreen-Spaces sichtbar ist.
15. Verhalten von `canJoinAllSpaces`-Panels bei ausgeschalteter Option „Displays have separate Spaces“.
16. Menüleistenhöhe als `frame.maxY − visibleFrame.maxY` ist korrekt (Dock oben, Auto-Hide, fremder Fullscreen-Space).
17. `visibleFrame` in einem fremden Fullscreen-Space aus Sicht eines inaktiven Prozesses.
18. Annahme eines Drops auf einem nonactivating Panel aktiviert die Ziel-App nicht; die Ursprungs-App bleibt key.
19. `alphaValue = 0` + `ignoresMouseEvents` als Ausblend-Alternative: Ist das Fenster dann aus Screenshots verschwunden?
20. Für alles in diesem Report ist keine TCC-Berechtigung (Accessibility, Input Monitoring, Screen Recording) nötig (Negativnachweis nur indirekt).
21. Ein späterer Ausblenden-Hotkey ohne Accessibility (z. B. Carbon `RegisterEventHotKey`), außerhalb des Scopes.

## Testplan macOS

**Voraussetzungen:**
- Je ein Testlauf auf **macOS 14, 15 und 26** (mindestens 26 und eine ältere).
- Ein Mac mit Notch und ein externer Monitor.
- DaVinci Resolve (kostenlose Version reicht), Safari, TextEdit, Finder.
- Protokoll je Schritt: macOS-Build, Hardware, Ergebnis (ja/nein/Beobachtung), bei Bedarf Bildschirmfoto mit dem iPhone (keine Screenshot-UI, die das Ergebnis verfälscht).
- Testobjekt ist ein Minimal-Spike (Phase 1) mit **Laufzeit-Schaltern** (Menüleisten-Item oder Umgebungsvariablen) für Level, Collection-Behavior, Activation-Policy und Panel-Variante (A/B). Das Panel zeigt Level, Behavior-Rohwert und Fensternummer als Text an und loggt alle `NSDraggingDestination`-Aufrufe mit Zeitstempel (`os_signpost`/`Logger`).

**T1 – Basis-Sichtbarkeit**
- Eselsohr (40 × 40 pt, deckend gefärbt) oben rechts mit Empfehlungskonfiguration starten.
- Prüfen auf: Desktop, zweitem Space, nach Space-Wechsel per Swipe (bleibt es stehen und wandert nicht mit?), in Mission Control (sichtbar mit `.stationary`, verborgen mit `.transient`?), im ⌘-Tab-Umschalter (darf nicht erscheinen) und bei „Cycle Through Windows“ (⌘`).
- Ausgeben: `NSWindow.Level.statusBar.rawValue`, `.popUpMenu`, `.screenSaver` (zu ⚠️1).

**T2 – Fullscreen-Matrix**
- TextEdit, Safari und Resolve je in nativen Vollbild (grüner Button), dann per Swipe in diesen Space wechseln.
- Matrix: Level {`.floating`, `.statusBar`, `.popUpMenu`} × Klasse {`NSPanel` + `.nonactivatingPanel`, `NSPanel` ohne, `NSWindow`} × Policy {`.accessory`, `.regular`} × Behavior {Empfehlung, Empfehlung + `.canJoinAllApplications`, nur `[.canJoinAllSpaces, .fullScreenAuxiliary]`}.
- Je Zelle festhalten: sichtbar ja/nein, sichtbar nach Space-Wechsel ja/nein, Exception oder Konsolen-Warnung.
- Zusatz (⚠️6): `collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace]` setzen → Exception? Konsolenausgabe notieren.
- Zusatz (⚠️8, ⚠️9): `.nonactivatingPanel` erst nach `init` setzen → aktiviert ein Klick die App? `isFloatingPanel = true` nach `level = .statusBar` setzen → `level.rawValue` ausgeben.

**T3 – DaVinci Resolve**
- Resolve (a) per grünem Button im nativen Vollbild, (b) über Workspace → Full Screen Window, (c) mit Cinema Viewer / Viewer-Vollbild (⌘F), (d) mit Ausgabe auf einen zweiten Monitor (Video Clean Feed).
- Je Modus: Ist das Eselsohr sichtbar, und nimmt es einen Drop an (Bild aus dem Finder)?
- Mit `CGWindowListCopyWindowInfo` (eigenes Testtool) Level und Owner des Resolve-Fensters ausgeben. Achtung: Fensternamen erfordern ggf. Screen Recording, das ist ok für das Testtool, nicht für Dropboard.

**T4 – Drag-Übergang (Kernrisiko)**
- Bild aus dem Finder ziehen, über dem Eselsohr verharren (300 ms Delay), dann Expand.
- Variante A: Board-Panel in Endgröße `orderFrontRegardless()` über dem Eselsohr.
- Variante B: Eselsohr-Panel per `setFrame(_:display:)` in 12 Schritten über 200 ms auf Bildschirmgröße.
- Für jede Variante loggen:
  - Kommt `draggingExited` am Eselsohr bzw. `draggingEntered` am Board, und wann genau (ms nach `orderFront`)?
  - Braucht es eine Mausbewegung oder kommt der Aufruf auch bei stillstehender Maus?
  - Welche Operation zeigt der Cursor (Kopieren-Badge)?
  - Klappt der Drop an der Cursorposition? Was passiert beim Loslassen *während* der Animation?
- Wiederholen mit: Screenshot-Thumbnail als Quelle, Safari-Bild als Quelle, Esc während des Drags (kommt `draggingExited`/`draggingEnded`?), Maus verlässt das Board.
- Variante B zusätzlich: CPU des WindowServer-Prozesses in Aktivitätsanzeige/Instruments während der Animation, und ruckelt es?
- Zu ⚠️10: Board mit `ignoresMouseEvents = true` → Drop möglich?
- Zu ⚠️13: Expand-Latenz mit vorab erzeugtem vs. neu erzeugtem Panel (Signpost von `draggingEntered` am Eselsohr bis zum ersten Board-Frame).

**T5 – Fokus**
- Den Test in TextEdit mit blinkendem Cursor und Resolve im Vollbild durchführen.
- Nach Drop auf Eselsohr bzw. Board:
  - `NSWorkspace.shared.frontmostApplication` loggen (per Timer im Spike).
  - Prüfen, ob die Menüleiste noch der Ursprungs-App gehört und ob sofort weitergetippt werden kann.
  - Prüfen, ob ein Space-Wechsel passiert.
- Gegenprobe mit absichtlichem `NSApp.activate()` → muss den Fehler zeigen (Space-Sprung).

**T6 – Bildschirme/Menüleiste**
- Notch-Mac und externer Monitor: Positionierung des Eselsohrs (Abstand Menüleiste, Einrückung) auf beiden Bildschirmen.
- Variieren: „Menüleiste automatisch ein- und ausblenden“ an/aus, Dock oben/links, fremder Fullscreen-Space.
- Je Fall loggen: `frame`, `visibleFrame`, `safeAreaInsets`, `auxiliaryTopRightArea`, `screensHaveSeparateSpaces`.
- „Displays have separate Spaces“ aus (Abmelden nötig) → Fullscreen-App auf Monitor 1, ist das Eselsohr auf Monitor 2 sichtbar und nutzbar?
- Monitor im Betrieb ab- und anstecken → werden die Panels korrekt neu verteilt (`didChangeScreenParametersNotification`)?

**T7 – Stage Manager**
- Stage Manager an: Ist das Eselsohr sichtbar und bleibt es an seinem Platz? Mit und ohne `.canJoinAllApplications`.

**T8 – System-UI-Kollisionen**
- Mitteilung auslösen (`osascript -e 'display notification "x"'`) → liegt das Banner über oder unter dem Eselsohr, wird es verdeckt?
- Weitere Fälle: Kontrollzentrum öffnen, ⌘⇧5 (Leiste und Auswahlrahmen über dem Eselsohr?), ⌘⇧4 und Thumbnail (überlappt bei Ecke unten rechts?), ein Menü der Ursprungs-App aufklappen, das bis zum Eselsohr reicht.
- Dasselbe mit Board offen (Ansichtsmodus).

**T9 – Screenshots**
- Mit `sharingType = .none` (nur zur Doku) und alternativ mit `orderOut`: Ist das Eselsohr in den Screenshots sichtbar?
- Je mit: ⌘⇧3, ⌘⇧4 + Leertaste (Fensterauswahl), ⌘⇧5-Aufnahme, QuickTime-Bildschirmaufnahme, einer ScreenCaptureKit-App (z. B. das Apple-Sample).
- Zusätzlich `alphaValue = 0` testen (⚠️19).

**T10 – Berechtigungen**
- Frischer Benutzer-Account bzw. `tccutil reset All <bundle-id>`, Spike starten, T1–T5 durchspielen.
- Erwartung: kein TCC-Dialog, kein Eintrag unter Datenschutz & Sicherheit → Bedienungshilfen/Eingabeüberwachung/Bildschirmaufnahme.

## Quellen

Apple-Dokumentation (Inhalt jeweils über `https://developer.apple.com/tutorials/data/documentation/<pfad>.json` abgerufen am 2026-10-07):
- [A1] NSWindow.Level – https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct (+ `/floating`, `/statusbar`, `/popupmenu`, `/screensaver`); NSWindow.level – https://developer.apple.com/documentation/appkit/nswindow/level-swift.property
- [A2] CGWindowLevelForKey(_:) – https://developer.apple.com/documentation/coregraphics/cgwindowlevelforkey(_:)
- [A3] CGShieldingWindowLevel() – https://developer.apple.com/documentation/coregraphics/cgshieldingwindowlevel()
- [A4] CGWindowLevelKey (+ `/draggingwindow`, `/overlaywindow`, `/maximumwindow`, `/cursorwindow`, `/assistivetechhighwindow`) – https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey
- [A5] CGDisplayCapture(_:) – https://developer.apple.com/documentation/coregraphics/cgdisplaycapture(_:)
- [A6] NSWindow.CollectionBehavior – https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct ; collectionBehavior – https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.property
- [A7] canJoinAllSpaces – https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces
- [A8] fullScreenAuxiliary / fullScreenPrimary / fullScreenNone / primary / auxiliary / managed – https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary (sowie `/fullscreenprimary`, `/fullscreennone`, `/primary`, `/auxiliary`, `/managed`)
- [A9] stationary – https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary
- [A10] transient – https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/transient
- [A11] ignoresCycle / moveToActiveSpace – https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/ignorescycle , …/movetoactivespace
- [A12] canJoinAllApplications – https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications
- [A13] NSApplication.ActivationPolicy (+ `.accessory`, `.prohibited`) – https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum
- [A14] NSNonactivatingPanelMask – https://developer.apple.com/documentation/appkit/nsnonactivatingpanelmask (auch als `.md`-Variante abgerufen)
- [A15] nonactivatingPanel – https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel
- [A16] hidesOnDeactivate – https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate
- [A17] NSPanel / isFloatingPanel – https://developer.apple.com/documentation/appkit/nspanel , https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel
- [A18] isOpaque / hasShadow – https://developer.apple.com/documentation/appkit/nswindow/isopaque , https://developer.apple.com/documentation/appkit/nswindow/hasshadow
- [A19] canBecomeKey – https://developer.apple.com/documentation/appkit/nswindow/canbecomekey
- [A20] borderless – https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/borderless
- [A21] canBecomeMain – https://developer.apple.com/documentation/appkit/nswindow/canbecomemain
- [A22] becomesKeyOnlyIfNeeded – https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded
- [A23] needsPanelToBecomeKey – https://developer.apple.com/documentation/appkit/nsview/needspaneltobecomekey
- [A24] ignoresMouseEvents – https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents
- [A25] isMovable – https://developer.apple.com/documentation/appkit/nswindow/ismovable
- [A26] animationBehavior – https://developer.apple.com/documentation/appkit/nswindow/animationbehavior-swift.property
- [A27] orderFrontRegardless() – https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless()
- [A28] NSWindow.registerForDraggedTypes(_:) – https://developer.apple.com/documentation/appkit/nswindow/registerfordraggedtypes(_:)
- [A29] NSView.registerForDraggedTypes(_:) – https://developer.apple.com/documentation/appkit/nsview/registerfordraggedtypes(_:)
- [A30] NSApplication.activate() / yieldActivation(to:) – https://developer.apple.com/documentation/appkit/nsapplication/activate() , https://developer.apple.com/documentation/appkit/nsapplication/yieldactivation(to:)
- [A31] draggingEntered(_:) – https://developer.apple.com/documentation/appkit/nsdraggingdestination/draggingentered(_:) ; NSDraggingDestination – https://developer.apple.com/documentation/appkit/nsdraggingdestination
- [A32] draggingUpdated(_:) – https://developer.apple.com/documentation/appkit/nsdraggingdestination/draggingupdated(_:)
- [A33] draggingExited(_:) – https://developer.apple.com/documentation/appkit/nsdraggingdestination/draggingexited(_:) ; performDragOperation(_:) – https://developer.apple.com/documentation/appkit/nsdraggingdestination/performdragoperation(_:)
- [A34] NSSpringLoadingDestination – https://developer.apple.com/documentation/appkit/nsspringloadingdestination
- [A35] Archiv: „Dragging Destinations“ (Drag and Drop Programming Topics, Stand 2012-01-09, **alt**) – https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Concepts/dragdestination.html
- [A36] NSEvent.mouseLocation – https://developer.apple.com/documentation/appkit/nsevent/mouselocation
- [A37] NSScreen.screens / frame – https://developer.apple.com/documentation/appkit/nsscreen/screens , https://developer.apple.com/documentation/appkit/nsscreen/frame
- [A38] NSScreen.main – https://developer.apple.com/documentation/appkit/nsscreen/main
- [A39] didChangeScreenParametersNotification – https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification
- [A40] screensHaveSeparateSpaces – https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces
- [A41] visibleFrame – https://developer.apple.com/documentation/appkit/nsscreen/visibleframe
- [A42] safeAreaInsets – https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets
- [A43] auxiliaryTopLeftArea – https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc
- [A44] auxiliaryTopRightArea – https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytoprightarea-gr2n
- [A45] activeSpaceDidChangeNotification – https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification
- [A46] didChangeScreenNotification – https://developer.apple.com/documentation/appkit/nswindow/didchangescreennotification
- [A47] NSWindow.SharingType / .none / sharingType – https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum , …/sharingtype-swift.enum/none , https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.property
- [A48] addGlobalMonitorForEvents(matching:handler:) – https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
- Ebenfalls abgerufen, ohne tragende Aussage: setFrame(_:display:) / setFrame(_:display:animate:) / setFrameOrigin(_:) („window server limits window position coordinates to ±16,000 and sizes to 10,000“), addChildWindow(_:ordered:), makeKeyAndOrderFront(_:), hudWindow, utilityWindow, fullSizeContentView, SCContentFilter – jeweils unter https://developer.apple.com/documentation/appkit/… bzw. …/screencapturekit/sccontentfilter

Apple Developer Forums:
- [F1] „Window visible on all spaces (including fullscreen apps)“, Nov. 2015/Sep. 2016, **alt** – https://developer.apple.com/forums/thread/26677
- [F2] „Issues making a fullscreen & always on top Window“ – https://developer.apple.com/forums/thread/738308
- [F3] „How to create a QuickTime recording like panel?“, Mai 2025, unbeantwortet – https://developer.apple.com/forums/thread/783576
- [F4] „How to stop LSUIElement app windows from hiding kittens?“, Sep. 2016, **alt** – https://developer.apple.com/forums/thread/63442
- [F5] „menu bar popover doesn't display when in fullscreen“ (Antwort Quinn/DTS), **alt**, Datum nicht ermittelt – https://developer.apple.com/forums/thread/85994
- [F6] „NSTrackingEnabledDuringMouseDrag broken in Ventura“ (FB11973492) – https://developer.apple.com/forums/thread/724087
- [F7] „Screen record restriction in MacOS app“ (Antwort Ed Ford/DTS), Datum nicht ermittelt – https://developer.apple.com/forums/thread/770585
- [F8] macOS 26.3 RC: transparente/borderless Fenster und Maus-Events (FB21879511), Feb. 2026 – https://developer.apple.com/forums/thread/814798
- [F9] „transparent window can't click through in macos sonoma“, Sep. 2023 – https://developer.apple.com/forums/thread/737584
- [F10] „ScreenCaptureKit sample initially omits application with NSWindowSharingType NSWindowSharingNone“ (FB21115847), Nov. 2025 – https://developer.apple.com/forums/thread/808016

GitHub (verifizierte Beispiele, Code gelesen; `main`-Branch, Stand des Abrufs 2026-10-07, nicht gepinnt):
- [G1] karansinghgit/speaktype PR #142 – https://github.com/karansinghgit/speaktype/pull/142
- [G2] speaktype `MiniRecorderWindowController.swift` – https://github.com/karansinghgit/speaktype/blob/main/speaktype/Controllers/MiniRecorderWindowController.swift
- [G3] boring.notch `BoringNotchWindow.swift` – https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/components/Notch/BoringNotchWindow.swift
- [G4] boring.notch `DragDetector.swift` – https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/observers/DragDetector.swift
- [G5] boring.notch `boringNotchApp.swift` und `BoringNotchSkyLightWindow.swift` – https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/boringNotchApp.swift , https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/components/Notch/BoringNotchSkyLightWindow.swift (Info.plist ohne LSUIElement: https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/Info.plist)
- [G6] boring.notch `NotchSpaceManager.swift` – https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/managers/NotchSpaceManager.swift
- [G7] boring.notch `CGSSpace.swift` (private API) – https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/private/CGSSpace.swift
- [G8] MrKai77/DynamicNotchKit `DynamicNotchPanel.swift` – https://github.com/MrKai77/DynamicNotchKit/blob/main/Sources/DynamicNotchKit/Utility/DynamicNotchPanel.swift
- [G9] tinkertanker/classroom-widgets PR #162 (21.09.2026, macOS 26) – https://github.com/tinkertanker/classroom-widgets/pull/162
- [G10] tover0314-w/opentypeless Issue #128 (macOS 14.8) – https://github.com/tover0314-w/opentypeless/issues/128
- [G11] Lakr233/NotchDrop `NotchWindow.swift`, `NotchWindowController.swift`, `NotchViewModel+Events.swift` – https://github.com/Lakr233/NotchDrop/blob/main/NotchDrop/NotchWindow.swift , https://github.com/Lakr233/NotchDrop/blob/main/NotchDrop/NotchWindowController.swift , https://github.com/Lakr233/NotchDrop/blob/main/NotchDrop/NotchViewModel+Events.swift
- [G12] NotchDrop `AppDelegate.swift` (`.accessory`) – https://github.com/Lakr233/NotchDrop/blob/main/NotchDrop/AppDelegate.swift
- [G13] `CGWindowLevel.h` aus macOS-11.3-SDK (inoffizieller Mirror, **alt**) – https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/System/Library/Frameworks/CoreGraphics.framework/Versions/A/Headers/CGWindowLevel.h
- [G14] `NSWindow.h` / `NSPanel.h` aus macOS-11.3-SDK (inoffizieller Mirror, **alt**) – https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSWindow.h , …/NSPanel.h
- [G15] electron/electron Issue #35815 – https://github.com/electron/electron/issues/35815
- [G16] tauri-apps/tauri Issue #14200 (20.09.2025, Sekundärquelle) – https://github.com/tauri-apps/tauri/issues/14200
- Sekundär, nur zur Orientierung: manaflow-ai/cmux Issue #2758 – https://github.com/manaflow-ai/cmux/issues/2758

Nicht abrufbar (Egress-Proxy blockiert, daher nicht verwendet): iterm2.com, lists.apple.com (cocoa-dev-Archiv), cindori.com.
