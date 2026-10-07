import AppKit
import DropboardCore

/// Zustandsautomat für Drag-Sessions auf Eselsohr und Board (Logik aus Spike eselsohr-drop/AppController).
///
///   idle ──draggingEntered(ear, Bild)──▶ hovering ──300 ms (E10)──▶ expanded ──performDrop(board)──▶ dropClosing ──dropCloseDelay──▶ idle
///                                          │ performDrop(ear) = Quick-Drop ▶ idle          │ Exit/Ende/Esc ohne Drop
///                                          │ draggingExited ▶ idle                         ▼
///                                                                                       collapsing ──200 ms Realtime──▶ idle
///
/// Ansichtsmodus (Schritt 7, Details in ViewModeController):
///   idle ──Klick aufs Eselsohr──▶ viewing ──Esc / Klick aufs Eselsohr──▶ viewClosing ──3 Frames Stop-Motion──▶ idle
///   In `viewing` landet ein fremder Drag (Bild) auf Eselsohr oder Board per Drop an Cursor; das Board bleibt offen.
@MainActor
final class DragCoordinator: NSObject {
    enum Phase: String {
        case idle, hovering, expanded, collapsing, dropClosing, viewing, viewClosing
    }

    private let presenter: BoardPresenter
    private let board: BoardController
    private let importer: ImageImporter
    private let motion: MotionPreferences
    private let diagnostics: Diagnostics
    private let viewMode: ViewModeController
    private(set) var phase: Phase = .idle

    // Drag-Session / Expand (wie Spike)
    private var sessionSeq = Int.min
    private var dropReceived = false
    private var expandAt: TimeInterval = 0
    private var mouseAtExpand = NSPoint.zero
    private var boardReached = false
    private var mouseMovedLogged = false
    private var noEnterWarned = false
    private var releaseSeenAt: TimeInterval?
    private var exitedInsideAt: TimeInterval?
    private var updateLoggedAfterExpand = Set<String>()
    private var pollTimer: Timer?
    /// Ansichtsmodus: nimmt der aktuelle fremde Drag ein Bild mit? (in draggingEntered bestimmt)
    private var viewDragAccepts = false

    init(presenter: BoardPresenter, board: BoardController, importer: ImageImporter,
         motion: MotionPreferences, diagnostics: Diagnostics) {
        self.presenter = presenter
        self.board = board
        self.importer = importer
        self.motion = motion
        self.diagnostics = diagnostics
        viewMode = ViewModeController(presenter: presenter, board: board, motion: motion, diagnostics: diagnostics)
        super.init()
        viewMode.coordinator = self
    }

    // MARK: Maus (Klick aufs Eselsohr, Ansichtsmodus)

    func mouseDown(_ view: DropTargetView, _ event: NSEvent) {
        let screen = screenPoint(view, event)
        switch phase {
        case .idle:
            guard view.role == .ear else { return }
            Log.line("[WIN]", "Klick auf \(name(of: view)) ohne Drag → Ansichtsmodus")
            diagnostics.logFocus("nach Klick")
            phase = .viewing
            viewMode.open(reason: "Klick aufs Eselsohr")
        case .viewing:
            if presenter.isOnEar(screenPoint: screen) {
                closeViewing(reason: "Klick aufs Eselsohr")
            } else {
                viewMode.mouseDown(at: presenter.boardPoint(fromScreen: screen))
            }
        default:
            Log.line("[VIEW]", "Klick auf \(name(of: view)) ignoriert phase=\(phase.rawValue)")
        }
    }

    func mouseDragged(_ view: DropTargetView, _ event: NSEvent) {
        guard phase == .viewing else { return }
        viewMode.mouseDragged(to: presenter.boardPoint(fromScreen: screenPoint(view, event)))
    }

    func mouseUp(_ view: DropTargetView, _ event: NSEvent) {
        guard phase == .viewing else { return }
        viewMode.mouseUp(at: presenter.boardPoint(fromScreen: screenPoint(view, event)))
    }

