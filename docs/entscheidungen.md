# Entscheidungen

> **Status: VORLÄUFIG.** Max hat am 7. Okt. 2026 gesagt: „mach erstmal einen Entwurf fertig nach bestem Gewissen, Fragen klären wir dann“.
> Die folgenden Punkte sind Annahmen des Orchestrators. Jede ist im Code als Konstante bzw. an einer Stelle gebündelt, damit sie sich leicht ändern lässt.

| # | Frage (aus `phase0/00-zusammenfassung.md`) | Vorläufige Entscheidung | Begründung |
|---|---|---|---|
| E1 | Globales 6-fps-Raster oder Start sofort? | **Start sofort.** Jede Stop-Motion-Sequenz beginnt beim Auslösen und hat dann einen festen Takt von 1/6 s. | Designregel „so schnell wie möglich“. Bis zu 167 ms Startverzögerung würden wie Lag wirken. |
| E2 | „Bewegung reduzieren“ und Aufblättern | **Board erscheint sofort,** ohne Aufblättern, ohne Jitter, ohne Zwischenframes. | Die HIG nennt Zoom und Scale ausdrücklich als Bewegung (Report 03). |
| E3 | Deployment-Target | **macOS 14.** | `NSView.displayLink` (Ticker-Fallback); Mac mini hat SDK bis 15.5. |
| E4 | Sandbox | **Ohne App Sandbox** im Prototyp. | Report 01; vermeidet Entitlement-Fragen beim Drop. |
| E5 | Screenshot wird „verbraucht“ | **Akzeptiert.** Dropboard speichert die Kopie dauerhaft und loggt den Quellpfad. | Die App-Kopie ist ohnehin die Ablage. Bleibt Frage an Max. |
| E6 | DaVinci Resolve | **Offen.** Getestet wird zuerst mit einer beliebigen App im nativen Vollbild (z. B. Safari). | Resolve muss auf dem Mac mini vorhanden sein. |
| E7 | `betriebsregeln.md` | **Entwurf gilt** bis zur Abnahme. | — |
| E8 | Briefing-Konflikt: „Overlay schließt sofort“ vs. „Drop: 2 Frames Stop-Motion“ | **Board bleibt für die 2 Drop-Frames (≈333 ms) sichtbar, dann schließt es.** Die Konstante heißt `dropCloseDelay`. Mit „Bewegung reduzieren“ schließt es sofort. | Sonst ist die Drop-Animation nie sichtbar. Das Fenster ist nicht aktivierend, die Ursprungs-App behält den Fokus. Frage an Max. |
| E9 | Build-System | **SwiftPM-Executables**, `swift-tools-version: 5.9` (Swift-5-Sprachmodus), gebaut mit `swift build` auf den Command Line Tools. | Kein Xcode auf dem Mac mini. Swift 5 statt Swift-6-Modus, damit die strikte Concurrency-Prüfung keine Builds bricht, die hier nicht vorab kompilierbar sind. |
| E10 | Expand-Verzögerung | **300 ms** Drag-Hover auf dem Eselsohr, dann Expand. | Briefing, Abschnitt Einstellungen. |
| E11 | Beschnitt (Max, 7. Okt. 2026: „nach einem Doppelklick den Beschnitt ändern“) | **Doppelklick auf ein Bild im Ansichtsmodus → Beschnittmodus.** Das ganze Original erscheint, außerhalb des Rahmens abgedunkelt (abgedunkeltes Papier, warm). 4 Eck- und 4 Kanten-Griffe ändern den Rahmen, Ziehen im Rahmen verschiebt das Bild darunter. ⇧ hält das Seitenverhältnis. **Übernehmen:** Return, Doppelklick oder Klick daneben. **Abbrechen:** Esc. **R** setzt auf das ganze Bild zurück. Nicht-destruktiv: Die Originaldatei bleibt unverändert, gespeichert wird ein normiertes Rechteck in `board.json`. Der sichtbare Teil bleibt beim Beschneiden an Ort und Größe wie Papier, das man zurechtschneidet. | Designregel „wenige Klicks“; nicht-destruktiv, damit sich nichts verliert; der Export übernimmt den Beschnitt später. |
