import AppKit
import QuartzCore

/// Panel-Konfiguration genau wie Spike eselsohr-drop (Report 02, Ergebnis 3). Für Eselsohr UND Board identisch.
final class DropboardPanel: NSPanel {
    // Keine eigenen designated inits → alle NSWindow-Initializer werden geerbt; die styleMask
    // geht trotzdem direkt in den Initializer (Report 02: nachträgliches Setzen evtl. wirkungslos).
    convenience init(panelFrame: NSRect) {
        self.init(contentRect: panelFrame,
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
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        level = .statusBar   // zuletzt setzen (Report 02, Hinweis zu isFloatingPanel)
    }

    /// C3/C16: key-fähig NUR im Ansichtsmodus (Esc, Backspace/Entf über den lokalen Key-Monitor in ViewModeController).
    /// BoardPresenter setzt das Flag beim Öffnen des Ansichtsmodus und nimmt es beim Schließen VOR dem orderOut
    /// zurück – sonst macht AppKit das sichtbare Eselsohr zum nächsten Key-Window und Tasten landen bei Dropboard
    /// statt in der Ursprungs-App. Im Ruhezustand und während eines Drags nie key (Phase 0: dort nicht nötig).
    /// ⚠️ VERIFIZIEREN: Ein Klick auf ein Panel mit canBecomeKey == false liefert trotzdem mouseDown
    /// (acceptsFirstMouse == true) – Log `[WIN] Klick auf ear ohne Drag → Ansichtsmodus`.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Layer-Hosting-View und Drop-Ziel (Muster aus Spike eselsohr-drop/DropView und board-paper/BoardView:
/// erst `layer` setzen, dann `wantsLayer = true`). Keine Subviews, kein draw(_:).
/// Alle NSDraggingDestination-Aufrufe gehen 1:1 an den DragCoordinator.
final class DropTargetView: NSView {
    enum Role { case ear, board }

    let role: Role
    weak var coordinator: DragCoordinator?
    var updateCount = 0
    var lastUpdateLog: TimeInterval = 0

    init(role: Role, size: NSSize, hostedLayer: CALayer) {
        self.role = role
        super.init(frame: NSRect(origin: .zero, size: size))
        hostedLayer.frame = bounds   // ⚠️ VERIFIZIEREN (aus Spike board-paper): AppKit setzt den Root-Frame nicht selbst
        layer = hostedLayer
        wantsLayer = true
        registerForDraggedTypes(ImageImporter.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("nicht verwendet") }

    // MARK: Maus

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Ansichtsmodus (Schritt 7): Klick aufs Eselsohr öffnet/schließt; auf dem Board Auswahl und Ziehen.
    override func mouseDown(with event: NSEvent) { coordinator?.mouseDown(self, event) }
    // ⚠️ VERIFIZIEREN: mouseDragged/mouseUp kommen in keinem Spike vor; erwartet: nach mouseDown auf einem nicht
    // aktivierenden Panel einer inaktiven App laufen sie an dieselbe View (Log `[VIEW] Umsortieren Start`).
    override func mouseDragged(with event: NSEvent) { coordinator?.mouseDragged(self, event) }
    override func mouseUp(with event: NSEvent) { coordinator?.mouseUp(self, event) }

    // MARK: NSDraggingDestination (Signaturen wie Spike)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { coordinator?.dragEntered(self, sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { coordinator?.dragUpdated(self, sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { coordinator?.dragExited(self, sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { coordinator?.prepareDrop(self, sender) ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { coordinator?.performDrop(self, sender) ?? false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { coordinator?.concludeDrop(self, sender) }
    // ⚠️ VERIFIZIEREN (aus Spike): draggingEnded(_:) mit nicht-optionalem Parameter; Aufruf am Ziel nicht belegt.
    override func draggingEnded(_ sender: NSDraggingInfo) { coordinator?.dragEnded(self, sender) }
}
