# Stepped Animation (Stop-Motion) und Realtime-Pfad unter AppKit/Core Animation

> Phase-0-Recherchereport · Stand 2026-10-07 · erstellt im Linux-Container, **nichts davon wurde auf macOS ausgeführt**.
> Apple-Referenzseiten wurden über die JSON-Variante (`https://developer.apple.com/tutorials/data/documentation/<pfad>.json`) abgerufen, weil die normalen Seiten per JavaScript rendern. Die lesbare Variante liegt jeweils unter `https://developer.apple.com/documentation/<pfad>`.

## Ergebnis

**Empfehlung: `CAKeyframeAnimation` mit `calculationMode = .discrete` führt die Animationen aus. Dazu kommt ein reiner, deterministischer „Stop-Motion-Planer“, der das 6-fps-Raster und den Jitter berechnet.** Der „globale Ticker“ ist damit eine logische Uhr bzw. ein Zeitraster und **kein dauerhaft laufender Timer**.

Die Begründung:
- Discrete-Keyframe-Animationen laufen im Render-Server.
- Nach dem Ende entfernen sie sich selbst (`isRemovedOnCompletion` ist standardmäßig `true`). Im Idle bleibt deshalb strukturell nichts übrig, das CPU verbraucht.
- Run-Loop-Modi und ein blockierter Main-Thread haben keinen Einfluss.
- Mehrere Objekte lassen sich über ein gemeinsames `beginTime` auf dasselbe Raster legen.

Damit es nicht zurückspringt, gibt es ein festes Muster: Zuerst wird der **Model-Wert auf den Endzustand** gesetzt, und zwar in einer Transaktion mit `CATransaction.setDisableActions(true)`. Danach kommt die discrete-Animation mit expliziten Werten dazu. **Nicht** `fillMode = .forwards` mit `isRemovedOnCompletion = false` verwenden.

Bei `.discrete` gilt: **`keyTimes` hat ein Element mehr als `values`**, das erste ist 0, das letzte 1. Der letzte Wert bleibt bis zum Ende der Animation stehen.

Ein Ticker (`NSView.displayLink(target:selector:)`, ab macOS 14) bleibt nur als Fallback, z. B. für Nicht-Layer-Eigenschaften. Er läuft dann nur bei Bedarf und wird bei leerer Queue invalidiert. `CVDisplayLink`-Erzeugung ist seit macOS 15 deprecated.

Für den Realtime-Pfad wird ein explizites `CABasicAnimation` (linear/easeOut, kein Spring) auf einem selbst verwalteten Layer direkt in `draggingEntered(_:)` gestartet. Der Commit erfolgt automatisch am Ende des Run-Loop-Durchlaufs, auch während eines Drags.

## Details

### 1. `CAKeyframeAnimation` mit `.discrete`: Semantik

- **Zählregel:** Für `.discrete` „require one less element in the `values` array than the `keyTimes` array. Each `value / keyTime` pair represents the value from the specified time until the next keyframe.“ Apples Beispiel nutzt `keyTimes = [0, 0.25, 0.5, 0.75, 1]` und `values = [310, 60, 120, 60]`. Dazu heißt es: „The value of `position.y` will remain at `60` until the animation completes.“ Quelle: Apple-Doku `CAAnimationCalculationMode.discrete`.
- **`keyTimes`-Regeln für discrete:** „the first value in the array must be `0.0` and the last value must be `1.0`. The array should have one more entry than appears in the values array.“ Außerdem: „If the values in this array are invalid or inappropriate for the current calculation mode, they are ignored.“ Was danach passiert, ist undokumentiert. Bei falscher Anzahl werden die `keyTimes` also stillschweigend verworfen, und die Verteilung ist dann vermutlich gleichmäßig. → ⚠️ VERIFIZIEREN (V1). Quelle: `keyTimes`.
- **Kein Easing:** Discrete „cause[s] the animated property to jump from one keyframe value to the next without any interpolation. This calculation mode uses the values in the keyTimes property but ignores the timingFunctions property.“ Quelle: Core Animation Programming Guide, „Creating Basic Animations“. `values`: „Values between keyframes are created using interpolation, unless the calculation mode is set to discrete.“
- **Default:** `calculationMode` steht standardmäßig auf `.linear`. Man muss also explizit `.discrete` setzen. Quelle: `calculationMode`.
- **Rechenbeispiel Drop (2 Frames à 1/6 s):** `values = [groß, final]`, `keyTimes = [0, 0.5, 1]`, `duration = 2/6 s ≈ 0,333 s`. Es geht auch kürzer: `values = [groß]`, `keyTimes = [0, 1]`, `duration = 1/6 s`. Der Model-Wert ist bereits `final`. Nach dem Entfernen der Animation zeigt der Layer den Model-Wert, und genau das ist Frame 2. Der zweite Frame „kostet“ dann keine Animationszeit, sondern ist einfach der Ruhezustand. Die Unterschiede zur gleichmäßigen Taktung müssen im Test angeschaut werden (T1).
- **`duration`:** Standardwert 0 (`CAMediaTiming.duration`). Laut `add(_:forKey:)` gilt: „If the `duration` property of the animation is zero or negative, the duration is changed to the current value of the `kCATransactionAnimationDuration` transaction property (if set) or to the default value of `0.25` seconds.“ Deshalb muss `duration` immer explizit gesetzt werden.
- **`fillMode` / `isRemovedOnCompletion`:**
  - `isRemovedOnCompletion` ist standardmäßig `true`, d. h. die Animation wird „removed from the target layer’s animations once its active duration has passed“.
  - `fillMode` ist standardmäßig `.removed` („removed from the presentation when the animation is completed“).
  - `.forwards` bedeutet „remains visible in its final state“.
  - `.backwards` bedeutet „clamps values before zero to zero“.
  - `.both` clamps an beiden Enden.
  - Quellen: `isRemovedOnCompletion`, `fillMode`, `CAMediaTimingFillMode`.