    /// Esc (über ViewModeController) oder Klick aufs Eselsohr.
    func closeViewing(reason: String) {
        guard phase == .viewing else { return }
        phase = .viewClosing
        viewMode.close(reason: reason) { [weak self] in
            guard let self = self, self.phase == .viewClosing else { return }
            self.phase = .idle
        }
    }

    /// Bildschirmwechsel o. Ä.: Ansichtsmodus ohne Animation beenden (vor BoardPresenter.relayout aufrufen).
    func endViewingImmediately(reason: String) {
        guard phase == .viewing || phase == .viewClosing else { return }
        viewMode.endImmediately(reason: reason)
        phase = .idle
    }

    // MARK: Hilfen

    private var handoff: HandoffMode { presenter.handoff }

    /// grow: nach dem Expand ist die Eselsohr-View selbst das Board. Im Ansichtsmodus zählt auch das Eselsohr
    /// (liegt bei two-panels über dem Board) als Board.
    private func isBoardTarget(_ view: DropTargetView) -> Bool {
        view.role == .board || (handoff == .grow && presenter.isOpen) || phase == .viewing
    }

    private func name(of view: DropTargetView) -> String {
        if view.role == .board { return "board" }
        return (handoff == .grow && presenter.isOpen) ? "ear(grown)" : "ear"
    }

    private func sinceExpand() -> String {
        phase == .expanded || phase == .collapsing || phase == .dropClosing ? " +\(Log.ms(since: expandAt))ms nach Expand" : ""
    }

    private func screenPoint(_ view: DropTargetView, _ info: NSDraggingInfo) -> NSPoint {
        guard let w = view.window else { return info.draggingLocation }
        return w.convertPoint(toScreen: info.draggingLocation)
    }

    private func screenPoint(_ view: DropTargetView, _ event: NSEvent) -> NSPoint {
        guard let w = view.window else { return NSEvent.mouseLocation }
        return w.convertPoint(toScreen: event.locationInWindow)
    }

    private func mouseMovedSinceExpand() -> Bool { NSEvent.mouseLocation != mouseAtExpand }

    /// Jitter nie während eines Drags: Stop-Motion-Optionen gibt es nur nach dem Drop.
    private func postDropMotionOptions() -> PlanOptions {
        PlanOptions(jitter: phase == .dropClosing, reduceMotion: motion.effective, backingScale: Double(board.scene.scale))
    }

    // MARK: Drag-Ereignisse (von DropTargetView)

    func dragEntered(_ view: DropTargetView, _ info: NSDraggingInfo) -> NSDragOperation {
        let win = name(of: view)
        let pos = fmt(screenPoint(view, info))
        if phase == .viewing {
            return viewDragEntered(view, info, win: win, pos: pos)
        }
        if isBoardTarget(view) {
            guard phase == .expanded else {
                Log.line("[HANDOFF]", "draggingEntered win=\(win) ignoriert phase=\(phase.rawValue)")
                return []
            }
            boardReached = true
            exitedInsideAt = nil
            Log.line("[HANDOFF]", "draggingEntered win=\(win)\(sinceExpand()) mausBewegtSeitExpand=\(mouseMovedSinceExpand()) "
                + "pos=\(pos) maus=\(fmt(NSEvent.mouseLocation))")
            return .copy
        }
        guard phase == .idle || phase == .hovering else {
            Log.line("[HANDOFF]", "draggingEntered win=\(win) ignoriert phase=\(phase.rawValue)")
            return []
        }
        let seq = info.draggingSequenceNumber
        if seq != sessionSeq {
            sessionSeq = seq
            dropReceived = false
            Log.line("[HANDOFF]", "neue Drag-Session seq=\(seq)")
            importer.dumpPasteboard(info, phase: "draggingEntered", window: win)
        }
        guard importer.looksLikeImage(info) else {
            Log.line("[PB]", "kein Bild im Drag → Eselsohr bleibt still (kein Expand, kein Drop)")
            return []
        }
        phase = .hovering
        Log.line("[HANDOFF]", "draggingEntered win=\(win) pos=\(pos) → Expand-Timer \(Int(DropboardConfig.expandDelay * 1000))ms")
        scheduleExpand()
        return .copy
    }

