# Spike: Stop-Motion-Ticker (Phase 1)

Isolierte Demo für den Stop-Motion-Pfad (6 fps, stepped, Jitter) und den Realtime-Pfad (200 ms) von Dropboard.
Grundlage: `docs/phase0/03-stepped-animation.md`, Entscheidungen E1 (Start sofort), E2 (Bewegung reduzieren), E3 (macOS 14), E9 (SwiftPM).

**Status: auf Linux geschrieben, nie kompiliert und nie ausgeführt.** Alle Aussagen unten sind Testschritte, kein Nachweis.
Unbelegte API-Annahmen sind im Code mit `// ⚠️ VERIFIZIEREN` markiert (`grep -rn "VERIFIZIEREN" Sources`).

## Aufbau

| Target | Inhalt |
|---|---|
| `StopMotionCore` (Library) | Reiner Planer: `StopMotionClock` (6 fps), `SplitMix64` (seedbarer PRNG), Jitter, `StopMotionPlanner`, fertige Sequenzen `drop`, `reveal`, `move`, `delete`. Nur Foundation und CoreGraphics-Typen. |
| `stopmotion-demo` (Executable) | `StopMotion` (CAKeyframeAnimation, `.discrete`), `RealtimeMotion` (CABasicAnimation), Demo-Fenster, `--selftest`. |

Kein Timer, kein DisplayLink: Nach dem Commit läuft alles im Render-Server, danach entfernen sich die Animationen selbst.
Das einzige verzögerte Aufräumen (Mask entfernen, gelöschte Karte entfernen) ist ein One-Shot.

## Build, Selftest, Start

```
cd spikes/stopmotion
swift build
swift run stopmotion-demo --selftest      # kein Fenster, Exit-Code 0 = alles PASS, 1 = mindestens ein FAIL
swift run stopmotion-demo                 # Demo-Fenster
swift run stopmotion-demo --seed 42       # reproduzierbare Zufallswerte
```

Gebaut wird nur mit den Command Line Tools, es gibt bewusst kein XCTest-Target.

## Tasten (Fenster muss den Fokus haben)

| Taste | Aktion |
|---|---|
| 1 | Drop-Sequenz auf zufälliger Karte (2 Frames: groß ohne Kipp, dann final mit Kipp) |
| 2 | Reveal aller Karten (3 Frames: Scale 0.6, 0.85, 1.0) |
| 3 | Move: zufällige Karte zu zufälliger Position (2 bis 4 Schritte) |
| 4 | Delete (2 Frames: kleiner, dann weg), danach neue Karte mit Drop |
| R | Realtime-Reveal (200 ms Mask-Scale vom oberen rechten Eck, easeOut) zum Vergleich |
| M | "Bewegung reduzieren" manuell umschalten (zusätzlich zur Systemeinstellung) |
| I | Idle-Check: loggt die Anzahl aktiver Animationen auf allen Layern |
| Esc | Beenden |

Jede Sequenz loggt auf stdout: Name, Pfad, Ziel, Frame-Anzahl, Dauer, Reduce-Motion-Status.

## Testschritte für Max (macOS)

Notieren: Mac-Modell, macOS-Version, Display (Retina/1x, 60/120 Hz).

1. **Selftest:** `swift run stopmotion-demo --selftest`. Erwartung: nur `PASS`, letzte Zeile `N/N PASS`, `echo $?` ergibt 0.
2. **Build:** `swift build` ohne Warnungen und Fehler. Compile-Fehler bitte komplett an den Orchestrator melden (Code wurde nie kompiliert).
3. **Stepped wirkt nicht wie Lag:** Taste 1 mehrfach. Erwartung: sofortige Reaktion (kein Warten bis zum nächsten Raster, E1), zwei klar getrennte Frames à 167 ms, kein Zurückspringen am Ende.
4. **Jitter sichtbar:** Taste 2, mehrfach. Die Karten zittern in den Zwischenframes leicht, der letzte Frame sitzt ruhig und exakt. Bewertung: wirkt "hart" oder "unscharf/flimmernd" (V15)?
5. **Move:** Taste 3. Gleichmäßige Schritte, erster Schritt sofort, Ankunft exakt am Ziel.
6. **Delete:** Taste 4. Karte schrumpft leicht, verschwindet, neue Karte erscheint mit Drop.
7. **Vergleich Realtime:** Taste R. Flüssiges Aufziehen in 200 ms vom oberen rechten Eck, kein Bounce, danach keine Maske mehr (I zeigt 0).
8. **Reduce Motion:** Systemeinstellungen, Bedienungshilfen, Anzeige, "Bewegung reduzieren" bei laufender App umschalten (das Log zeigt `reduce motion changed by system`). Dann Tasten 1 bis 4 und R. Erwartung: Stop-Motion = 1 Frame (`frames=1 duration=0.000s animated=false`), kein Jitter, Realtime-Reveal sofort (`animated=false`). Taste M muss denselben Effekt ohne Systemeinstellung liefern.
9. **Idle-CPU:** Mehrere Sequenzen auslösen, dann 10 s nichts tun und Taste I drücken. Erwartung: `0 active animation(s)`. Danach die Messung (ohne Interaktion, Fenster sichtbar):
   - Activity Monitor: Prozess `stopmotion-demo`, Spalte "% CPU" (CPU-Tab) und "Idle Wake Ups" (Energie-Tab, ggf. Spalte einblenden). Erwartung: 0,0 % und nahe 0 Wake-ups.
   - Terminal: `top -pid <PID> -stats pid,command,cpu,idlew -l 15 -s 1` (PID steht in der ersten Log-Zeile).
   - Zur Plausibilisierung der Messmethode: Messwert direkt während einer Sequenz mit vergleichen.
10. **Retina/1x (falls zwei Displays):** Fenster zwischen den Displays ziehen. Das Log meldet `backing scale changed`. Jitter bleibt auf ganze Device-Pixel gerundet (Schärfe prüfen).
11. **Harter Schatten:** Kartenschatten ohne Blur, 2 pt nach rechts unten (V13: Richtung prüfen), Kanten der gekippten Karten sauber (V14).

Prüfprotokoll bitte mit Datum, Name und Ergebnis je Schritt (OK, Abweichung, nicht geprüft).
