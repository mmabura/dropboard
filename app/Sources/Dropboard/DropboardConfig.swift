import AppKit
import DropboardCore

/// Übergabe der Drag-Session vom Eselsohr ans Board (Report 02, Risiko T4 – auf Hardware noch offen).
enum HandoffMode: String {
    case twoPanels = "two-panels"   // Variante A: eigenes Board-Panel, orderFrontRegardless (Default)
    case grow                       // Variante B: Eselsohr-Panel wächst per setFrame auf Bildschirmgröße
}

/// Verhaltens-Konstanten an einer Stelle (Entscheidungen E1–E10).
enum DropboardConfig {
    /// T4 offen: per Startargument `--handoff grow` oder hier umschalten.
    static let defaultHandoff: HandoffMode = .twoPanels

    /// E10: Drag-Hover auf dem Eselsohr bis zum Expand – nur noch der STANDARD. Der tatsächliche Wert kommt aus
    /// `Settings.expandDelayMs` (Menüleiste → „Verzögerung bis Aufklappen“, erlaubt: `ExpandDelay.choicesMs`).
    static let defaultExpandDelayMs: Int = ExpandDelay.defaultMs
    /// E8: Board bleibt für die 2 Drop-Frames sichtbar (2 × 1/6 s ≈ 333 ms), dann schließt es.
    /// Mit „Bewegung reduzieren“ schließt es sofort.
    static let dropCloseDelay: TimeInterval = 2 * StopMotionClock.frameDuration

    // Eselsohr (Werte wie Spike eselsohr-drop)
    static let earSize: CGFloat = 40
    /// Horizontale Einrückung vom linken/rechten Bildschirmrand (Briefing: „etwas vom Rand eingerückt“).
    static let earInset: CGFloat = 12
    /// Vertikaler Abstand zur Menüleiste (oben) bzw. zum Dock/unteren Rand (unten), jeweils am visibleFrame.
    static let earEdgeGap: CGFloat = 2
    /// Standard-Ecke (Briefing: „oben rechts“). Die tatsächliche Ecke kommt aus `Settings.corner` (Menüleiste → „Ecke“).
    static let defaultCorner: EarCorner = .topRight

    // Watchdog, solange das Board während eines Drags offen ist (wie Spike)
    static let pollInterval: TimeInterval = 0.02
    /// P8: Timer-Toleranz des Watchdogs (Coalescing erlaubt, Esc/Loslassen bleiben < 25 ms).
    static let pollTolerance: TimeInterval = 0.005
    /// P8: harte Obergrenze – länger als das bleibt das Board während eines Drags nie offen (danach Zuklappen).
    static let watchdogMaxDuration: TimeInterval = 30
    /// P8: prepareForDragOperation ohne folgendes performDragOperation → nach dieser Zeit zuklappen.
    static let dropPerformTimeout: TimeInterval = 3
    /// Maustaste los, aber kein Drop → nach dieser Zeit zuklappen.
    static let releaseGrace: TimeInterval = 0.5
    /// draggingExited, obwohl der Cursor noch im Board liegt (Esc bricht den Drag ab) → nach dieser Zeit
    /// ohne Wiedereintritt zuklappen. `nil` = Spike-Verhalten (nur draggingEnded/Maustaste).
    /// B4: von 300 auf 150 ms gesenkt; Esc selbst erkennt der Watchdog zusätzlich direkt (EscapeKey).
    /// ⚠️ VERIFIZIEREN: Ein regulärer Wiedereintritt (Log `Wiedereintritt nach …ms`) liegt auf Hardware unter 150 ms.
    static let exitInsideGrace: TimeInterval? = 0.15
    /// Virtueller Tastencode Esc (kVK_Escape).
    static let escKeyCode: UInt16 = 53
    /// Ansichtsmodus: Esc-Rückfallweg per Tastenzustand, nur solange kein Dropboard-Panel key ist (C16).
    static let viewEscPollInterval: TimeInterval = 0.05

    /// S1: Bundle-ID von Dropboard.app (app/Packaging/Info.plist); ohne Bundle (swift run) kein Instanz-Check.
    static let bundleIdentifier = "app.dropboard.Dropboard"
    /// P7: Logdatei ab dieser Größe nach `<datei>.1` rotieren.
    static let logRotateBytes: UInt64 = 5 * 1024 * 1024
    static let noEnterWarnAfter: TimeInterval = 1.0
    static let updateLogInterval: TimeInterval = 0.25

    // Ansichtsmodus (Schritt 7)
    /// Ab dieser Mausbewegung (pt) wird aus einem Klick auf ein Bild ein Ziehen (Umsortieren).
    static let viewDragThreshold: CGFloat = 3
}