- **Model vs. Presentation, Zurückspringen vermeiden:** „an explicit animation does not modify the data in the layer tree … At the end of the animation, Core Animation removes the animation object from the layer and redraws the layer using its current data values. If you want the changes from an explicit animation to be permanent, you must also update the layer’s property“ (Guide, Listing 3-2 mit dem Kommentar „Change the actual data value in the layer to the final value“). Der Presentation-Tree enthält „the in-flight values“, der Layer-Tree „always reflects the last value set by your code and is equivalent to the final state of the animation“ (Guide, „Core Animation Basics“). Daraus folgt dieses Muster:
  1. Transaktion mit `setDisableActions(true)` beginnen.
  2. Model-Wert auf den Endzustand setzen.
  3. `CAKeyframeAnimation` mit expliziten `values` hinzufügen, beginnend beim Startwert. Der Guide empfiehlt ausdrücklich, bei expliziten Animationen den Startwert immer anzugeben.
  4. Commit.

  Nach dem Ende bleibt nichts mehr am Layer hängen, und es gibt keinen Unterschied zwischen Model und Presentation. `.forwards` zusammen mit `isRemovedOnCompletion = false` würde die Animation dauerhaft am Layer belassen und Model und Anzeige auseinanderlaufen lassen. Ob das zusätzlich Render-Server-Arbeit im Idle verursacht, ist nicht belegt → ⚠️ VERIFIZIEREN (V2).
- **Verzögerter Start / gemeinsames Raster:** „Use the beginTime property to set the start time of an animation“. Die lokale Zeit eines Layers erhält man mit `convertTime(CACurrentMediaTime(), from: nil)` (Guide, „Advanced Animation Tricks“, Listing 5-3; Doku `convertTime(_:from:)`, `CACurrentMediaTime()`). Liegt `beginTime` in der Zukunft und ist der Model-Wert schon final, zeigt der Layer bis zum Start den Endzustand. Abhilfe ist `fillMode = .backwards`, dann wird bis zum Start der erste Keyframe gezeigt. Dass mehrere Layer mit identischem `beginTime` exakt auf demselben Display-Frame umschalten, ist plausibel, aber nicht dokumentiert → ⚠️ VERIFIZIEREN (V3).
- **Position und Rotation gleichzeitig:** Entweder keyPath `transform` mit einem Array aus `NSValue(caTransform3D:)` („Animating this property causes the keyframe animation to apply each transform matrix to the layer in turn“, Guide), oder zwei discrete-Animationen (`position`, `transform.rotation.z`) mit identischen `keyTimes` in einer `CAAnimationGroup` („Timing and duration values applied to the group override those same values in the individual animation objects“, Guide). Ob Sub-KeyPaths wie `transform.rotation.z` auf macOS identisch funktionieren, ist hier nicht belegt → ⚠️ VERIFIZIEREN (V4).
- **Jitter additiv:** Mit `isAdditive = true` wird der Animationswert „added to the current render tree value“ (Doku `isAdditive`). Der Jitter lässt sich also als reine Offset-Animation über den Model-Wert legen. Das ist optional und vereinfacht den Planer, weil er nur Deltas liefert.

### 2. Ticker-Alternativen vs. `.discrete`

| Mechanismus | Belegtes Verhalten | Bewertung für Dropboard |
|---|---|---|
| `Timer` | „A timer is not a real-time mechanism … if a timer’s firing time occurs during a long run loop callout or while the run loop is in a mode that isn’t monitoring the timer, the timer doesn’t fire until the next time …“. Ein wiederholender Timer plant „based on the scheduled firing time … to avoid drift“. `tolerance` ist standardmäßig 0, und das System „reserves the right to apply a small amount of tolerance“. Run-Loop-Modus `.eventTracking` = „set when tracking events modally, such as a mouse-dragging loop“, `.common` = Pseudo-Modus für alle Common-Modes. | Drift-frei, aber nicht vsync-synchron. Ein Main-Thread-Hänger verschiebt Frames. Muss in `.common` laufen. Für das 6-fps-Raster brauchbar, aber schlechter als CA. |
| `DispatchSourceTimer` | Erzeugt per `DispatchSource.makeTimerSource(flags:queue:)`, „initially inactive … call its activate()“. Planung mit `schedule(deadline:repeating:leeway:)`. | Unabhängig von Run-Loop-Modi, aber UI-Updates müssen trotzdem auf den Main-Thread. Keine Vorteile gegenüber CA. |
| `CVDisplayLink` | `CVDisplayLinkCreateWithActiveCGDisplays` / `…WithCGDisplay` sind **deprecated ab macOS 15.0**: „use NSView.displayLink(target:selector:), NSWindow.displayLink(target:selector:), or NSScreen.displayLink(target:selector:)“. | Nicht verwenden. |
| `NSView.displayLink(target:selector:)` → `CADisplayLink` (macOS 14+) | „callback will be invoked in-sync with the display the view is on. If the view is hidden, or not on any display, the callback will not be invoked.“ Laut Release Notes macOS 14 „automatically track the display the view is on, and will be automatically suspended if it isn’t on a display“. `isPaused` stoppt die Callbacks, `invalidate()` entfernt den Link aus allen Run-Loop-Modi. `preferredFrameRateRange` ist „best attempt“, Raten sind typischerweise „a factor of the display’s maximum refresh rate“. In WWDC23 wird der Link im Beispiel „to the main runloop for the common modes“ hinzugefügt. | Bester Ticker-Kandidat: vsync-synchron, folgt dem Bildschirm. Ob 6 Hz über `preferredFrameRateRange` auf macOS tatsächlich ankommt, ist offen → ⚠️ VERIFIZIEREN (V5). Robuster: mit voller Rate laufen lassen und auf das 1/6-s-Raster quantisieren, also nur auf Raster-Grenzen reagieren. |
| `CAKeyframeAnimation .discrete` | Läuft nach dem Commit ohne App-Code. AppKit „prefers to render layer trees out-of-process“ (Doku `layerUsesCoreImageFilters`, macOS 10.9+). Entfernt sich nach Ablauf selbst (Default). | **Idle = 0 App-Arbeit by design.** Unabhängig vom Main-Thread nach dem Commit. Dass ein blockierter Main-Thread die laufende Animation nicht stört, ist aus „out-of-process“ abgeleitet → ⚠️ VERIFIZIEREN (V6). |