    func dragUpdated(_ view: DropTargetView, _ info: NSDraggingInfo) -> NSDragOperation {
        view.updateCount += 1
        if phase == .viewing { return viewDragAccepts ? .copy : [] }
        guard isBoardTarget(view) else { return phase == .hovering ? .copy : [] }
        guard phase == .expanded else { return [] }
        boardReached = true
        exitedInsideAt = nil
        let win = name(of: view)
        let first = !updateLoggedAfterExpand.contains(win)
        if first || Log.now - view.lastUpdateLog >= DropboardConfig.updateLogInterval {
            updateLoggedAfterExpand.insert(win)
            view.lastUpdateLog = Log.now
            Log.line("[HANDOFF]", "draggingUpdated\(first ? " (erstes nach Expand)" : "") win=\(win)\(sinceExpand()) "
                + "mausBewegtSeitExpand=\(mouseMovedSinceExpand()) pos=\(fmt(screenPoint(view, info))) n=\(view.updateCount)")
        }
        return .copy
    }

    func dragExited(_ view: DropTargetView, _ info: NSDraggingInfo?) {
        let win = name(of: view)
        let mouse = NSEvent.mouseLocation
        if phase == .viewing {
            Log.line("[HANDOFF]", "draggingExited win=\(win) phase=viewing maus=\(fmt(mouse)) (Board bleibt offen)")
            view.updateCount = 0
            return
        }
        if !isBoardTarget(view) {
            if phase == .hovering {
                cancelExpand()
                phase = .idle
                Log.line("[HANDOFF]", "draggingExited win=\(win) vor Expand → Expand abgebrochen updates=\(view.updateCount) maus=\(fmt(mouse))")
            } else {
                Log.line("[HANDOFF]", "draggingExited win=\(win)\(sinceExpand()) phase=\(phase.rawValue) maus=\(fmt(mouse))")
            }
            view.updateCount = 0
            return
        }
        Log.line("[HANDOFF]", "draggingExited win=\(win)\(sinceExpand()) updates=\(view.updateCount) maus=\(fmt(mouse))")
        guard phase == .expanded else { return }
        if presenter.boardFrame.contains(mouse) {
            exitedInsideAt = Log.now
            Log.line("[HANDOFF]", "Cursor noch im Board-Frame (Esc/Abbruch?) → warte auf Wiedereintritt, draggingEnded oder Maustaste")
        } else {
            collapse(reason: "Maus hat Board verlassen (draggingExited)")
        }
    }

    func prepareDrop(_ view: DropTargetView, _ info: NSDraggingInfo) -> Bool {
        dropReceived = true
        cancelExpand()
        Log.line("[DROP]", "prepareForDragOperation win=\(name(of: view))\(sinceExpand())")
        return true
    }

