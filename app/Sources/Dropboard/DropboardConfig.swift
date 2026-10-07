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

    /// E10: Drag-Hover auf dem Eselsohr bis zum Expand.
    static let expandDelay: TimeInterval = 0.3
    /// E8: Board bleibt für die 2 Drop-Frames sichtbar (2 × 1/6 s ≈ 333 ms), dann schließt es.
    /// Mit „Bewegung reduzieren“ schließt es sofort.
    static let dropCloseDelay: TimeInterval = 2 * StopMotionClock.frameDuration

    // Eselsohr (Werte wie Spike eselsohr-drop)
    static let earSize: CGFloat = 40
    static let earInsetRight: CGFloat = 12
    static let earTopGap: CGFloat = 2

    // Watchdog, solange das Board während eines Drags offen ist (wie Spike)
    static let pollInterval: TimeInterval = 0.02
    /// Maustaste los, aber kein Drop → nach dieser Zeit zuklappen.
    static let releaseGrace: TimeInterval = 0.5
    /// draggingExited, obwohl der Cursor noch im Board liegt (Esc bricht den Drag ab) → nach dieser Zeit
    /// ohne Wiedereintritt zuklappen. `nil` = Spike-Verhalten (nur draggingEnded/Maustaste).
    static let exitInsideGrace: TimeInterval? = 0.3
    static let noEnterWarnAfter: TimeInterval = 1.0
    static let updateLogInterval: TimeInterval = 0.25

    // Ansichtsmodus (Schritt 7)
    /// Ab dieser Mausbewegung (pt) wird aus einem Klick auf ein Bild ein Ziehen (Umsortieren).
    static let viewDragThreshold: CGFloat = 3
}

/// Rahmen aus der Bildschirmgeometrie (Eselsohr-Position wie Spike: visibleFrame, rechts eingerückt,
/// knapp unter der Menüleiste). MainActor, weil NSScreen/NSEvent dort benutzt werden (wie in den Spikes).
@MainActor
enum ScreenGeometry {
    static func earFrame(_ screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        return NSRect(x: vf.maxX - DropboardConfig.earInsetRight - DropboardConfig.earSize,
                      y: vf.maxY - DropboardConfig.earTopGap - DropboardConfig.earSize,
                      width: DropboardConfig.earSize, height: DropboardConfig.earSize)
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

    /// Bildschirm unter dem Mauszeiger (Report 02, Abschnitt 5), Fallback NSScreen.main.
    static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