/// Rahmen aus der Bildschirmgeometrie (Eselsohr-Position: visibleFrame, seitlich eingerückt, knapp unter der
/// Menüleiste bzw. über dem Dock; reine Geometrie in DropboardCore.EarGeometry, Selftest für alle 4 Ecken).
/// MainActor, weil NSScreen/NSEvent dort benutzt werden (wie in den Spikes).
@MainActor
enum ScreenGeometry {
    static func earFrame(_ screen: NSScreen, corner: EarCorner) -> NSRect {
        EarGeometry.earFrame(visibleFrame: screen.visibleFrame, corner: corner, size: DropboardConfig.earSize,
                             inset: DropboardConfig.earInset, gap: DropboardConfig.earEdgeGap)
    }

    /// Board deckt den ganzen Bildschirm ab (wie Spike).
    static func boardFrame(_ screen: NSScreen) -> NSRect { screen.frame }

    /// Ablagefläche in Board-Koordinaten (oben links, y nach unten): visibleFrame minus Rand.
    static func usableArea(_ screen: NSScreen, metrics: LayoutMetrics) -> CGRect {
        usableArea(frame: screen.frame, visibleFrame: screen.visibleFrame, metrics: metrics)
    }

    static func usableArea(frame f: NSRect, visibleFrame vf: NSRect, metrics: LayoutMetrics) -> CGRect {
        let m = CGFloat(metrics.margin)
        let visible = CGRect(x: vf.minX - f.minX, y: f.maxY - vf.maxY, width: vf.width, height: vf.height)
        return visible.insetBy(dx: m, dy: m)
    }

    /// C2/C18/B12: Bildschirm fürs Eselsohr = primärer Bildschirm (mit Menüleiste), `nil` ohne Bildschirm (kein Crash).
    /// Apple-Doku `NSScreen.screens` [Report 02, A37]: „The screen at index 0 … corresponds to the primary screen …
    /// This is the screen that contains the menu bar“. `NSScreen.main` ist dagegen der Bildschirm mit dem Key-Window
    /// (A38), also der der Ursprungs-App – dafür ungeeignet.
    /// ⚠️ VERIFIZIEREN: Zitat aus der Apple-Doku zu `screens` hier aus dem Gedächtnis, im Report 02 nur verlinkt.
    static func primaryScreen() -> NSScreen? {
        let screens = NSScreen.screens
        return ScreenChoice.earScreenIndex(screenCount: screens.count).map { screens[$0] }
    }
}

/// Reine Bildschirmwahl (Selftest FixB).
enum ScreenChoice {
    /// Index in `NSScreen.screens` fürs Eselsohr: 0 (Hauptbildschirm mit Menüleiste) oder nil ohne Bildschirm.
    static func earScreenIndex(screenCount: Int) -> Int? {
        screenCount > 0 ? 0 : nil
    }
}

/// Esc-Taste per Tastenzustand abfragen (B4 während des Drags, C16 als Rückfallweg im Ansichtsmodus).
/// Kein Event-Monitor: ein globaler KeyDown-Monitor bräuchte Accessibility (Report 01, Abschnitt 6) und wird
/// deshalb NICHT verwendet.
/// ⚠️ VERIFIZIEREN: `CGEventSource.keyState(.combinedSessionState, key:)` liefert den echten Zustand von Esc OHNE
/// Eingabeüberwachung/Accessibility und löst keinen TCC-Dialog aus. Nicht belegt. Nachweis auf Hardware: Log
/// `[HANDOFF] Esc erkannt (Tastenzustand)` bzw. `[VIEW] Esc erkannt (Tastenzustand-Rückfallweg)`; fehlt die Zeile
/// bei gedrückter Esc-Taste, liefert die API ohne Berechtigung nichts (dann greifen exitInsideGrace bzw. Klick).
enum EscapeKey {
    static func isDown() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(DropboardConfig.escKeyCode))
    }
}

/// Phasen des Zustandsautomaten (DragCoordinator). Top-Level und ohne Actor, damit der Selftest sie benutzen kann.
enum DragPhase: String {
    case idle, hovering, expanded, collapsing, dropClosing, viewing, viewClosing

    /// Teil einer Drag-Session (Eselsohr/Board): solange läuft die Aktivitäts-Assertion (P14).
    var isDragSession: Bool {
        switch self {
        case .hovering, .expanded, .collapsing, .dropClosing: return true
        case .idle, .viewing, .viewClosing: return false
        }
    }
}

/// Reine Entscheidungen des Zustandsautomaten (Selftest FixB).
enum DragRules {
    /// Antwort des Eselsohrs (two-panels, oder grow vor dem Expand) auf draggingEntered/draggingUpdated –
    /// nicht im Ansichtsmodus (eigener Zweig).
    enum EarAnswer: Equatable {
        case reject        // [] – nichts passiert
        case startHover    // .copy, Phase → hovering, Expand-Timer starten
        case keepHover     // .copy, Timer läuft schon
        case boardDrop     // .copy: Board ist offen (expanded), ein Drop hier gilt als Board-Drop an Cursor (C1)
    }