**CPU im Idle:**
- Die Energy-Efficiency-Guide sagt: „Waking the system from an idle state incurs an energy cost … Invalidate repeating timers when they’re no longer needed. Set tolerances“. `CVDisplayLinkStart` wird dort ausdrücklich als Timer-API gezählt.
- Ein Ticker müsste deshalb strikt **on-demand** laufen: starten, sobald ein Stop-Motion-Job eingeplant wird, und `invalidate()` bzw. `isPaused = true`, sobald die Queue leer ist.
- Bei CA gibt es diesen Zustand gar nicht, weil kein App-Code periodisch läuft. Die Messung auf dem Mac ist trotzdem Pflicht (T4).

**Präzision:**
- Beide Wege quantisieren auf Display-Frames. Bei 60 Hz sind das ±16,7 ms auf 167 ms, bei 120 Hz ±8,3 ms.
- Ein `Timer` ist nicht vsync-gekoppelt. Der Wert wird erst beim nächsten CA-Commit bzw. vsync sichtbar, deshalb kommt bis zu ein Display-Frame Versatz hinzu. Visuell vermutlich irrelevant → ⚠️ VERIFIZIEREN (V7).

**Synchronität mehrerer Objekte:**
- Ticker: Alle Objekte werden im selben Callback in einer Transaktion gesetzt, damit sind sie per Konstruktion synchron.
- CA: gleiches `beginTime` und gleiche `keyTimes` (V3).
- Ein **globales Raster** (Start auf das nächste Vielfache von 1/6 s seit einer App-Epoche gerundet) ist bei beiden Wegen nur Rechenarbeit im Planer. Es verzögert den Start um bis zu 167 ms. Das ist eine Designentscheidung für Max (siehe Offene Punkte).

**Testbarkeit:**
- Die beste Testbarkeit ergibt sich, wenn alle Entscheidungen in einer reinen Funktion stecken. Diese Funktion bekommt die Startzeit, die Frame-Anzahl, einen injizierten Zufallsgenerator mit Seed und das Reduce-Motion-Flag. Sie liefert die Frame-Liste: Werte und `keyTimes` bzw. Zeitpunkte.
- Das ist in Unit-Tests vollständig deterministisch prüfbar. Bei CA kann man zusätzlich das erzeugte Animationsobjekt prüfen (`values`, `keyTimes`, `duration`, `calculationMode`).
- Ein Ticker braucht eine injizierbare Uhr, z. B. ein Protokoll mit `now()` und manuellem `tick()`. Das ist gut machbar, aber mehr Code.
- CA-Timing selbst lässt sich nur auf dem Mac prüfen. Hilfsmittel für manuelle Tests: `speed`/`timeOffset` aus `CAMediaTiming` erlauben Pausieren und Scrubben (Guide, Listing 5-4).

### 3. Implizite Animationen unterdrücken

- **Standalone-Layer** (selbst erzeugte `CALayer`) erzeugen bei Property-Änderungen implizite Animationen: „Core Animation uses your changes as a trigger to create and schedule one or more implicit animations“ (Guide). Ein hartes Springen erreicht man mit einem dieser Wege:
  1. **`CATransaction.begin()` / `setDisableActions(true)` / `commit()`** um jede Model-Änderung. Doku: „Sets whether actions triggered as a result of property changes made within this transaction group are suppressed“. Guide Listing 6-2 zeigt dasselbe über `kCATransactionDisableActions`.
  2. **`layer.actions = ["position": NSNull(), "transform": NSNull(), …]`**. Das `actions`-Dictionary wird in `action(forKey:)` durchsucht.
  3. **Layer-Delegate `action(for:forKey:)`** liefert `NSNull`. Laut Guide gilt: „Return the NSNull object, in which case the search ends immediately“, `nil` setzt die Suche fort.
     - **Widerspruch in der Doku:** Die aktuelle Referenz `action(forKey:)` schreibt dagegen, der Delegate solle „Return the NSNull object if it does not handle the action“, und „If any of the above steps returns an instance of NSNull, it is converted to nil before continuing.“ → ⚠️ VERIFIZIEREN (V8).
     - Weg 1 ist von diesem Widerspruch nicht betroffen und deshalb die primäre Empfehlung.
- **Layer-backed `NSView`:** „AppKit disables implicit animations for its layer-backed views by default. The view’s animator proxy object reenables implicit animations … you can also programmatically reenable implicit animations by changing the allowsImplicitAnimation property of the current NSAnimationContext“ (Guide, „Rules for Modifying Layers in OS X“). `allowsImplicitAnimation` ist standardmäßig `false` und „only applicable when layer backed“.
  - **Wichtig:** Bei layer-backed Views darf der Code an deren eigenem Layer **u. a. `position`, `transform`, `bounds`, `frame`, `anchorPoint`, `shadowColor`, `shadowOffset`, `shadowOpacity`, `shadowRadius` nicht** ändern („must absolutely not modify“). Das gilt nicht für Layer-Hosting-Views.
- **Folge für die Architektur:**
  - Board-Inhalt (Bilder mit Rotation, Jitter, Schatten) als **Standalone-`CALayer`s** in einer **Layer-Hosting-View**. Laut `wantsLayer` muss man „set the layer property first and then set this property to true. The order … is crucial.“ Außerdem: „do not add subviews to a layer-hosting view“.
  - Alternativ als Sublayer, die man selbst an einen layer-backed View hängt. Ob AppKit an solchen Sublayern nichts verändert, ist nicht explizit belegt → ⚠️ VERIFIZIEREN (V9).
  - Für Layer-Hosting-Views gilt standardmäßig `layerContentsRedrawPolicy = .never` (Doku `layerContentsRedrawPolicy`), AppKit zeichnet also nicht dazwischen.