    func performDrop(_ view: DropTargetView, _ info: NSDraggingInfo) -> Bool {
        dropReceived = true
        cancelExpand()
        let win = name(of: view)
        let boardWasOpen = phase == .expanded
        let viewing = phase == .viewing
        let kind: String
        if viewing {
            kind = "Drop im Ansichtsmodus"
        } else if isBoardTarget(view) {
            kind = "Board-Drop"
        } else if boardWasOpen {
            kind = "Drop auf Eselsohr trotz offenem Board (Handoff fehlgeschlagen) → wie Board-Drop"
        } else {
            kind = "Quick-Drop"
        }
        let dropScreen = screenPoint(view, info)
        Log.line("[DROP]", "performDragOperation win=\(win) art=\(kind) dropPos=\(fmt(dropScreen)) "
            + "cursor=\(fmt(NSEvent.mouseLocation))\(sinceExpand())")
        if boardWasOpen {
            Log.line("[HANDOFF]", "performDragOperation auf win=\(win)\(sinceExpand()) boardErreicht=\(boardReached)")
        }
        importer.dumpPasteboard(info, phase: "performDragOperation", window: win)

        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let tickets = importer.receive(info, app: app)
        if viewing {
            // Drop an Cursor, Stop-Motion-Drop mit Jitter; das Board bleibt im Ansichtsmodus offen.
            let cursor = presenter.boardPoint(fromScreen: dropScreen)
            board.place(tickets, placement: .atCursor(cursor), dropMotion: viewMode.motionOptions)
            Log.line("[VIEW]", "Drop im Ansichtsmodus bilder=\(tickets.count) cursor=\(fmt(cursor)) → Board bleibt offen")
        } else if boardWasOpen {
            stopPolling()
            phase = .dropClosing
            let cursor = presenter.boardPoint(fromScreen: dropScreen)
            board.place(tickets, placement: .atCursor(cursor), dropMotion: postDropMotionOptions())
            // E8: Board bleibt für die Drop-Frames sichtbar; erst nach Rückkehr aus performDragOperation schließen.
            let delay = motion.effective ? 0 : DropboardConfig.dropCloseDelay
            Log.line("[MOTION]", "Board schließt in \(Int(delay * 1000))ms (dropCloseDelay, reduceMotion=\(motion.effective))")
            perform(#selector(closeAfterDrop), with: nil, afterDelay: delay, inModes: [.common])
        } else {
            board.place(tickets, placement: .nextFreeSlot, dropMotion: nil)
            if phase == .hovering { phase = .idle }
        }
        let ok = !tickets.isEmpty
        Log.line("[DROP]", "performDragOperation Rückgabe=\(ok) bilder=\(tickets.count)")
        diagnostics.logFocus("nach Drop")
        perform(#selector(logFocusAfterDrop), with: nil, afterDelay: 0.5, inModes: [.common])
        return ok
    }

    func concludeDrop(_ view: DropTargetView, _ info: NSDraggingInfo?) {
        Log.line("[DROP]", "concludeDragOperation win=\(name(of: view))\(sinceExpand())")
        importer.probeSources("concludeDragOperation")
    }

    func dragEnded(_ view: DropTargetView, _ info: NSDraggingInfo) {
        Log.line("[HANDOFF]", "draggingEnded win=\(name(of: view)) dropEmpfangen=\(dropReceived) phase=\(phase.rawValue)"
            + "\(sinceExpand()) cursor=\(fmt(NSEvent.mouseLocation))")
        view.updateCount = 0
        if phase == .hovering {
            cancelExpand()
            phase = .idle
        } else if phase == .expanded && !dropReceived {
            collapse(reason: "draggingEnded ohne Drop")
        }
    }

    @objc private func logFocusAfterDrop() { diagnostics.logFocus("500ms nach Drop") }

    /// Fremder Drag, während der Ansichtsmodus offen ist: nur Bilder annehmen, kein Expand-Timer, kein Watchdog.
    private func viewDragEntered(_ view: DropTargetView, _ info: NSDraggingInfo, win: String, pos: String) -> NSDragOperation {
        let seq = info.draggingSequenceNumber
        if seq != sessionSeq {
            sessionSeq = seq
            dropReceived = false
            Log.line("[HANDOFF]", "neue Drag-Session seq=\(seq) (Ansichtsmodus)")
            importer.dumpPasteboard(info, phase: "draggingEntered", window: win)
        }
        viewDragAccepts = importer.looksLikeImage(info)
        Log.line("[VIEW]", "fremder Drag draggingEntered win=\(win) pos=\(pos) bild=\(viewDragAccepts)"
            + (viewDragAccepts ? " → Drop an Cursor" : " → abgelehnt"))
        return viewDragAccepts ? .copy : []
    }

    // MARK: Expand / Zuklappen / Schließen

    private func scheduleExpand() {
        cancelExpand()
        perform(#selector(expandFired), with: nil, afterDelay: DropboardConfig.expandDelay, inModes: [.common])
    }

    private func cancelExpand() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(expandFired), object: nil)
    }

    @objc private func expandFired() {
        guard phase == .hovering, !dropReceived else { return }
        diagnostics.logFocus("vor Expand")
        phase = .expanded
        boardReached = false
        mouseMovedLogged = false
        noEnterWarned = false
        releaseSeenAt = nil
        exitedInsideAt = nil
        updateLoggedAfterExpand.removeAll()
        mouseAtExpand = NSEvent.mouseLocation
        expandAt = Log.now
        let animated = presenter.openForDrag(reduceMotion: motion.effective)
        Log.line("[HANDOFF]", "Expand ausgelöst mode=\(handoff.rawValue) maus=\(fmt(mouseAtExpand)) "
            + "dauer(orderFront/setFrame)=\(Log.ms(since: expandAt))ms mausTaste=\(NSEvent.pressedMouseButtons)")
        Log.line("[MOTION]", "RealtimeMotion reveal animated=\(animated) dauer=\(animated ? Int(RealtimeMotion.duration * 1000) : 0)ms "
            + "reduceMotion=\(motion.effective) abgedunkelt=\(board.scene.isDimmed)")
        diagnostics.logWindows("nach Expand")
        startPolling()
    }

    /// Ohne Drop: Realtime-Zuklappen (~200 ms), dann orderOut.
    private func collapse(reason: String) {
        guard phase == .expanded else { return }
        phase = .collapsing
        stopPolling()
        let t = Log.now
        let animated = presenter.collapse(reduceMotion: motion.effective) { [weak self] in
            guard let self = self else { return }
            self.phase = .idle
            Log.line("[HANDOFF]", "Board geschlossen grund=\(reason) offen=\(String(format: "%.1f", (Log.now - self.expandAt) * 1000))ms "
                + "zuklappen=\(Log.ms(since: t))ms")
            self.diagnostics.logWindows("nach Schließen")
        }
        Log.line("[MOTION]", "RealtimeMotion collapse animated=\(animated) grund=\(reason) reduceMotion=\(motion.effective)")
    }

    /// Nach dem Drop (E8): ohne Realtime-Animation ausblenden, die Stop-Motion-Frames sind dann durch.
    @objc private func closeAfterDrop() {
        guard phase == .dropClosing else { return }
        let t = Log.now
        presenter.closeImmediately()
        phase = .idle
        Log.line("[HANDOFF]", "Board geschlossen grund=nach Drop offen=\(String(format: "%.1f", (t - expandAt) * 1000))ms "
            + "dauer(orderOut/setFrame)=\(Log.ms(since: t))ms")
        diagnostics.logWindows("nach Schließen")
    }

    // MARK: Watchdog (Board offen während eines Drags), wie Spike

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: DropboardConfig.pollInterval, target: self,
                          selector: #selector(pollTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func pollTick() {
        guard phase == .expanded else { stopPolling(); return }
        let elapsed = Log.now - expandAt
        // ⚠️ VERIFIZIEREN (aus Spike): NSEvent.mouseLocation / pressedMouseButtons liefern während eines fremden Drags aktuelle Werte.
        if !mouseMovedLogged && mouseMovedSinceExpand() {
            mouseMovedLogged = true
            Log.line("[HANDOFF]", "erste Mausbewegung nach Expand +\(Log.ms(since: expandAt))ms boardErreicht=\(boardReached) "
                + "maus=\(fmt(NSEvent.mouseLocation))")
        }
        if !boardReached && !noEnterWarned && elapsed >= DropboardConfig.noEnterWarnAfter {
            noEnterWarned = true
            Log.line("[HANDOFF]", "WARNUNG: \(Int(DropboardConfig.noEnterWarnAfter * 1000))ms nach Expand kein Drag-Ereignis "
                + "auf dem Board (mausBewegtSeitExpand=\(mouseMovedSinceExpand()))")
        }
        guard !dropReceived else { return }
        if let exitedAt = exitedInsideAt, let grace = DropboardConfig.exitInsideGrace, Log.now - exitedAt >= grace {
            collapse(reason: "Drag im Board abgebrochen (Esc), kein Wiedereintritt in \(Int(grace * 1000))ms")
            return
        }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            if let released = releaseSeenAt {
                if Log.now - released >= DropboardConfig.releaseGrace {
                    collapse(reason: "Maustaste losgelassen, kein Drop innerhalb \(Int(DropboardConfig.releaseGrace * 1000))ms")
                }
            } else {
                releaseSeenAt = Log.now
                Log.line("[HANDOFF]", "Maustaste losgelassen (Polling)\(sinceExpand()) cursor=\(fmt(NSEvent.mouseLocation))")
            }
        } else {
            releaseSeenAt = nil
        }
    }
}
