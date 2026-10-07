import AppKit

/// Bildschirmgrosses, nicht aktivierendes Panel (Konfiguration nach Report 02, Ergebnis Punkt 3).
final class BoardPanel: NSPanel {
    init(screen: NSScreen) {
        // .nonactivatingPanel muss im Initializer stehen (Report 02).
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        hidesOnDeactivate = false          // Default bei NSPanel ist true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        level = .statusBar                 // zuletzt setzen (Report 02: isFloatingPanel nicht verwenden)
    }

    // Spike: darf key werden (Esc, Klicks). Produktiv waere das Board waehrend des Drags nicht key.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // ⚠️ VERIFIZIEREN: Borderless-Fenster mit Level >= Menueleiste werden nicht unter die Menueleiste verschoben;
    // Override verhindert es sicherheitshalber (Signatur nicht in den Phase-0-Reports belegt).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