- **Zusammen mit einer discrete-Animation:** Wenn der Model-Wert ohne `disableActions` gesetzt wird, entsteht eine implizite 0,25-s-Animation unter dem Property-Namen als Key. Eine danach unter demselben Key hinzugefügte Animation würde sie ersetzen („Only one animation per unique key is added to the layer“, `add(_:forKey:)`). Auf diese Ersetzung sollte man sich nicht verlassen → `disableActions` immer verwenden. Den Test dafür beschreibt T3.

### 4. „Bewegung reduzieren“

- `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion: Bool { get }` (macOS 10.12+): „If this property’s value is true, avoid large animations, especially those that simulate the third dimension. To receive updates when this setting changes, register for the accessibilityDisplayOptionsDidChangeNotification notification using notificationCenter.“
- `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` (macOS 10.10+): „The notification object is the shared NSWorkspace instance. The notification doesn’t contain a userInfo dictionary.“ **Wichtig:** „To receive this notification, use notificationCenter [= `NSWorkspace.shared.notificationCenter`] to register for it. If you use a different notification center to register, you won’t receive the notification.“ Für Swift Concurrency gibt es ab macOS 26 zusätzlich `NSWorkspace.AccessibilityDisplayOptionsDidChangeMessage`.
- HIG Accessibility: Bei aktivem Reduce Motion „ensure your app … responds by reducing automatic and repetitive animations, including zooming, scaling, and peripheral motion“. Außerdem werden Fades statt x/y/z-Übergängen empfohlen.
- Umsetzung laut Briefing: Bei Reduce Motion liefert der Planer genau einen Frame, nämlich den Endzustand ohne Jitter. Das entspricht einem Model-Set in `disableActions` ohne Keyframe-Animation. Das Flag wird beim Start gelesen und per Notification aktualisiert. Ob der **Realtime-Pfad** (200-ms-Scale) unter Reduce Motion ebenfalls entfällt, legt das Briefing nicht fest. Die HIG nennt „zooming, scaling“ ausdrücklich (siehe Offene Punkte).

### 5. Realtime-Pfad (Aufblättern/Zuklappen)

- **Mechanik:**
  - Explizites `CABasicAnimation` (oder `NSAnimationContext.runAnimationGroup` mit `timingFunction`) mit `CAMediaTimingFunction(name: .linear)` oder `.easeOut`. `easeOut` ist dokumentiert als Bézier (0,0)–(0.58,1.0), hat also keinen Overshoot und kein Bounce.
  - Kein Spring verwenden.
  - `duration = 0.2`.
  - Model-Wert vorab in `disableActions` setzen (Muster aus 1).
  - `anchorPoint` auf die Eselsohr-Ecke setzen („All geometric manipulations to the view occur about the specified point“).
- **Mask vs. Clip-Container:**
  - Laut Tech Talk „Demystify and eliminate hitches in the render phase“ verursachen Masken einen Offscreen-Pass: „render the entire subtree offscreen before copying only the pixels within the masked shape back“.
  - Ein einfacher Layer mit Hintergrundfarbe als Maske sollte durch einen Container mit `masksToBounds = true` ersetzt werden.
  - Für ein **rechteckiges** Aufziehen aus der Ecke heißt das: `bounds` eines Clip-Containers (`masksToBounds`) animieren, Anker in der Ecke.
  - Für eine **diagonale Kante** (Papierfalz) braucht man eine `CAShapeLayer`-Maske mit `path`-Animation. Dafür gilt: Pfad-Animationen sind „not support[ed]“ als implizite Animation und brauchen eine explizite `CAPropertyAnimation`. Die Pfade müssen dieselbe Anzahl Kontrollpunkte haben, sonst „results are undefined“.
  - Der Tech Talk ist iOS-zentriert. Dass die Offscreen-Aussagen für den macOS-Render-Server gleich gelten, ist nicht belegt → ⚠️ VERIFIZIEREN (V10).
- **Start in `draggingEntered(_:)`:**
  - Der Callback läuft auf dem Main Actor (`@MainActor optional func draggingEntered(_:) -> NSDragOperation`).
  - Der CA-Commit passiert automatisch: „Flush is typically called automatically at the end of the current runloop, regardless of the runloop mode … you should attempt to avoid calling flush explicitly“ (Doku `CATransaction.flush()`). Ein explizites `flush()` ist also nicht nötig.
  - Gegen Ruckeln: Im Callback keine schwere Arbeit erledigen (kein Bild-Decoding, kein Layout). Alle Layer und Texturen **vorher** aufbauen, im Callback nur Model-Wert und Animation setzen.
  - Die Board-Fläche wird vorab mit der Endgröße angelegt und nur aufgedeckt, statt das `NSPanel`-Fenster pro Frame wachsen zu lassen. Wie das mit dem Fenster-Drop-Target zusammenspielt, ist Thema des Window-Reports → ⚠️ VERIFIZIEREN (V11).
  - Die Hover-Verzögerung (~300 ms) ist ein One-Shot-Timer während eines Drags. Er muss in `.common`-Modes laufen, weil `.eventTracking` „such as a mouse-dragging loop“ sonst einen `.default`-Timer blockieren kann. Ob die *Ziel*-App während eines fremden Drags überhaupt in `eventTracking` läuft, ist offen → ⚠️ VERIFIZIEREN (V12).
- **Retina / `contentsScale`:**
  - „For layers you create and manage yourself, you must set the value of this property yourself“. Bei einem Layer-backed View setzt AppKit den Wert automatisch.
  - Bei Bildschirmwechsel kommt `viewDidChangeBackingProperties()` („when the backing store scale or color space changes“). Dort `contentsScale` aller Standalone-Layer nachziehen.
  - `NSWindow.backingScaleFactor` ist 1.0 oder 2.0. Apple rät aber, für Layout „the backing coordinate space conversion methods“ statt des Faktors zu verwenden.
  - Ein Scale-Up von Bitmap-Inhalten (von klein auf 1.0) bedeutet nur Verkleinerung des vollen Inhalts. Ein Reveal per `bounds` bzw. Maske skaliert den Inhalt überhaupt nicht und ist daher schärfer als `transform.scale`.

### 6. Harter Schatten ohne Blur

