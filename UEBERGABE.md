# Dropboard – Übergabe

Stand: 7. Okt. 2026 · Branch `claude/relaxed-bell-vahe5z` · GitHub `mmabura/dropboard`

## Was das ist

Dropboard ist eine native macOS-Moodboard-App (Swift/AppKit, SwiftPM, ohne Xcode). Ein Eselsohr sitzt in einer Bildschirmecke. Ein Bild aufs Eselsohr ziehen und kurz halten öffnet das Board, der Drop legt das Bild ab. Ein Klick aufs Eselsohr öffnet den Ansichtsmodus.
Die Spezifikation steht in `docs/briefing.md`, die Arbeitsregeln in `betriebsregeln.md`, die vorläufigen Entscheidungen E1–E12 in `docs/entscheidungen.md`.

## Ordner

| Pfad | Inhalt |
|---|---|
| `app/` | **Die App.** SwiftPM-Package `Dropboard` (Targets `DropboardCore` + `Dropboard`) |
| `app/scripts/build-app.sh` | Baut `Dropboard.app`, `.zip` und `.dmg`. `--publish` legt sie in die Dropbox, `--install` nach /Applications |
| `app/Packaging/` | Info.plist, App-Icon, „Zuerst lesen“ |
| `app/README.md` | Architektur, Argumente, manuelle Testliste mit erwarteten Logzeilen |
| `spikes/` | Drei Phase-1-Minimalprojekte (Eselsohr/Drop, Papier, Stop-Motion), abgeschlossen |
| `docs/phase0/` | Recherche-Reports (Thumbnail-Drag, Window-Level, Stop-Motion) mit Quellen |
| `docs/phase1/`, `docs/phase2/` | Testprotokolle vom Mac mini |
| `docs/phase3/` | Reviews: Code, Verhalten, Performance |
| `docs/stand.md` | **Aktueller Stand, Nachweise, offene Fragen F1–F10, Backlog** |

## Bauen (macOS 14+, Command Line Tools reichen)

```sh
cd app
swift build
.build/debug/Dropboard --selftest          # erwartet: alle PASS (Stand 0.1.24: 323/323)
.build/debug/Dropboard --board-dir /tmp/db-test   # App mit Test-Board starten, Ctrl-C beendet
.build/debug/Dropboard --snapshot /tmp/db.png --snapshot-demo   # Offscreen-Render ohne Berechtigung
cd .. && app/scripts/build-app.sh          # Universal-App nach app/dist/
```

Logdatei: `~/Library/Logs/Dropboard/dropboard.log`

## Stand

- **Veröffentlicht:** 0.1.32 (Commit `4c9eef5`): Briefing-Schritte 1–8, Review-Fixes, Beschnitt (E11) und Export mit DPI (E12). Baut ohne Fehler und Warnungen, Selftest 505/505, Idle 0,0 % CPU, Single-Instance-Schutz.
- **Nicht von Hand getestet:** die echten Drag-Gesten. Siehe `docs/stand.md`, Abschnitt „Noch NICHT nachgewiesen“. Wichtigster Test: Bild aufs Eselsohr ziehen, halten, das Board klappt auf, auf dem Board loslassen.

## Seit dem ersten Archiv (7. Okt., Commit a2848de) dazugekommen

1. **Beschnitt per Doppelklick (E11).** Inzwischen fertig, ab Commit `903a3a0` (Version 0.1.30). Ein älteres Archiv enthält ihn nicht, `git pull` holt ihn. Spezifikation in `docs/entscheidungen.md` E11:
   - Modell `BoardItem.crop`, normiert und abwärtskompatibel.
   - Darstellung über `contentsRect`.
   - Beschnittmodus im Ansichtsmodus per Doppelklick, mit Griffen, Pan, ⇧, Return/Esc/R.
   - Selftests.
2. **Export mit DPI (E12).** Inzwischen fertig, ab Commit `4c9eef5` (Version 0.1.32). Spezifikation in E12:
   - Menüleiste bzw. ⌘E, kein Dialog.
   - PNG/PDF/Originale-Ordner, 72/150/300/600 dpi.
   - Aus Originalen dekodieren, maximal 16 384 px.
   - Zusätzlich die CLI `--export … --dpi …` zum automatischen Prüfen.

## Offene Fragen an Max

Siehe `docs/stand.md`, F1–F10. Am wichtigsten:
- **F1:** Das Board deckt den ganzen Bildschirm ab, Abbrechen geht nur per Esc.
- **F2:** Das Overlay bleibt nach dem Drop 333 ms offen.
- **F8:** Ist ein Apple-Developer-Account für Signatur und Notarisierung vorhanden?

## Arbeitsweise bisher

- Der Orchestrator plant und verteilt die Arbeit, Sub-Agents setzen sie um. Opus übernimmt Recherche, Integration und Review, Sonnet klar spezifizierten Code.
- Jeder Code-Stand wurde auf dem Mac mini gebaut und mit `--selftest` und `--snapshot` geprüft, bevor er veröffentlicht wurde.
- Unbelegte API-Annahmen sind im Code mit `⚠️ VERIFIZIEREN` markiert.
