import AppKit
import QuartzCore
import DropboardCore

/// Fenster: Eselsohr-Panel (immer sichtbar) und Board (Handoff-Variante two-panels oder grow).
/// Öffnen/Schließen mit dem Realtime-Pfad; der Stop-Motion-Pfad liegt bei den Items (BoardController).
/// Nie NSApp.activate / makeKeyAndOrderFront: nur orderFrontRegardless/orderOut (Report 02).
/// Für Schritt 7 (Ansichtsmodus) kommt hier `openForViewing()` dazu (Stop-Motion-Reveal, 3 Frames, ohne Abdunklung).
@MainActor
final class BoardPresenter {
    let handoff: HandoffMode
    let scene: BoardScene
    let ear: DropboardPanel
    let earView: DropTargetView
    /// Nur two-panels: eigenes, vorab erzeugtes und verstecktes Board-Panel (wie Spike).
    private(set) var board: DropboardPanel?
    private(set) var boardView: DropTargetView?
    private let earLayer: CALayer
    /// Nur grow: Eselsohr und Board liegen in derselben View/demselben Panel (wie Spike).
    private let growRoot: CALayer
    private let noiseTile: CGImage?
    private(set) var earFrame: NSRect
    private(set) var boardFrame: NSRect
    private(set) var usableArea: CGRect
    private(set) var isOpen = false
    private var closeToken = 0

    init(handoff: HandoffMode, screen: NSScreen, scene: BoardScene, noiseTile: CGImage?) {
        // Nur lokale Werte benutzen, bis alle gespeicherten Eigenschaften gesetzt sind.
        let earFrame = ScreenGeometry.earFrame(screen)
        let boardFrame = ScreenGeometry.boardFrame(screen)
        let earLayer = CALayer()
        let growRoot = CALayer()
        self.handoff = handoff
        self.scene = scene
        self.noiseTile = noiseTile
        self.earFrame = earFrame
        self.boardFrame = boardFrame
        self.earLayer = earLayer
        self.growRoot = growRoot
        usableArea = ScreenGeometry.usableArea(screen, metrics: LayoutMetrics.standard)
        ear = DropboardPanel(panelFrame: earFrame)

        switch handoff {
        case .twoPanels:
            earView = DropTargetView(role: .ear, size: earFrame.size, hostedLayer: earLayer)
            // Vorab erzeugt und versteckt; Expand kostet dann nur orderFrontRegardless (Report 02 ⚠️13).
            let b = DropboardPanel(panelFrame: boardFrame)
            let bv = DropTargetView(role: .board, size: boardFrame.size, hostedLayer: scene.root)
            b.contentView = bv
            b.orderOut(nil)
            board = b
            boardView = bv
        case .grow:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            growRoot.addSublayer(earLayer)
            growRoot.addSublayer(scene.root)
            scene.root.isHidden = true
            CATransaction.commit()
            earView = DropTargetView(role: .ear, size: earFrame.size, hostedLayer: growRoot)
        }
        ear.contentView = earView
        updateEarArt(scale: screen.backingScaleFactor)
    }

    func attach(_ coordinator: DragCoordinator) {
        earView.coordinator = coordinator
        boardView?.coordinator = coordinator
    }

    func showEar() {
        ear.orderFrontRegardless()
    }

    // MARK: Koordinaten

    /// Bildschirmpunkt → Board-Koordinaten (oben links, y nach unten).
    func boardPoint(fromScreen p: NSPoint) -> CGPoint {
        CGPoint(x: p.x - boardFrame.minX, y: boardFrame.maxY - p.y)
    }

    /// Eselsohr-Ecke (oben rechts) in Layer-Koordinaten des Papiers: Anker für Aufblättern/Zuklappen.
    private var anchor: CGPoint {
        CGPoint(x: earFrame.maxX - boardFrame.minX, y: earFrame.maxY - boardFrame.minY)
    }

    // MARK: Öffnen / Schließen

    /// Drag-Expand: Board sofort in Endgröße sichtbar, Aufblättern als Realtime-Maske (oder sofort bei Reduce Motion).
    /// Rückgabe: wurde animiert?
    @discardableResult
    func openForDrag(reduceMotion: Bool) -> Bool {
        closeToken += 1
        isOpen = true
        scene.setDimmed(true)
        var animated = false
        switch handoff {
        case .twoPanels:
            board?.setFrame(boardFrame, display: false)
            animated = RealtimeMotion.reveal(scene.sheet, from: anchor, reduceMotion: reduceMotion)
            board?.orderFrontRegardless()
        case .grow:
            withoutImplicitAnimations {
                growRoot.frame = CGRect(origin: .zero, size: boardFrame.size)
                earLayer.isHidden = true
                scene.root.isHidden = false
            }
            animated = RealtimeMotion.reveal(scene.sheet, from: anchor, reduceMotion: reduceMotion)
            ear.setFrame(boardFrame, display: true)
            withoutImplicitAnimations { growRoot.frame = CGRect(origin: .zero, size: boardFrame.size) }
        }
        return animated
    }

    /// Zuklappen ohne Drop (Realtime, ~200 ms zur Eselsohr-Ecke), dann orderOut. `completion` danach.
    @discardableResult
    func collapse(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) -> Bool {
        guard isOpen else {
            completion()
            return false
        }
        closeToken += 1
        let token = closeToken
        return RealtimeMotion.collapse(scene.sheet, to: anchor, reduceMotion: reduceMotion) { [weak self] in
            guard let self = self, self.closeToken == token else { return }
            self.closeImmediately()
            completion()
        }
    }

    /// Sofort ausblenden (nach den Drop-Frames, E8). Erst orderOut, dann Maske weg – sonst blitzt das Board auf.
    func closeImmediately() {
        closeToken += 1
        switch handoff {
        case .twoPanels:
            board?.orderOut(nil)
        case .grow:
            ear.setFrame(earFrame, display: true)
            withoutImplicitAnimations {
                growRoot.frame = CGRect(origin: .zero, size: earFrame.size)
                scene.root.isHidden = true
                earLayer.isHidden = false
            }
        }
        RealtimeMotion.clear(scene.sheet)
        scene.setDimmed(false)
        isOpen = false
    }

    // MARK: Bildschirmwechsel

    func relayout(screen: NSScreen) {
        if isOpen { closeImmediately() }
        earFrame = ScreenGeometry.earFrame(screen)
        boardFrame = ScreenGeometry.boardFrame(screen)
        usableArea = ScreenGeometry.usableArea(screen, metrics: LayoutMetrics.standard)
        scene.resize(size: boardFrame.size, scale: screen.backingScaleFactor)
        ear.setFrame(earFrame, display: true)
        board?.setFrame(boardFrame, display: false)
        updateEarArt(scale: screen.backingScaleFactor)
    }

    private func updateEarArt(scale: CGFloat) {
        let size = earFrame.size
        withoutImplicitAnimations {
            earLayer.frame = CGRect(origin: .zero, size: size)
            earLayer.contentsScale = scale
            earLayer.contents = PaperArt.earImage(size: size, scale: scale, noiseTile: noiseTile)
            earLayer.opacity = PaperStyle.earOpacity   // gedämpft, kein Schatten
            if handoff == .grow && !isOpen { growRoot.frame = CGRect(origin: .zero, size: size) }
        }
    }
}
