# Phase 1 – Testprotokoll

**Umgebung:** Max' Mac mini (Apple M4, macOS 26.5.1 / 25F80), 4K-Display (Backing-Scale 2.0).
Toolchain: nur Command Line Tools, Swift 6.1.2, SDKs bis macOS 15.5, kein Xcode, kein XCTest.

**Ausgeführt von:** Remote-Control-Session auf dem Mac mini, im Auftrag des Orchestrators.
Interaktive Prüfungen (Optik, Gesten) sind **noch nicht** gemacht. Sie stehen unten als offen.

## board-paper (Commit 6403967)

| Prüfung | Ergebnis |
|---|---|
| `swift build` | ✅ Exit 0, 0 Fehler, 0 Warnungen (26,6 s) |
| Ressource `noise.png` im Bundle | ✅ `board-paper_BoardPaper.bundle/noise.png` (59 642 B), flach im Bundle → ⚠️ in `Package.swift` bestätigt |
| Start-Smoketest (4 s, dann SIGTERM) | ✅ läuft, kein Crash, keine Ausgabe |
| Optik (Off-White, Noise, Schatten, Rotation, Abdunklung) | ⏳ offen – braucht Max oder Snapshot-Modus |

## stopmotion (Commit e864951)

| Prüfung | Ergebnis |
|---|---|
| `swift build` | ✅ Exit 0, 0 Fehler, 0 Warnungen (25,7 s) |
| `--selftest` | ✅ 55/55 PASS, Exit 0 |
| Start-Smoketest (4 s, dann SIGTERM) | ✅ läuft, kein Crash; Backing-Scale 2.0 gemeldet; Reduce Motion beim Start: aus |
| Animationen per Taste, Jitter-Wirkung, CPU im Idle | ⏳ offen – braucht Max |

## eselsohr-drop (Commit d1133f5)

| Prüfung | Ergebnis |
|---|---|
| `swift build` | ✅ Exit 0, 0 Fehler, 0 Warnungen (25,7 s) |
| Start-Smoketest `--handoff two-panels` (5 s, dann SIGINT) | ✅ läuft, sauber beendet (exit 0) |
| `setActivationPolicy(.accessory)` ohne Bundle | ✅ `true` |
| Level / Collection-Behavior | ✅ beide Panels level 25 (`.statusBar`), behavior `0x151` = canJoinAllSpaces · stationary · ignoresCycle · fullScreenAuxiliary |
| Kein Fokusraub beim Start | ✅ `NSApp.isActive=false`, frontmost blieb die vorherige App |
| Eselsohr-Position | ✅ frame (1868,1008 40×40) bei visibleFrame (0,57 1920×993): Oberkante 1048, Menüleiste beginnt bei 1050 → 2 pt darunter, 12 pt vom rechten Rand |
| Level-Referenz | floating 3 · mainMenu 24 · statusBar 25 · popUpMenu 101 · cgDraggingWindow 500 · screenSaver 1000 (bestätigt Report 02) |
| Drag-Tests T0–T6 (Thumbnail, Finder, Browser, Handoff, Fokus, Vollbild) | ⏳ offen – Gesten durch Max, Testliste in `spikes/eselsohr-drop/README.md` |
