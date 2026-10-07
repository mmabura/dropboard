# Dropboard – Briefing für Claude Code

7. Okt. 2026 · @Max

## Kernidee

Dropboard ist eine macOS-Moodboard-App, die Bilder in einer einzigen Drag-Geste sammelt. Ein kleines Eselsohr sitzt dauerhaft in einer Bildschirmecke; ein Drag darauf öffnet das Board, der Drop legt das Bild ab, das Board schließt sich. Kein Finder, kein App-Wechsel, kein Klick.

**Designregel für jede Entscheidung:** So wenig Klicks wie möglich, ein Arbeitsschritt ist so schnell wie möglich abgeschlossen, der kreative Fluss wird nie unterbrochen.

## Kern-Interaktion

Das Eselsohr ist das einzige sichtbare UI-Element im Normalbetrieb. Es ist still: keine Reaktion auf Drag-Start, keine Idle-Animation.

| Element / Aktion | Verhalten |
|---|---|
| Eselsohr | Umgeknicktes Papiereck, ca. 40 px, oben rechts, knapp unter der Menüleiste, etwas vom Rand eingerückt. Immer sichtbar, gedämpft, kein Schatten. Position in allen vier Ecken wählbar. |
| Drag + Hover auf Eselsohr | Papier zieht sich in ca. 200 ms flüssig vom Eck diagonal über den Bildschirm. Board wird als Overlay sichtbar, Ursprungs-App bleibt aktiv. |
| Drop auf Board | Bild landet an der Cursorposition (unsichtbares Grid snappt), Overlay schließt sofort. Fokus bleibt in der Ursprungs-App. |
| Drop direkt aufs Eselsohr (ohne Expand abzuwarten) | Quick-Drop: Bild landet automatisch an der nächsten freien Stelle. Keine Animation. |
| Maus verlässt Board ohne Drop / Esc | Overlay klappt flüssig zu, nichts passiert. |
| Klick aufs Eselsohr (kein Drag) | Board öffnet sich im Ansichtsmodus: betrachten, umsortieren, löschen, exportieren. Schließen per Esc oder Klick aufs Eselsohr. |

Akzeptierte Drag-Quellen: Screenshot-Thumbnail von macOS, Bilddateien aus dem Finder, Bilder aus Browsern, Bild-URLs, Textschnipsel. Priorität im Prototyp: Bilder.

## Look: Papier

Das Board fühlt sich wie ein Blatt Papier an, nicht wie ein Software-Panel.

- Canvas: warmes Off-White, kein reines Weiß. Leichte Faserstruktur als Noise-Textur-Ebene, Deckkraft so niedrig, dass sie bei 100 % Zoom gerade sichtbar ist. Flach: keine Vignette, kein Verlauf.
- Bilder liegen auf dem Papier: harter kleiner Schatten (1–2 px Versatz, kein Blur). Beim Ablegen minimale Zufallsrotation von ±1–2°, damit es nach Hand statt nach Raster aussieht. Grid bleibt als Snapping da, ist aber unsichtbar.
- Overlay-Hintergrund während des Drags: abgedunkeltes Papier statt schwarzer Transparenz.
- Eselsohr: gleiches Papier, als umgeknickte Ecke gezeichnet, ohne Schatten im Ruhezustand.
- Typografie: monospaced oder leicht unregelmäßige Serifenlose, dunkles Graphit statt Schwarz. Keine Systemblau-Akzente.
- Textur im Prototyp als eine einzelne PNG-Noise-Ebene, nicht prozedural.

## Motion: zwei Animationspfade

Während der Nutzer etwas trägt, verhält sich die App wie ein Werkzeug (Realtime). Sobald er losgelassen hat, verhält sie sich wie ein Objekt (Stop-Motion). Beide Pfade im Code klar getrennt und benannt, damit sie sich nicht vermischen.

| Pfad | Wann | Wie |
|---|---|---|
| Realtime | Aufblättern bei Drag-Hover, Zuklappen ohne Drop | Flüssig, ca. 200 ms, Scale/Mask-Animation vom Eselsohr ausgehend. Kein Bounce. |
| Keine Animation | Quick-Drop aufs Eselsohr | Bild erscheint direkt an der nächsten freien Stelle. |
| Stop-Motion | Alles nach dem Drop und alles im Ansichtsmodus | 6 fps (ca. 167 ms pro Frame), stepped, keine Easing-Kurven. Drop: 2 Frames (groß, dann final mit Schatten und Kipp). Aufblättern im Ansichtsmodus: 3 Frames. Umsortieren, Löschen, Tab-Wechsel: stepped. |

