# Stand Dropboard – 7. Okt. 2026

**Version 0.1.24** (Commit `ebf8359`), veröffentlicht in
`Dropbox/_PROJECTS/CLAUDE CODE/Dropboard/` (`Dropboard-latest.dmg`, `.zip`, `versions/v0.1.24/`).

## Was fertig ist

| Phase | Ergebnis | Nachweis |
|---|---|---|
| 0 Recherche | 3 Reports (Thumbnail-Drag, Window-Level, Stop-Motion) | `docs/phase0/` |
| 1 Spikes | 3 lauffähige Minimal-Projekte | `docs/phase1/testprotokoll.md` |
| 2 Integration | Briefing-Schritte 1–8 in `app/` | `docs/phase2/testprotokoll.md` |
| 3 Review | Code (20), Verhalten (13), Performance (14) Befunde | `docs/phase3/` |
| 4 Fix | Gruppen A/B/C + Single-Instance-Schutz | Tabelle unten |
| Verteilung | `Dropboard.app` (Universal, ad-hoc), DMG/ZIP, `--publish` nach Dropbox | `app/scripts/build-app.sh` |

## Nachweise auf dem Mac mini (automatisch, ohne Gesten)

| Prüfung | Ergebnis |
|---|---|
| `swift build` (0.1.24) | ✅ 0 Fehler, 0 Warnungen |
| `--selftest` | ✅ 323/323 PASS (Planer, Layout, Store, Ansichtsmodus, Settings, Fix A/B/C) |
| App-Bundle | ✅ Universal x86_64+arm64, `codesign --verify --strict` gültig, Gatekeeper „rejected“ (ad-hoc, erwartet) |
| Start per `open` | ✅ kein Fokusraub, Eselsohr level 25, behavior 0x151, Menüleisten-Symbol + Hotkey ⌃⌥⌘E registriert ohne Berechtigung |
| Idle (0.1.18, 60 s) | ✅ 0,0 % CPU, ~0 Wakeups, 0 Logzeilen, Main-Thread 100 % in `mach_msg` |
| Single-Instance (0.1.24) | ✅ zweite Instanz beendet sich: „Bereits eine Instanz aktiv … beende mich“ |
| Snapshot-Optik | ✅ Eselsohr als umgeknicktes Papier, harter Schatten sichtbar, Noise fein, Abdunklung warm |

## Phase 4 – behobene Befunde

| Gruppe | Befunde |
|---|---|
| A Import/Dekodieren/Store | P1 P2 P3 P4 P9 P10 C6 C7 C8 C9 C10 C11 C14 C15 C17 C19 C20 B8; B2 teilweise |
| B Zustand/Fenster/Fokus | C1 C2 C3 C4 C12 C16 C18 B4 B12 P6 P7 P8 P14 S1 |
| C Optik/Motion/Szene | P5 C5 C13 B6 B7 + Eselsohr-Redesign + Schatten |
| nicht behoben | P12 (`--handoff grow` nutzt bewusst `setFrame`), P11/P13 (niedrig), B3 (Designfrage), B1 (Entscheidung E8) |

## Noch NICHT nachgewiesen – braucht Max am Gerät

1. **Drag-Übergang Eselsohr → Board** (größtes Risiko): Bild aufs Eselsohr ziehen, ~300 ms halten, Board klappt auf, auf dem Board loslassen. Log: `[HANDOFF] Drop-Panel=board …` (oder `=ear … trotz offenem Board`) und das Bild liegt am Cursor.
2. **Screenshot-Thumbnail** (⌘⇧4 → Vorschau aufs Eselsohr): Bild kommt an; Log `[DROP] Weg=…`.
3. **Fokus**: Nach dem Drop in TextEdit weitertippen können; Log `[FOCUS] … NSApp.isActive=false`.
4. **Vollbild-Space** (Safari/Resolve im Vollbild): Eselsohr sichtbar und Drop funktioniert.
5. **Esc** bei offenem Board und im Ansichtsmodus; dabei **kein** Berechtigungsdialog (Eingabeüberwachung).
6. **Beim Anmelden starten** mit der ad-hoc-signierten App.
7. **Erster Start auf dem Laptop** (Gatekeeper-Dialog ja/nein).

Logdatei: `~/Library/Logs/Dropboard/dropboard.log`. Vollständige Testliste mit erwarteten Logzeilen: `app/README.md`.

## Offene Fragen an Max

| # | Frage | Vorläufig |
|---|---|---|
| F1 | **Board deckt den ganzen Bildschirm** (B3): Abbrechen geht nur per Esc, weil es kein „neben dem Board“ gibt. Soll das Papier nur einen Bereich ab der Ecke bedecken (z. B. ⅔ der Diagonale), damit Loslassen daneben abbricht? | ganzer Bildschirm |
| F2 | **Overlay nach dem Drop** (E8/B1): Briefing sagt „schließt sofort“, verlangt aber 2 sichtbare Drop-Frames. | bleibt ≈333 ms offen |
| F3 | **Stop-Motion-Start** (E1): sofort oder auf globalem 6-fps-Raster? | sofort |
| F4 | **Bewegung reduzieren** (E2): Aufblättern auch weg? | ja, Board erscheint sofort |
| F5 | **Screenshot „verbraucht“** (E5): macOS legt nach angenommenem Thumbnail-Drop evtl. keine Datei auf den Schreibtisch – ok? | ok |
| F6 | **Ausblenden-Hotkey**: ⌃⌥⌘E statt ⌥⌘D (kollidiert mit „Dock ein-/ausblenden“) – ok? | ⌃⌥⌘E |
| F7 | **Eselsohr auf weißem Hintergrund** etwas blass – Kante kräftiger? | so lassen |
| F8 | **Apple-Developer-Account** vorhanden? Dann Developer-ID-Signatur + Notarisierung, kein Gatekeeper-Dialog mehr. | ad-hoc |
| F9 | **Versionsnummern**: aktuell 0.1.<Commit-Anzahl>. Eigenes Schema/Tags gewünscht? | so lassen |
| F10 | `betriebsregeln.md` und `docs/entscheidungen.md` abnehmen. | Entwürfe gelten |

## Backlog (nach dem Prototyp laut Briefing)

Export (PNG/PDF/Ordner), mehrere Boards mit Tab-Leiste, weitere Quellen (Text, Farben, Resolve-Frames),
Overlay-Deckkraft und Einrückung als Einstellung, Eselsohr pro Bildschirm, Hotkey frei belegbar.
Kleinkram: Selftests schreiben einzelne Zeilen ins echte `dropboard.log`; P11/P13.