- `shadowRadius`: „The blur radius (in points) used to render the layer’s shadow“, Default 3.0 → **0 setzen**.
- `shadowOffset`: „(in points)“, Default (0, −3).
- `shadowOpacity`: Default **0.0**, der Schatten ist also unsichtbar, solange man den Wert nicht setzt.
- `shadowColor`: Default opak schwarz. Fürs Papier-Look stattdessen Graphit mit passender Opacity.
- **Einheiten:** Das Briefing verlangt 1–2 **px**. Auf Retina (Faktor 2) sind das 0,5–1 pt.
- **Richtung:** Auf macOS ist das Standard-Koordinatensystem nicht geflippt (Ursprung unten links, Guide/`contentsGravity`). Ein negatives y verschiebt nach unten, bei `isGeometryFlipped = true` umgekehrt → ⚠️ VERIFIZIEREN (V13).
- **`shadowPath`:** „Specifying an explicit path usually improves rendering performance“. Ohne Pfad nutzt CA „the layer’s composited alpha channel“. Guide („Improving Animation Performance“): „For layers whose shape never changes or rarely changes, this greatly improves performance“. Tech Talk: Ein dynamischer Schatten verursacht einen Offscreen-Pass, mit `shadowPath` „eliminate all five offscreens“. Für Bild-Layer genügt ein Rechteck-Pfad über die `bounds`. Rotation und Jitter laufen über `transform`/`position`, der Pfad bleibt in Layer-Koordinaten konstant. `shadowPath` wird **nicht** implizit animiert.
- **Zufallsrotation ±1–2°:** `allowsEdgeAntialiasing` ist auf macOS standardmäßig `false`, außer `UIViewEdgeAntialiasing` steht in der Info.plist. Rotierte Kanten werden deshalb gezackt, wenn man das Antialiasing nicht aktiviert. Es empfiehlt sich `true` für Bild-Layer. Wie sich das mit dem harten Schatten verträgt → ⚠️ VERIFIZIEREN (V14).
- **Jitter 0,5–1 px:** Subpixel-Positionen werden vermutlich mit Filterung gerendert. Bewegt man das um ein halbes Pixel, wirkt es eher weich-flimmernd als hart springend. Empfehlung: Jitter auf ganze Device-Pixel runden (Retina 0,5 pt, 1x 1 pt) und visuell vergleichen → ⚠️ VERIFIZIEREN (V15).

### 7. Noise-Textur als PNG-Layer

- `contents` mit `CGImage`: „If you are using the layer to display a static image, you can set this property to the CGImage … (In macOS 10.6 and later, you can also set the property to an NSImage object.)“. Gilt mit dieser Einschränkung: „If the layer object is tied to a view object, you should avoid setting the contents of this property directly“. Ausnahme ist `updateLayer()`, und Standalone- bzw. Layer-Hosting-Layer sind ohnehin nicht betroffen.
- `contentsScale` muss bei direkt gesetzter Bitmap selbst gesetzt werden: „If your image is intended for a Retina display, set the value of this property to 2.0“ (Guide). Nur bei `NSImage` als `contents` wählt AppKit die passende Repräsentation selbst und setzt `contentsScale` passend (Guide).
- **Kein natives Tiling:** `contentsRect` kachelt nicht: „If pixels outside the unit rectangle are requested, the edge pixels of the contents image will be extended outwards.“ `contentsGravity` skaliert oder positioniert nur.
- **Optionen (Bewertung):**
  1. **Einmal vorrendern (empfohlen für den Prototyp):** Bei Start bzw. Bildschirm- oder Scale-Wechsel ein `CGImage` in Board-Größe erzeugen. Dafür die PNG-Kachel per `CGContext.draw(_:in:byTiling: true)` kacheln („fills the context’s entire clipping region by tiling many copies of the image“, macOS 10.9+). Das Ergebnis als `contents` eines Layers setzen, `contentsScale` passend, Opacity niedrig. Danach ist das ein statischer Layer ohne Laufzeitkosten. Speicher: z. B. 3456×2234 px × 4 B ≈ 31 MB pro Bildschirm (Rechnung, nicht gemessen).
  2. **`NSColor(patternImage:)` in `draw(_:)`** eines Layer-backed Views mit `setFill()` und Füllen der `bounds`, nicht des `dirtyRect` (Doku `clipsToBounds`, macOS 14). Laut Doku gilt „The image is tiled starting at the bottom of the window. The image is not scaled.“ Wie @2x-Repräsentationen dabei behandelt werden → ⚠️ VERIFIZIEREN (V16).
  3. **`layer.backgroundColor = NSColor(patternImage:).cgColor`:** In Foren verbreitet, aber nicht von Apple belegt. `cgColor` ist laut Doku „always … a valid color, even though the value may be an approximation in some cases“, was bei einem Pattern auch eine Volltonfarbe bedeuten könnte → ⚠️ VERIFIZIEREN (V17).
  4. **`CGColor(patternSpace:pattern:components:)` mit `CGPattern`** („Core Graphics tiles the pattern cell for you“) als `backgroundColor`. Die API ist dokumentiert, ob CA Pattern-Farben als Layer-Hintergrund rendert, ist es nicht → ⚠️ VERIFIZIEREN (V18).
  5. **`CAReplicatorLayer`:** dokumentiert, verschachtelbar für 2D („Replicator layers can be nested“), `instanceTransform` relativ zur Vorgängerinstanz. Funktioniert, ist aber für eine statische Textur übertrieben. Bei Rundung können Kachelnähte entstehen → ⚠️ VERIFIZIEREN (V19).
- Weil die Textur statisch ist, sollte sie nicht mitanimiert werden. Sie gehört zum Board-Hintergrund, der Realtime-Reveal deckt sie nur auf.

## Offene Punkte

