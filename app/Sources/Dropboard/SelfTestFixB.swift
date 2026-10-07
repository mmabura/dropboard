import Foundation
import DropboardCore

/// Phase 4, Fix-Gruppe B (Zustandsautomat/Fenster/Fokus): reine Logik aus DropboardConfig.swift
/// (DragRules, DragPhase, WatchdogRules, ScreenChoice, SingleInstance, LogRotation).
/// Einhängen in SelfTest.run (macht der Orchestrator): `FixBSelfTest.run(t)`.
enum FixBSelfTest {
    static func run(_ t: SelfTestChecker) {
        earRules(t)
        dropKinds(t)
        activity(t)
        watchdog(t)
        screens(t)
        singleInstance(t)
        logRotation(t)
    }

    // MARK: C1, C12 – Antwort des Eselsohrs

    private static func earRules(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("fixB: " + name, ok()) }
        typealias R = DragRules
        check("C1: expanded + Bild → Eselsohr nimmt an (boardDrop), nicht []",
              R.earDrag(phase: .expanded, isImage: true) == .boardDrop)
        check("C12: idle + Bild (auch aus draggingUpdated) → Hover starten",
              R.earDrag(phase: .idle, isImage: true) == .startHover)
        check("C12: collapsing/dropClosing + Bild → abgelehnt (erst nach idle)",
              R.earDrag(phase: .collapsing, isImage: true) == .reject && R.earDrag(phase: .dropClosing, isImage: true) == .reject)
        check("hovering + Bild → Timer läuft weiter (kein Neustart)", R.earDrag(phase: .hovering, isImage: true) == .keepHover)
        check("kein Bild → in jeder Phase abgelehnt",
              [DragPhase.idle, .hovering, .expanded, .collapsing, .dropClosing, .viewing, .viewClosing]
                .allSatisfy { R.earDrag(phase: $0, isImage: false) == .reject })
        check("viewClosing → abgelehnt", R.earDrag(phase: .viewClosing, isImage: true) == .reject)

