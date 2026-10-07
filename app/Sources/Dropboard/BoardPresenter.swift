import AppKit
import QuartzCore
import DropboardCore

/// Fenster: Eselsohr-Panel (immer sichtbar) und Board (Handoff-Variante two-panels oder grow).
/// Öffnen/Schließen mit dem Realtime-Pfad; der Stop-Motion-Pfad liegt bei den Items (BoardController).
/// Nie NSApp.activate / makeKeyAndOrderFront: nur orderFrontRegardless/orderOut (Report 02).
/// Ansichtsmodus (Schritt 7): `openForViewing`/`closeViewing` mit dem Stop-Motion-Pfad (StopMotionSheet, 3 Frames),
/// ohne Abdunklung; das Board-Panel wird dafür key (makeKey), die App wird nicht aktiviert.
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
    /// Ansichtsmodus offen (Board per Klick geöffnet, nicht per Drag)
    private(set) var isViewing = false
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
                // Ansichtsmodus hatte das Eselsohr als Ecke über das Board gelegt
                earLayer.frame = CGRect(origin: .zero, size: earFrame.size)
                earLayer.zPosition = 0
            }
        }
        RealtimeMotion.clear(scene.sheet)
        StopMotionSheet.clear(scene.sheet)
        scene.setDimmed(false)
        isOpen = false
        isViewing = false
    }

    // MARK: Ansichtsmodus (Schritt 7, Stop-Motion-Pfad)

    /// Eselsohr-Rahmen in Layer-Koordinaten des Boards (y nach oben).
    private var earRectInBoard: CGRect {
        CGRect(x: earFrame.minX - boardFrame.minX, y: earFrame.minY - boardFrame.minY,
               width: earFrame.width, height: earFrame.height)
    }

    /// Klick aufs Eselsohr: Board ohne Abdunklung öffnen, Aufblättern als Stop-Motion (3 Frames, reveal) aus der
    /// Eselsohr-Ecke (Reduce Motion: sofort). Das Eselsohr bleibt sichtbar über dem Board (zum Schließen per Klick).
    /// Das Board-Panel wird key (Esc/Backspace), die App wird NICHT aktiviert (kein NSApp.activate, kein
    /// makeKeyAndOrderFront). Rückgabe: der abgespielte Plan (fürs Log).
    @discardableResult
    func openForViewing(options: PlanOptions, using rng: inout SplitMix64) -> StopMotionPlan {
        closeToken += 1
        isOpen = true
        isViewing = true
        scene.setDimmed(false)   // Papier im Ansichtsmodus nicht abgedunkelt
        RealtimeMotion.clear(scene.sheet)
        let plan = ViewModeSequences.open(target: StopMotionSheet.fullPose(anchor: anchor), options: options, using: &rng)
        switch handoff {
        case .twoPanels:
            board?.setFrame(boardFrame, display: false)
            StopMotionSheet.play(plan, on: scene.sheet, anchor: anchor, removeMaskAfter: true)
            board?.orderFrontRegardless()
            ear.orderFrontRegardless()   // gleiches Level, zuletzt nach vorn → Eselsohr liegt über dem Board
            // ⚠️ VERIFIZIEREN: makeKey() auf einem nicht aktivierenden Panel einer inaktiven App macht es key
            // (Tastatur) ohne die App zu aktivieren. Belegt ist nur: Klick macht das Panel key (Spike eselsohr-drop).
            // Fällt es aus, bleibt das Eselsohr nach dem Klick key – der lokale Key-Monitor greift dann trotzdem.
            board?.makeKey()
        case .grow:
            withoutImplicitAnimations {
                growRoot.frame = CGRect(origin: .zero, size: boardFrame.size)
                scene.root.isHidden = false
                earLayer.frame = earRectInBoard
                earLayer.zPosition = 1     // Eselsohr als Ecke über dem Papier
                earLayer.isHidden = false
            }
            StopMotionSheet.play(plan, on: scene.sheet, anchor: anchor, removeMaskAfter: true)
            ear.setFrame(boardFrame, display: true)
            withoutImplicitAnimations { growRoot.frame = CGRect(origin: .zero, size: boardFrame.size) }
            ear.makeKey()   // ⚠️ VERIFIZIEREN: wie oben (grow: das Eselsohr-Panel ist das Board)
        }
        return plan
    }

    /// Schließen: reveal rückwärts als Stop-Motion (3 Frames), dann orderOut. Reduce Motion: sofort.
    /// `completion` nach dem Ausblenden. Rückgabe: der abgespielte Plan (fürs Log).
    @discardableResult
    func closeViewing(options: PlanOptions, using rng: inout SplitMix64,
                      completion: @escaping @MainActor () -> Void) -> StopMotionPlan {
        let plan = ViewModeSequences.close(target: StopMotionSheet.fullPose(anchor: anchor), options: options, using: &rng)
        guard isOpen else {
            completion()
            return plan
        }
        guard plan.isAnimated else {
            closeImmediately()
            completion()
            return plan
        }
        closeToken += 1
        let token = closeToken
        StopMotionSheet.play(plan, on: scene.sheet, anchor: anchor, removeMaskAfter: false)
        afterDelay(plan.duration) { [weak self] in
            guard let self = self, self.closeToken == token else { return }
            self.closeImmediately()   // Model-Wert der Maske = „weg“, deshalb blitzt vor dem orderOut nichts auf
            completion()
        }
        return plan
    }

    /// Liegt ein Bildschirmpunkt auf dem Eselsohr? (Ansichtsmodus: Klick dort schließt, auch bei grow,
    /// wo das Eselsohr-Panel selbst das Board ist.)
    func isOnEar(screenPoint p: NSPoint) -> Bool {
        earFrame.contains(p)
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