1. **Designentscheidung (Max):** Sollen Stop-Motion-Frames auf ein *globales* 1/6-s-Raster einrasten (alle Objekte im gleichen Takt, Startverzögerung bis 167 ms nach dem Drop) oder startet jede Sequenz sofort mit eigenem Takt?
2. **Designentscheidung (Max):** Reduce Motion und Realtime-Pfad. Bleibt das 200-ms-Aufblättern, wird es durch sofortiges Öffnen ersetzt oder durch eine Überblendung? Die HIG nennt „zooming, scaling“ ausdrücklich.
3. **Deployment-Target:** `NSView.displayLink`/`CADisplayLink` erst ab macOS 14. Wenn der Ticker-Fallback gebraucht wird und ältere Systeme unterstützt werden sollen, bleibt nur `Timer` oder das deprecated `CVDisplayLink`.
4. Doku-Widerspruch zum `NSNull`-Verhalten beim Delegate (V8).
5. Ob `keyTimes` mit falscher Anzahl stillschweigend ignoriert werden und welches Timing dann gilt (V1).
6. Exakte Synchronität mehrerer discrete-Animationen mit gleichem `beginTime` (V3).
7. Ob eine dauerhaft angehängte Animation (`.forwards`, nicht entfernt) im Idle Render-Server-Last erzeugt (V2). Durch die Empfehlung irrelevant, aber als Begründung nützlich.
8. Wie das Realtime-Reveal mit dem Panel und Drop-Target zusammenspielt (vorgroßes, transparentes Panel vs. wachsendes Fenster). Das gehört zum Window-Report (V11).
9. Tiling-Variante der Noise-Textur für Retina, festzulegen im Spike „Board-Panel mit Papier-Textur“.

## ⚠️ VERIFIZIEREN

- **V1** – Bei `.discrete` mit `keyTimes.count != values.count + 1` werden die `keyTimes` ignoriert. Welches Timing gilt dann?
- **V2** – `fillMode = .forwards` + `isRemovedOnCompletion = false`: verursacht die angehängte Animation Idle-Last im Render-Server bzw. WindowServer?
- **V3** – Mehrere Layer mit identischem `beginTime` und `keyTimes` schalten auf demselben Display-Frame um.
- **V4** – Discrete-Animationen auf Sub-KeyPaths (`transform.rotation.z`, `position.x`) funktionieren unter macOS wie dokumentiert für iOS.
- **V5** – `CADisplayLink.preferredFrameRateRange` mit 6 Hz wird auf macOS (60/120 Hz, externe 75/144 Hz) eingehalten.
- **V6** – Eine laufende discrete-Animation schaltet weiter, während der Main-Thread blockiert ist (out-of-process Rendering).
- **V7** – Ein Timer-Ticker ohne vsync-Kopplung ist visuell nicht von CA unterscheidbar (±1 Display-Frame).
- **V8** – Delegate `action(for:forKey:)` → `NSNull`: beendet das die Suche (Guide) oder wird es zu `nil` und die Suche läuft weiter (Referenz)?
- **V9** – AppKit lässt selbst hinzugefügte Sublayer eines Layer-backed Views (position/transform/shadow) unangetastet.
- **V10** – Offscreen-Pass-Kosten von `mask` vs. `masksToBounds` und `shadowPath` gelten auf macOS wie im iOS-zentrierten Tech Talk.
- **V11** – Reveal innerhalb eines vorab bildschirmgroßen Panels vs. wachsendes `NSPanel`: Drop-Target und Hit-Testing (mit Window-Report abgleichen).
- **V12** – Run-Loop-Modus der *Ziel*-App während eines Drags aus einer fremden App. Feuert ein `.default`-Timer?
- **V13** – Richtung von `shadowOffset` auf macOS (nicht geflippt vs. `isGeometryFlipped`).
- **V14** – `allowsEdgeAntialiasing = true` zusammen mit hartem Schatten (Radius 0) und ±2° Rotation: saubere Kanten ohne Halo?
- **V15** – Subpixel-Jitter (0,25 pt auf Retina) wirkt weich/flimmernd; ganzzahliges Device-Pixel-Raster wirkt „hart“.
- **V16** – `NSColor(patternImage:)` mit @1x/@2x-`NSImage`: wird auf Retina die 2x-Repräsentation gekachelt?
- **V17** – `NSColor(patternImage:).cgColor` als `CALayer.backgroundColor` kachelt tatsächlich (statt Approximation als Volltonfarbe).
- **V18** – `CGColor` aus `CGPattern` als `CALayer.backgroundColor` wird von CA gerendert.
- **V19** – `CAReplicatorLayer`-Kachelung ohne sichtbare Nähte bei nicht-ganzzahligen Skalierungen.
- **V20** – Messwerkzeuge: Activity Monitor (Spalte „Idle Wake Ups“ im Energie-Tab) und `top -stats pid,command,cpu,idlew` liefern auf der Ziel-macOS-Version die genannten Spalten.

## Testplan macOS

Voraussetzung ist eine minimale Test-App (Phase-1-Spike „Stop-Motion-Ticker“) mit einer Layer-Hosting-View und 10 Standalone-Bild-Layern. Sie hat Buttons „Drop-Sequenz“, „Ticker-Variante“ und „Main-Thread 500 ms blockieren“. Getestet wird auf einem Retina-Mac (am besten 120-Hz-ProMotion) **und** einem externen 60-Hz-Display mit 1x. Notiert werden macOS-Version und Hardware.

- **T1 – Discrete-Semantik (V1, V4):**
  - Animation auf `position` mit `values = [A, B, C]`, `keyTimes = [0, 1/3, 2/3, 1]`, `duration = 0.5`.
  - Per `NSView.displayLink` jede vsync-Periode `presentation()?.position` mit `CACurrentMediaTime()` loggen.
  - Erwartung: Sprünge bei ≈0, 167 und 333 ms, C bis 500 ms, danach Model-Wert.
  - Danach `keyTimes` mit 3 Elementen (gleich `values.count`) wiederholen und das Timing dokumentieren.
  - Dasselbe für `transform.rotation.z` und für eine `CAAnimationGroup`.
- **T2 – Kein Zurückspringen (V2):**
  - Drei Varianten:
    - (a) Model vorher final + Default-Fill,
    - (b) Model nicht gesetzt + Default,
    - (c) `.forwards` + `isRemovedOnCompletion = false`.
  - Bildschirmaufnahme (QuickTime, 60 fps) einzeln durchsteppen.
  - Erwartung: (a) ohne Sprung, (b) springt zurück.
  - Für (c) zusätzlich 60 s Idle messen wie in T4 (App-CPU und WindowServer-CPU).
