import AppKit

/// Panel-Konfiguration genau nach Report 02, Ergebnis 3. Für Eselsohr UND Board identisch.
final class SpikePanel: NSPanel {
    // Keine eigenen designated inits → alle NSWindow-Initializer werden geerbt; die styleMask
    // geht trotzdem direkt in den Initializer (Report 02: nachträgliches Setzen evtl. wirkungslos).
    convenience init(spikeFrame: NSRect) {
        self.init(contentRect: spikeFrame,
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: false)
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        animationBehavior = .none
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        level = .statusBar   // zuletzt setzen (Report 02, Hinweis zu isFloatingPanel)
    }

    override var canBecomeKey: Bool { true }    // Esc per lokalem Key-Monitor nach Klick
    override var canBecomeMain: Bool { false }
}

/// Drop-Ziel. Zeichnet entweder das Eselsohr oder das Board (grow-Variante: dieselbe View).
/// Alle NSDraggingDestination-Aufrufe gehen 1:1 an den AppController.
final class DropView: NSView {
    enum Role { case ear, board }

    var role: Role = .ear
    weak var controller: AppController?
    var boardLabel = ""
    var updateCount = 0
    var lastUpdateLog: TimeInterval = 0
    var showsBoard = false { didSet { needsDisplay = true } }

    // MARK: Zeichnen (kein Feinschliff – Messinstrument)

    private static let paper = NSColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 0.85)
    private static let foldLine = NSColor(srgbRed: 0.78, green: 0.75, blue: 0.68, alpha: 0.9)

    override func draw(_ dirtyRect: NSRect) { if showsBoard { drawBoard() } else { drawEar() } }

    /// Umgeknicktes Papiereck: sichtbar ist die Lasche (Dreieck unten links), oben rechts ist „weg“.
    // ⚠️ VERIFIZIEREN: Ob Drags auch über den transparenten Pixeln (oberes rechtes Dreieck) ankommen.
    private func drawEar() {
        let w = bounds.width, h = bounds.height
        let flap = NSBezierPath()
        flap.move(to: NSPoint(x: 0, y: h))
        flap.line(to: NSPoint(x: w, y: 0))
        flap.line(to: NSPoint(x: 0, y: 0))
        flap.close()
        DropView.paper.setFill()
        flap.fill()
        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: 0, y: h))
        fold.line(to: NSPoint(x: w, y: 0))
        fold.lineWidth = 1
        DropView.foldLine.setStroke()
        fold.stroke()
    }

    private func drawBoard() {
        NSColor(white: 0, alpha: 0.25).setFill()
        NSBezierPath(rect: bounds).fill()
        let sheet = bounds.insetBy(dx: 48, dy: 48)
        DropView.paper.setFill()
        NSBezierPath(rect: sheet).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor(white: 0.3, alpha: 1)
        ]
        (boardLabel as NSString).draw(at: NSPoint(x: sheet.minX + 24, y: sheet.maxY - 40), withAttributes: attrs)
    }

    // MARK: Maus

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { controller?.clicked(self) }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragEntered(self, sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragUpdated(self, sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.dragExited(self, sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.prepareDrop(self, sender) ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.performDrop(self, sender) ?? false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { controller?.concludeDrop(self, sender) }
    // ⚠️ VERIFIZIEREN: Signatur draggingEnded(_:) mit nicht-optionalem Parameter (aktuelles SDK); Aufruf am Ziel nicht in Report 02 belegt.
    override func draggingEnded(_ sender: NSDraggingInfo) { controller?.dragEnded(self, sender) }
}