Stop-Motion-Details:

- Jeder Frame darf leicht zittern: 0,5–1 px Positions-Jitter, minimal variierende Rotation. Ohne Jitter wirkt stepped nur wie Lag.
- Jitter nur nach dem Drop und im Ansichtsmodus, nie während eines Drags.
- Technisch: Timer-basierter globaler Ticker oder `CAKeyframeAnimation` mit `calculationMode = .discrete`.
- Systemeinstellung „Bewegung reduzieren“ respektieren: dann alles ohne Jitter und Zwischenframes.

## Features nach dem Prototyp

- Mehrere Boards: Im Ansichtsmodus und beim Drag-Expand eine Tab-Leiste oben. Hover über einen Tab wechselt das Board noch während des Drags. Ein Board pro Projekt.
- Herkunft speichern: Bei jedem Drop Quell-App, Dateipfad bzw. URL und Zeitstempel mitschreiben.
- Export: Board als PNG oder PDF, oder als Ordner mit den Originaldateien.
- Weitere Quellen: Bild-URLs, Textschnipsel, Farbwerte, Videoframes aus Resolve.
- Einstellungen: Ecke (vier Positionen, Einrückung), Verzögerung bis Expand (Standard ca. 300 ms, sonst poppt es bei jedem Drag auf), Overlay-Deckkraft, Ausblenden-Hotkey.
- Ausblenden: Hotkey oder Menüleisten-Schalter, der das Eselsohr temporär versteckt, z. B. für Aufnahmen und Präsentationen. Sonst ist es in jedem Screenshot drin.

## Technische Hinweise und Risiken (macOS)

Das Eselsohr als dauerhaftes Drop-Target braucht keine globale Drag-Überwachung und damit keine Accessibility- oder Input-Monitoring-Berechtigung. Das ist der Hauptgrund für dieses Design.

- Fenster: Eselsohr und Board als nicht-aktivierende `NSPanel` (borderless, transparent, über allen Fenstern). Window-Level so wählen, dass das Panel auch über Fullscreen-Spaces sichtbar bleibt, z. B. über DaVinci Resolve im Vollbild. Collection-Behavior: `canJoinAllSpaces`, `fullScreenAuxiliary`.
- Drop-Handling: `NSDraggingDestination` auf dem Eselsohr-Panel und dem Board-Panel. Beim Expand wächst das Board-Panel unter dem Cursor, die Drag-Session muss nahtlos vom kleinen ins große Panel übergehen.
- Screenshot-Thumbnail: Das macOS-Thumbnail liefert beim Drag möglicherweise ein File-Promise statt fertiger Dateidaten. Als Erstes im Prototyp testen, ob der Drop vom Thumbnail sauber ankommt. Falls nicht: `NSFilePromiseReceiver` verwenden.
- Oben rechts kollidiert mit Mitteilungen. Eselsohr knapp unter der Menüleiste und vom rechten Rand eingerückt platzieren, Standardabstand testen.
- Mehrere Monitore: Das Board expandiert auf dem Bildschirm, auf dem der Drag läuft. Ein Eselsohr pro Bildschirm oder nur auf dem Hauptbildschirm, als Einstellung.
- Speicherung: Bilder als Kopie in einem App-eigenen Ordner, Board-Layout als JSON daneben. Keine Datenbank im Prototyp.
- Abgrenzung: Yoink und Dropover sind Zwischenablage-Shelfs. Dropboard ist ein Board, auf dem man positioniert. Das muss im Pitch und in der UI klar sein.

## Prototyp-Umfang und Reihenfolge

Der erste Prototyp hat ein Eselsohr, ein Board, nur Bilder. Export und Multi-Board kommen danach.