- **T3 – Implizite Animationen:**
  - Standalone-Layer-`position` ändern:
    - (a) ohne Transaktion, dann ist eine weiche 0,25-s-Bewegung zu erwarten,
    - (b) mit `setDisableActions(true)`,
    - (c) mit `actions = ["position": NSNull()]`,
    - (d) per Delegate mit `NSNull` (V8),
    - (e) per Delegate mit `nil`.
  - Mit Aufnahme belegen, welche Variante hart springt.
- **T4 – CPU im Idle (Pflicht laut Betriebsregeln):**
  - App starten und 10 Drop-Sequenzen auslösen. Danach 60 s ohne Interaktion warten. Messen mit:
    - Activity Monitor → Tab „Energie“ (Energy Impact, Idle Wake Ups) und Tab „CPU“,
    - `top -pid <PID> -stats pid,command,cpu,idlew -l 60 -s 1` (V20),
    - optional `sudo powermetrics --samplers tasks -i 1000 -n 60`,
    - Xcode Debug Navigator → Energy Impact.
  - Varianten: (a) reine CA, (b) `Timer`-Ticker mit Invalidate bei leerer Queue, (c) `CADisplayLink` mit `isPaused`, (d) `CADisplayLink` mit `invalidate()`.
  - Erwartung (a)/(b)/(d): 0,0 % CPU und ~0 Wakeups/s.
  - Zusätzlich die Gegenprobe mit einem absichtlich weiterlaufenden Ticker, damit die Messmethode den Unterschied auch zeigt.
- **T5 – Synchronität (V3, V7):**
  - 10 Layer in einer Transaktion mit identischem `beginTime` starten.
  - Mit 120-fps-Aufnahme bzw. Log aus T1 prüfen, ob alle auf demselben Frame umschalten.
  - Ticker-Variante daneben, die Abweichung zur Raster-Sollzeit (ms) als Histogramm.
- **T6 – Main-Thread blockiert (V6):** Während einer 6-Frame-Sequenz den Main-Thread 500 ms blockieren. Erwartung CA: Frames laufen weiter. Ticker: Frames bleiben stehen und holen danach einmal auf.
- **T7 – 6 Hz per DisplayLink (V5):** `preferredFrameRateRange` auf min = max = preferred = 6 setzen und die Callback-Intervalle loggen, auf 60-, 120- und 75/144-Hz-Display.
- **T8 – Reduce Motion:**
  - Systemeinstellungen → Bedienungshilfen → Anzeige → „Bewegung reduzieren“ umschalten, während die App läuft.
  - Prüfen: Die Notification kommt nur über `NSWorkspace.shared.notificationCenter`, die Gegenprobe ist `NotificationCenter.default`. Der Property-Wert ist korrekt. Die Drop-Sequenz wird zu einem Frame ohne Jitter.
- **T9 – Realtime in `draggingEntered` (V11, V12):**
  - Bild aus dem Finder auf ein Test-Drop-Target ziehen. Im Callback die 200-ms-Reveal-Animation starten (bounds/masksToBounds-Variante und `CAShapeLayer`-Maskenvariante).
  - Mit Instruments (Time Profiler, ggf. Animation-Hitches-Template, falls auf macOS verfügbar) Hitches und die Latenz vom Callback bis zum ersten sichtbaren Frame messen.
  - Den Run-Loop-Modus im Callback (`RunLoop.current.currentMode`) loggen und einen `.default`- vs. `.common`-Timer für die Hover-Verzögerung testen.
- **T10 – Schatten (V10, V13, V14):**
  - Bild-Layer mit `shadowRadius = 0`, Offset (0,5 pt, −0,5 pt) bzw. (1 pt, −1 pt), `shadowOpacity` 0,3. Mit und ohne `shadowPath`, mit und ohne `allowsEdgeAntialiasing`, bei 0° und ±2°.
  - Screenshots auf 1x und 2x vergleichen (Pixel-Zoom in Vorschau). Mit 100 Layern die Framezeit beim Realtime-Reveal mit/ohne `shadowPath` messen.
- **T11 – Jitter-Raster (V15):** Jitter von 0,25 pt vs. 0,5 pt vs. 1 pt auf Retina im Direktvergleich. Subjektive Bewertung durch Max („wirkt hart / wirkt unscharf“).
- **T12 – Noise-Tiling (V16–V19):**
  - Varianten 1–5 aus Abschnitt 7 nebeneinander auf 1x und 2x. Prüfen: Schärfe (gekachelt mit 1:1-Pixeln?), Nähte, Speicher (Xcode Memory Gauge).
  - Verhalten beim Verschieben des Fensters zwischen 1x- und 2x-Display (`viewDidChangeBackingProperties`).

## Quellen

Apple-Referenz (JSON-Variante, per `curl` abgerufen; Präfix `https://developer.apple.com/tutorials/data/documentation/`):