    static func earDrag(phase: DragPhase, isImage: Bool) -> EarAnswer {
        guard isImage else { return .reject }
        switch phase {
        case .idle: return .startHover          // C12: auch aus draggingUpdated, wenn die Phase inzwischen idle ist
        case .hovering: return .keepHover
        case .expanded: return .boardDrop       // C1: nicht mehr hart ablehnen
        case .collapsing, .dropClosing, .viewing, .viewClosing: return .reject
        }
    }

    enum DropKind: String {
        case viewing = "Drop im Ansichtsmodus"
        case board = "Board-Drop"
        case earWhileOpen = "Drop auf Eselsohr trotz offenem Board (Handoff nicht übernommen) → Board-Drop an Cursor"
        case quick = "Quick-Drop"
        case late = "Drop während Zuklappen → wie Quick-Drop"

        /// Board-Drop an Cursor (mit dropClosing), sonst nächste freie Stelle bzw. Ansichtsmodus.
        var isBoardDropAtCursor: Bool { self == .board || self == .earWhileOpen }
    }

    static func dropKind(phase: DragPhase, onBoardTarget: Bool) -> DropKind {
        switch phase {
        case .viewing: return .viewing
        case .expanded: return onBoardTarget ? .board : .earWhileOpen
        case .idle, .hovering: return .quick
        case .collapsing, .dropClosing, .viewClosing: return .late
        }
    }
}

/// Watchdog während des offenen Boards (P8, B4): reine Entscheidung pro Tick (Selftest FixB).
struct WatchdogInput {
    var elapsed: TimeInterval                 // seit Expand
    var dropReceived = false
    var sincePrepare: TimeInterval?           // seit prepareForDragOperation
    var sinceExitedInside: TimeInterval?      // seit draggingExited mit Cursor im Board
    var mouseButtonDown = true
    var sinceRelease: TimeInterval?           // seit erstmals „Maustaste los“ gesehen
    var escDown = false
}

enum WatchdogReason: Equatable {
    case maxDuration, performMissing, escape, exitInside, released

    var text: String {
        switch self {
        case .maxDuration: return "Watchdog-Obergrenze \(Int(DropboardConfig.watchdogMaxDuration)) s erreicht"
        case .performMissing: return "prepareForDragOperation ohne performDragOperation in \(Int(DropboardConfig.dropPerformTimeout)) s"
        case .escape: return "Esc erkannt (Tastenzustand)"
        case .exitInside: return "Drag im Board abgebrochen (Esc), kein Wiedereintritt in \(Int((DropboardConfig.exitInsideGrace ?? 0) * 1000))ms"
        case .released: return "Maustaste losgelassen, kein Drop innerhalb \(Int(DropboardConfig.releaseGrace * 1000))ms"
        }
    }
}

enum WatchdogAction: Equatable {
    case none, noteRelease, clearRelease
    case collapse(WatchdogReason)
}

enum WatchdogRules {
    static func decide(_ i: WatchdogInput) -> WatchdogAction {
        if i.elapsed >= DropboardConfig.watchdogMaxDuration { return .collapse(.maxDuration) }
        if i.dropReceived {
            if let p = i.sincePrepare, p >= DropboardConfig.dropPerformTimeout { return .collapse(.performMissing) }
            return .none
        }
        if i.escDown { return .collapse(.escape) }
        if let e = i.sinceExitedInside, let grace = DropboardConfig.exitInsideGrace, e >= grace { return .collapse(.exitInside) }
        if !i.mouseButtonDown {
            guard let r = i.sinceRelease else { return .noteRelease }
            return r >= DropboardConfig.releaseGrace ? .collapse(.released) : .none
        }
        return i.sinceRelease == nil ? .none : .clearRelease
    }
}

/// S1: Single-Instance-Schutz (reine Logik, Selftest FixB).
struct InstanceInfo {
    let pid: Int32
    let launchDate: Date?
}

enum SingleInstance {
    /// Andere Instanz, der diese weichen soll (nil = weiterlaufen). Ohne Bundle-ID (swift run) kein Check.
    /// Die ältere Instanz gewinnt; bei gleicher oder fehlender Startzeit die kleinere PID – so beenden sich zwei
    /// gleichzeitig gestartete Instanzen nicht gegenseitig.
    static func instanceToYieldTo(ownPID: Int32, ownLaunch: Date?, bundleID: String?, running: [InstanceInfo]) -> InstanceInfo? {
        guard let id = bundleID, !id.isEmpty else { return nil }
        return running
            .filter { $0.pid != ownPID && wins($0, overPID: ownPID, launch: ownLaunch) }
            .min { wins($0, overPID: $1.pid, launch: $1.launchDate) }
    }

    static func wins(_ other: InstanceInfo, overPID pid: Int32, launch: Date?) -> Bool {
        if let o = other.launchDate, let s = launch, o != s { return o < s }
        return other.pid < pid
    }
}

/// P7: Rotation der Logdatei (reine Logik, Selftest FixB).
enum LogRotation {
    static func shouldRotate(size: UInt64, limit: UInt64) -> Bool { size >= limit }
    static func rotatedPath(_ path: String) -> String { path + ".1" }
}