1. Eselsohr-Panel oben rechts, immer sichtbar, über allen Fenstern inkl. Fullscreen-Spaces.
2. Drop-Test vom macOS-Screenshot-Thumbnail und aus dem Finder. Hier entscheidet sich, ob das Konzept trägt.
3. Quick-Drop: Bild landet an der nächsten freien Stelle, Speicherung als Datei plus JSON-Layout.
4. Board-Panel mit Papier-Textur, Bilder mit hartem Schatten und Zufallsrotation.
5. Realtime-Expand bei Drag-Hover, Drop an Cursorposition, Zuklappen ohne Drop.
6. Stop-Motion-Ticker für Post-Drop-Zustände.
7. Ansichtsmodus per Klick: Umsortieren, Löschen, Esc.
8. Einstellungen: Ecke, Verzögerung, Ausblenden-Hotkey.

Stack: Swift, AppKit für die Panels und das Drag-and-Drop, SwiftUI optional für Einstellungen. Kein Electron, kein Web-Overlay, weil Window-Level und Drop-Verhalten nativ sein müssen.

## Methodik: Sub-Agents in Claude Code

Modellwahl nach Risiko, nicht nach Gewohnheit. Opus 5.5 überall dort, wo abgewogen, recherchiert oder integriert wird: Orchestrator, Phase 0, Phase 2, Phase 3. Sonnet 5.5 für Code mit vollständiger Spezifikation aus Phase 0 und isolierter Testbarkeit, z. B. Stop-Motion-Ticker, JSON-Speicherung, Einstellungen. Haiku 4.5 nur für mechanische Arbeit ohne Entscheidungen: Dateisuche, Log- und Report-Zusammenfassungen, Formatierung. Im Zweifel Opus; ein Sonnet-Agent, der eine ungeklärte API-Frage trifft, stoppt und meldet, statt zu raten.

Ein Orchestrator hält den Plan und den Zustand, die Arbeit läuft in parallelen Sub-Agents mit klar abgegrenzten Aufträgen. Jeder Sub-Agent bekommt genau eine Aufgabe, den Pfad zu `betriebsregeln.md` und dieses Briefing, und liefert einen Report mit Ergebnis, offenen Punkten und ⚠️ VERIFIZIEREN-Markern zurück. Der Orchestrator schreibt keinen Code selbst, sondern plant, verteilt, prüft und integriert.

| Phase | Sub-Agents (parallel) | Ergebnis |
|---|---|---|
| 0 Recherche | Drag-and-Drop aus dem macOS-Screenshot-Thumbnail (File Promise?) · Window-Level und Collection-Behavior für Overlays über Fullscreen-Spaces · Stepped Animation mit `CAKeyframeAnimation` `.discrete` | Je ein Report mit Quellen (Apple-Dokumentation, verifizierte Beispiele), kein Code |
| 1 Spike | Eselsohr-Panel mit Drop-Test · Board-Panel mit Papier-Textur · Stop-Motion-Ticker als isoliertes Demo | Drei lauffähige Minimal-Projekte, unabhängig voneinander |
| 2 Integration | Ein Agent führt die Spikes zusammen | Prototyp Schritte 1–5 |
| 3 Review | Code-Review · Verhaltens-Test gegen die Interaktionstabelle · Performance (CPU im Idle, Latenz Expand) | Befundlisten, keine Änderungen am Code |
| 4 Fix | Ein Agent pro Befundgruppe | Behobene Punkte mit Nachweis |

Regeln:

- Parallel läuft nur, was keine gemeinsamen Dateien berührt. Spikes in getrennten Verzeichnissen, Integration und Fixes seriell oder mit disjunkten Dateisets.
- Recherche-Agents dürfen keinen Produktionscode schreiben, Code-Agents keine ungeprüften API-Annahmen verwenden. Jede API-Annahme kommt aus Phase 0 oder wird als ⚠️ VERIFIZIEREN markiert.
- Stop-and-Report: Ein Agent, der auf eine Blockade stößt (Berechtigung, nicht reproduzierbares Verhalten, widersprüchliche Doku), stoppt und meldet, statt zu raten oder zu umgehen.
- Review-Agents sehen nur das Briefing und den Code, nicht die Begründungen der Code-Agents. Das hält den Blick frisch.
- Definition of Done pro Phase steht in `betriebsregeln.md`. Keine Phase startet, bevor die vorherige abgenommen ist.
- Kontext klein halten: Jeder Sub-Agent bekommt nur die Abschnitte dieses Briefings, die er braucht. Der Orchestrator fasst Reports zusammen, bevor er sie weitergibt.