        // Ablauf C12: Drag bleibt aufs Eselsohr, Board klappt zu → Updates bis idle abgelehnt, dann Hover.
        let sequence: [DragPhase] = [.collapsing, .collapsing, .idle]
        let answers = sequence.map { R.earDrag(phase: $0, isImage: true) }
        check("C12-Ablauf: collapsing, collapsing, idle → reject, reject, startHover",
              answers == [.reject, .reject, .startHover])
    }

    // MARK: C1 – Art des Drops

    private static func dropKinds(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("fixB: " + name, ok()) }
        typealias R = DragRules
        check("C1: Drop aufs Eselsohr bei offenem Board → Board-Drop an Cursor",
              R.dropKind(phase: .expanded, onBoardTarget: false) == .earWhileOpen
                && R.dropKind(phase: .expanded, onBoardTarget: false).isBoardDropAtCursor)
        check("Board-Drop (expanded, Board-Ziel) → an Cursor",
              R.dropKind(phase: .expanded, onBoardTarget: true) == .board && R.DropKind.board.isBoardDropAtCursor)
        check("Quick-Drop (idle/hovering) → nächste freie Stelle",
              R.dropKind(phase: .hovering, onBoardTarget: false) == .quick
                && R.dropKind(phase: .idle, onBoardTarget: false) == .quick && !R.DropKind.quick.isBoardDropAtCursor)
        check("Ansichtsmodus hat Vorrang vor dem Ziel",
              R.dropKind(phase: .viewing, onBoardTarget: false) == .viewing && R.dropKind(phase: .viewing, onBoardTarget: true) == .viewing)
        check("Drop während Zuklappen → kein Board-Drop (late)",
              R.dropKind(phase: .collapsing, onBoardTarget: true) == .late && !R.DropKind.late.isBoardDropAtCursor)
    }

    // MARK: P14 – Aktivität nur während der Drag-Session

    private static func activity(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("fixB: " + name, ok()) }
        check("P14: hovering/expanded/collapsing/dropClosing halten die Aktivität",
              [DragPhase.hovering, .expanded, .collapsing, .dropClosing].allSatisfy { $0.isDragSession })
        check("P14: idle/viewing/viewClosing ohne Aktivität",
              [DragPhase.idle, .viewing, .viewClosing].allSatisfy { !$0.isDragSession })
    }

    // MARK: P8, B4 – Watchdog

    private static func watchdog(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("fixB: " + name, ok()) }
        typealias W = WatchdogRules
        let base = WatchdogInput(elapsed: 0.5)
        check("Konstanten: 20 ms, Toleranz 5 ms, Obergrenze 30 s, perform-Timeout 3 s",
              DropboardConfig.pollInterval == 0.02 && DropboardConfig.pollTolerance == 0.005
                && DropboardConfig.watchdogMaxDuration == 30 && DropboardConfig.dropPerformTimeout == 3)
        check("B4: exitInsideGrace ≤ 150 ms", (DropboardConfig.exitInsideGrace ?? 1) <= 0.15)
        check("Maustaste gedrückt, nichts los → none", W.decide(base) == .none)

        var i = base
        i.elapsed = 30
        check("P8: Obergrenze 30 s → zuklappen", W.decide(i) == .collapse(.maxDuration))
        i.dropReceived = true
        check("P8: Obergrenze gilt auch mit angekündigtem Drop", W.decide(i) == .collapse(.maxDuration))

        i = base
        i.dropReceived = true
        i.sincePrepare = 1
        i.mouseButtonDown = false
        i.escDown = true
        check("Drop angekündigt (< 3 s) → nichts tun, auch bei Esc/Maustaste los", W.decide(i) == .none)
        i.sincePrepare = 3
        check("P8: prepare ohne perform ≥ 3 s → zuklappen", W.decide(i) == .collapse(.performMissing))

        i = base
        i.escDown = true
        check("B4: Esc gedrückt → sofort zuklappen", W.decide(i) == .collapse(.escape))
        i.escDown = false
        i.sinceExitedInside = 0.1
        check("Austritt im Board 100 ms → noch warten", W.decide(i) == .none)
        i.sinceExitedInside = 0.15
        check("Austritt im Board ≥ 150 ms → zuklappen", W.decide(i) == .collapse(.exitInside))

        i = base
        i.mouseButtonDown = false
        check("Maustaste los, erstmals → noteRelease", W.decide(i) == .noteRelease)
        i.sinceRelease = 0.2
        check("Maustaste los 200 ms → warten", W.decide(i) == .none)
        i.sinceRelease = 0.5
        check("Maustaste los ≥ 500 ms ohne Drop → zuklappen", W.decide(i) == .collapse(.released))
        i.mouseButtonDown = true
        check("Maustaste wieder gedrückt → clearRelease", W.decide(i) == .clearRelease)
        check("Gründe haben Logtext", [WatchdogReason.maxDuration, .performMissing, .escape, .exitInside, .released]
            .allSatisfy { !$0.text.isEmpty })
    }

    // MARK: C2, C18, B12 – Bildschirmwahl

    private static func screens(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("fixB: " + name, ok()) }
        check("C2: kein Bildschirm → nil (kein Crash)", ScreenChoice.earScreenIndex(screenCount: 0) == nil)
        check("C18/B12: ein oder mehrere Bildschirme → Index 0 (Hauptbildschirm mit Menüleiste)",
              ScreenChoice.earScreenIndex(screenCount: 1) == 0 && ScreenChoice.earScreenIndex(screenCount: 3) == 0)
    }

    // MARK: S1 – Single Instance

    private static func singleInstance(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("fixB: " + name, ok()) }
        let id = DropboardConfig.bundleIdentifier
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        let me = InstanceInfo(pid: 500, launchDate: t0.addingTimeInterval(10))
        let older = InstanceInfo(pid: 900, launchDate: t0)
        let newer = InstanceInfo(pid: 300, launchDate: t0.addingTimeInterval(20))
        func yieldPID(_ running: [InstanceInfo], bundle: String? = id, own: InstanceInfo = me) -> Int32? {
            SingleInstance.instanceToYieldTo(ownPID: own.pid, ownLaunch: own.launchDate, bundleID: bundle, running: running)?.pid
        }
        check("S1: Bundle-ID = app.dropboard.Dropboard", id == "app.dropboard.Dropboard")
        check("S1: allein → weiterlaufen", yieldPID([me]) == nil)
        check("S1: ältere Instanz läuft → beenden (zugunsten der älteren)", yieldPID([me, older]) == 900)
        check("S1: nur neuere Instanz → weiterlaufen", yieldPID([me, newer]) == nil)
        check("S1: drei Instanzen → der ältesten weichen", yieldPID([newer, me, older]) == 900)
        check("S1: ohne Bundle-ID (swift run) → kein Check", yieldPID([me, older], bundle: nil) == nil)
        let twinA = InstanceInfo(pid: 10, launchDate: t0)
        let twinB = InstanceInfo(pid: 11, launchDate: t0)
        check("S1: gleiche Startzeit → kleinere PID bleibt, nicht beide beenden",
              yieldPID([twinA, twinB], own: twinA) == nil && yieldPID([twinA, twinB], own: twinB) == 10)
        let noDate = InstanceInfo(pid: 5, launchDate: nil)
        check("S1: fehlende Startzeit → PID entscheidet", yieldPID([me, noDate]) == 5)
    }

    // MARK: P7 – Log-Rotation

    private static func logRotation(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("fixB: " + name, ok()) }
        let limit = DropboardConfig.logRotateBytes
        check("P7: Grenze 5 MB", limit == 5 * 1024 * 1024)
        check("P7: unter 5 MB keine Rotation", !LogRotation.shouldRotate(size: limit - 1, limit: limit))
        check("P7: ab 5 MB Rotation", LogRotation.shouldRotate(size: limit, limit: limit))
        check("P7: Rotationsziel <datei>.1", LogRotation.rotatedPath("/x/dropboard.log") == "/x/dropboard.log.1")
    }
}