- `quartzcore/cakeyframeanimation/calculationmode.json`
- `quartzcore/caanimationcalculationmode/discrete.json`
- `quartzcore/cakeyframeanimation.json`
- `quartzcore/cakeyframeanimation/keytimes.json`
- `quartzcore/cakeyframeanimation/values.json`
- `quartzcore/cakeyframeanimation/timingfunctions.json`
- `quartzcore/caanimation/isremovedoncompletion.json`
- `quartzcore/camediatiming/fillmode.json`
- `quartzcore/camediatimingfillmode.json`, `.../forwards.json`, `.../backwards.json`, `.../removed.json`, `.../both.json`
- `quartzcore/camediatiming/begintime.json`, `quartzcore/camediatiming/duration.json`, `quartzcore/camediatiming/speed.json`, `quartzcore/camediatiming/timeoffset.json`
- `quartzcore/calayer/convertTime(_:from:).json`
- `quartzcore/cacurrentmediatime().json`
- `quartzcore/calayer/add(_:forkey:).json`
- `quartzcore/calayer/presentation().json`, `quartzcore/calayer/model().json`
- `quartzcore/capropertyanimation/isadditive.json`
- `quartzcore/caanimationgroup.json`
- `quartzcore/catransaction.json`, `quartzcore/catransaction/setdisableactions(_:).json`, `quartzcore/catransaction/flush().json`
- `quartzcore/calayer/actions.json`, `quartzcore/calayer/action(forkey:).json`, `quartzcore/calayerdelegate/action(for:forkey:).json`
- `appkit/nsanimationcontext.json`, `appkit/nsanimationcontext/allowsimplicitanimation.json`, `appkit/nsanimationcontext/timingfunction.json`, `appkit/nsanimationcontext/runanimationgroup(_:completionhandler:).json`
- `appkit/nsview/wantslayer.json`, `appkit/nsview/wantsupdatelayer.json`, `appkit/nsview/updatelayer().json`, `appkit/nsview/layercontentsredrawpolicy-swift.property.json`, `appkit/nsview/layerusescoreimagefilters.json`, `appkit/nsview/viewdidchangebackingproperties().json`, `appkit/nsview/clipstobounds.json`, `appkit/nsview/draw(_:).json`
- `appkit/nsview/displaylink(target:selector:).json`, `appkit/nswindow/displaylink(target:selector:).json`, `appkit/nsscreen/displaylink(target:selector:).json`
- `quartzcore/cadisplaylink.json`, `quartzcore/cadisplaylink/preferredframerateRange.json`, `quartzcore/cadisplaylink/preferredframespersecond.json`, `quartzcore/cadisplaylink/ispaused.json`, `quartzcore/cadisplaylink/invalidate().json`, `quartzcore/cadisplaylink/timestamp.json`, `quartzcore/cadisplaylink/targettimestamp.json`
- `corevideo/cvdisplaylink.json`, `corevideo/cvdisplaylinkcreatewithactivecgdisplays(_:).json`, `corevideo/cvdisplaylinkcreatewithcgdisplay(_:_:).json`
- `foundation/timer.json`, `foundation/timer/tolerance.json`, `foundation/runloop/mode/common.json`, `foundation/runloop/mode/eventtracking.json`, `foundation/runloop/mode/default.json`
- `dispatch/dispatchsourcetimer.json`, `dispatch/dispatchsource/maketimersource(flags:queue:).json`
- `appkit/nsworkspace/accessibilitydisplayshouldreducemotion.json`, `appkit/nsworkspace/accessibilitydisplayoptionsdidchangenotification.json`, `appkit/nsworkspace/notificationcenter.json`, `appkit/nsworkspace/accessibilitydisplayoptionsdidchangemessage.json`
- `appkit/nsdraggingdestination/draggingentered(_:).json`
- `quartzcore/camediatimingfunctionname/easeout.json`, `quartzcore/camediatimingfunctionname/linear.json`, `quartzcore/cabasicanimation.json`
- `quartzcore/calayer/anchorpoint.json`, `quartzcore/calayer/mask.json`, `quartzcore/cashapelayer.json`, `quartzcore/cashapelayer/path.json`
- `quartzcore/calayer/shadowradius.json`, `quartzcore/calayer/shadowoffset.json`, `quartzcore/calayer/shadowopacity.json`, `quartzcore/calayer/shadowpath.json`, `quartzcore/calayer/shadowcolor.json`, `quartzcore/calayer/allowsedgeantialiasing.json`, `quartzcore/calayer/isgeometryflipped.json`
- `quartzcore/calayer/contents.json`, `quartzcore/calayer/contentsscale.json`, `quartzcore/calayer/contentsrect.json`, `quartzcore/calayer/contentsgravity.json`
- `quartzcore/careplicatorlayer.json`, `quartzcore/careplicatorlayer/instancecount.json`, `quartzcore/careplicatorlayer/instancetransform.json`
- `appkit/nscolor/init(patternimage:).json`, `appkit/nscolor/patternimage.json`, `appkit/nscolor/cgcolor.json`
- `coregraphics/cgcontext/draw(_:in:bytiling:).json`, `coregraphics/cgcolor/init(patternspace:pattern:components:).json`, `coregraphics/cgpattern.json`
- `appkit/nswindow/backingscalefactor.json`

Apple-Guides, Release Notes, Videos, HIG:

- Core Animation Programming Guide – Creating Basic Animations: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CreatingBasicAnimations/CreatingBasicAnimations.html
- Core Animation Programming Guide – Changing a Layer’s Default Behavior: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/ReactingtoLayerChanges/ReactingtoLayerChanges.html
- Core Animation Programming Guide – Advanced Animation Tricks: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/AdvancedAnimationTricks/AdvancedAnimationTricks.html
- Core Animation Programming Guide – Improving Animation Performance: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/ImprovingAnimationPerformance/ImprovingAnimationPerformance.html
- Core Animation Programming Guide – Setting Up Layer Objects: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/SettingUpLayerObjects/SettingUpLayerObjects.html
- Core Animation Programming Guide – Core Animation Basics: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html
- Energy Efficiency Guide for Mac Apps – Minimize Timer Usage: https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html
- AppKit Release Notes for macOS 14 (Abschnitt „Display Link“): https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14.md
- WWDC23 Session 10054 „What’s new in AppKit“ (Transkript, Abschnitt CADisplayLink): https://developer.apple.com/videos/play/wwdc2023/10054/
- Tech Talk 10857 „Demystify and eliminate hitches in the render phase“ (Transkript: Offscreen-Passes, shadowPath, Masken): https://developer.apple.com/videos/play/tech-talks/10857/
- Human Interface Guidelines – Accessibility (Abschnitt Motion/Reduce Motion), JSON: https://developer.apple.com/tutorials/data/design/human-interface-guidelines/accessibility.json
- Human Interface Guidelines – Motion, JSON: https://developer.apple.com/tutorials/data/design/human-interface-guidelines/motion.json

Nicht verwendet: Forenantworten zu `NSColor(patternImage:).cgColor` tauchten nur in Suchergebnissen auf. Die Seite (appsloveworld.com) war über den Proxy nicht abrufbar (403). Deshalb wird sie nicht zitiert, siehe V17.
