import AppKit
import QuartzCore
import DropboardCore

/// Zustandsautomat für Drag-Sessions auf Eselsohr und Board (Logik aus Spike eselsohr-drop/AppController).
///
///   idle ──draggingEntered(ear, Bild)──▶ hovering ──Settings.expandDelayMs (E10: 300 ms)──▶ expanded ──performDrop(board)──▶ dropClosing ──dropCloseDelay──▶ idle
///                                          │ performDrop(ear) = Quick-Drop ▶ idle          │ Exit/Ende/Esc ohne Drop
///                                          │ draggingExited ▶ idle                         ▼
///                                                                                       collapsing ──200 ms Realtime──▶ idle
///
/// Ansichtsmodus (Schritt 7, Details in ViewModeController):
///   idle ──Klick aufs Eselsohr / Menüleiste „Board öffnen“──▶ viewing ──Esc / Klick aufs Eselsohr──▶ viewClosing ──3 Frames Stop-Motion──▶ idle
///   In `viewing` landet ein fremder Drag (Bild) auf Eselsohr oder Board per Drop an Cursor; das Board bleibt offen.
///   Beschnittmodus (E11) ist ein Unterzustand von `viewing` (CropController): Doppelklick öffnet, ein fremder Drag und
///   endAllImmediately brechen ihn ab, ein Klick aufs Eselsohr übernimmt ihn und schließt dann den Ansichtsmodus.
///
/// Phase 4 (Gruppe B): Entscheidungen in `DragRules`/`WatchdogRules` (DropboardConfig.swift, Selftest FixB).
///   C1  expanded: Eselsohr lehnt nicht mehr ab; ein Drop dort = Board-Drop an Cursor (Board liegt sichtbar darüber).
///   C12 draggingUpdated prüft die Phase neu: nach collapsing/dropClosing → idle startet Hovering ohne Neueintritt.
///   C4  endAllImmediately ist der gemeinsame Weg für Bildschirmwechsel, Ecke, Ausblenden.
///   P8/P14 Watchdog und Aktivitäts-Assertion hängen am `phase`-didSet → Stopp in allen Endpfaden garantiert.
@MainActor
final class DragCoordinator: NSObject {
    typealias Phase = DragPhase

    private let presenter: BoardPresenter
    private let board: BoardController
    private let importer: ImageImporter
    private let motion: MotionPreferences
    private let diagnostics: Diagnostics
    /// Schritt 8: Verzögerung bis zum Expand kommt aus den Einstellungen (wirkt ab dem nächsten Drag).
    private let settings: Settings
    private let viewMode: ViewModeController
    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            // P8: Watchdog läuft nur in `expanded` – jeder andere Zustand stoppt ihn, egal über welchen Pfad.
            if phase != .expanded { stopPolling() }
            // P14: Aktivitäts-Assertion für die ganze Drag-Session (inkl. Expand-Timer in `hovering`).
            updateActivity()
        }
    }
    /// P14: ProcessInfo-Aktivität (userInitiated + latencyCritical), solange `phase.isDragSession`.
    private var activity: NSObjectProtocol?
    private var activityStart: TimeInterval = 0

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
    /// P8: Zeitpunkt von prepareForDragOperation (Drop angekündigt) für den Timeout ohne performDragOperation.
    private var prepareAt: TimeInterval?
    /// C12: „Bild im Drag?“ einmal pro Drag-Session (draggingUpdated fragt es sonst bei jedem Update ab).
    private var imageCheck: (seq: Int, isImage: Bool)?
    private var updateLoggedAfterExpand = Set<String>()
    private var pollTimer: Timer?
    /// Ansichtsmodus: nimmt der aktuelle fremde Drag ein Bild mit? (in draggingEntered bestimmt)
    private var viewDragAccepts = false

    init(presenter: BoardPresenter, board: BoardController, importer: ImageImporter,
         motion: MotionPreferences, diagnostics: Diagnostics, settings: Settings) {
        self.presenter = presenter
        self.board = board
        self.importer = importer
        self.motion = motion
        self.diagnostics = diagnostics
        self.settings = settings
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
            openViewing(reason: "Klick aufs Eselsohr")
        case .viewing:
            if presenter.isOnEar(screenPoint: screen) {
                // E11: Klick daneben übernimmt einen offenen Beschnitt; danach schließt der Ansichtsmodus wie bisher.
                viewMode.commitCrop(reason: "Klick aufs Eselsohr")
                closeViewing(reason: "Klick aufs Eselsohr")
            } else {
                // E11: clickCount 2 auf einem Bild öffnet den Beschnittmodus (der erste Klick hat schon ausgewählt).
                // ⚠️ VERIFIZIEREN: NSEvent.clickCount zählt auch auf einem nicht aktivierenden Panel einer inaktiven App
                // (Log `[CROP] Beschnitt geöffnet`).
                viewMode.mouseDown(at: presenter.boardPoint(fromScreen: screen), clickCount: event.clickCount)
            }
        default:
            Log.line("[VIEW]", "Klick auf \(name(of: view)) ignoriert phase=\(phase.rawValue)")
        }
    }

    func mouseDragged(_ view: DropTargetView, _ event: NSEvent) {
        guard phase == .viewing else { return }
        viewMode.mouseDragged(to: presenter.boardPoint(fromScreen: screenPoint(view, event)),
                              shift: event.modifierFlags.contains(.shift))
    }

    /// Nur im Beschnittmodus (Tracking-Area, BoardPresenter.setCropTracking): Cursor über Griffen/Bild.
    func mouseMoved(_ view: DropTargetView, _ event: NSEvent) {
        guard phase == .viewing else { return }
        viewMode.mouseMoved(at: presenter.boardPoint(fromScreen: screenPoint(view, event)))
    }

    func mouseUp(_ view: DropTargetView, _ event: NSEvent) {
        guard phase == .viewing else { return }
        viewMode.mouseUp(at: presenter.boardPoint(fromScreen: screenPoint(view, event)))
    }

    /// E12: ⌘E im Ansichtsmodus → Export (AppController/ExportController).
    func setExportHandler(_ handler: @escaping @MainActor () -> Void) {
        viewMode.onExport = handler
    }

    /// Ansichtsmodus öffnen – gleicher Weg für Klick aufs Eselsohr und Menüleiste „Board öffnen“.
    /// Rückgabe: geöffnet? (nur aus `idle`)
    @discardableResult
    func openViewing(reason: String) -> Bool {
        guard presenter.screenAvailable else {
            Log.line("[VIEW]", "Ansichtsmodus öffnen ignoriert grund=\(reason) – kein Bildschirm")
            return false
        }
        guard phase == .idle else {
            Log.line("[VIEW]", "Ansichtsmodus öffnen ignoriert grund=\(reason) phase=\(phase.rawValue)")
            return false
        }
        phase = .viewing
        viewMode.open(reason: reason)
        return true
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

    /// Ansichtsmodus ohne Animation beenden (Teil von endAllImmediately).
    func endViewingImmediately(reason: String) {
        guard phase == .viewing || phase == .viewClosing else { return }
        viewMode.endImmediately(reason: reason)
        phase = .idle
    }

    /// C4 – gemeinsamer Weg für Bildschirmwechsel, Ecke wechseln, Eselsohr ausblenden: ALLE Phasen ohne Animation
    /// beenden. Ansichtsmodus wie oben, ein Drag-Zustand (hovering/expanded/collapsing/dropClosing) wird abgebrochen
    /// und das Board geschlossen. Danach ist die Phase `idle` (Watchdog und Aktivität enden im didSet), und keine
    /// Zuklappen-/Drop-Completion wartet mehr auf einen alten Rahmen (closeToken im Presenter, Guards hier).
    func endAllImmediately(reason: String) {
        cancelExpand()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(closeAfterDrop), object: nil)
        switch phase {
        case .idle:
            stopPolling()
            return
        case .viewing, .viewClosing:
            endViewingImmediately(reason: reason)
        case .hovering, .expanded, .collapsing, .dropClosing:
            let was = phase
            presenter.closeImmediately()
            phase = .idle
            Log.line("[HANDOFF]", "abgebrochen grund=\(reason) phase=\(was.rawValue) → idle (ohne Animation)")
        }
        stopPolling()
    }

    // MARK: Hilfen

    private var handoff: HandoffMode { presenter.handoff }

    /// grow: nach dem Expand ist die Eselsohr-View selbst das Board. Im Ansichtsmodus zählt auch das Eselsohr
    /// (liegt bei two-panels über dem Board) als Board.
    private func isBoardTarget(_ view: DropTargetView) -> Bool {
        view.role == .board || (handoff == .grow && presenter.isOpen) || phase == .viewing
    }

    /// P14: Aktivität an/aus je nach Phase (nur aus dem phase-didSet).
    /// ⚠️ VERIFIZIEREN: beginActivity(options: [.userInitiated, .latencyCritical]) verhindert Timer-Coalescing/App Nap
    /// für den Expand-Timer; Messung: Log `Expand ausgelöst … verspätung=…ms`.
    private func updateActivity() {
        if phase.isDragSession {
            guard activity == nil else { return }
            activityStart = Log.now
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Dropboard: Drag über Eselsohr/Board")
        } else if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
            Log.line("[HANDOFF]", "Aktivität (userInitiated, latencyCritical) beendet nach \(Log.ms(since: activityStart))ms phase=\(phase.rawValue)")
        }
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
            logReentry(win)
            Log.line("[HANDOFF]", "draggingEntered win=\(win)\(sinceExpand()) mausBewegtSeitExpand=\(mouseMovedSinceExpand()) "
                + "pos=\(pos) maus=\(fmt(NSEvent.mouseLocation))")
            return .copy
        }
        let isImage = noteSession(info, win: win, phaseLabel: "draggingEntered")
        switch DragRules.earDrag(phase: phase, isImage: isImage) {
        case .reject:
            if isImage {
                Log.line("[HANDOFF]", "draggingEntered win=\(win) ignoriert phase=\(phase.rawValue) "
                    + "(Hover startet per draggingUpdated, sobald idle)")
            } else {
                Log.line("[PB]", "kein Bild im Drag → Eselsohr bleibt still (kein Expand, kein Drop)")
            }
            return []
        case .startHover:
            startHover(win: win, pos: pos, via: "draggingEntered")
            return .copy
        case .keepHover:
            return .copy
        case .boardDrop:
            // C1: Handoff hat (noch) nicht aufs Board-Panel gewechselt – annehmen, Drop gilt als Board-Drop an Cursor.
            exitedInsideAt = nil
            Log.line("[HANDOFF]", "draggingEntered win=\(win) phase=expanded\(sinceExpand()) → angenommen "
                + "(Drop hier = Board-Drop an Cursor) pos=\(pos)")
            return .copy
        }
    }

    func dragUpdated(_ view: DropTargetView, _ info: NSDraggingInfo) -> NSDragOperation {
        view.updateCount += 1
        if phase == .viewing { return viewDragAccepts ? .copy : [] }
        guard isBoardTarget(view) else { return earUpdated(view, info) }
        guard phase == .expanded else { return [] }
        boardReached = true
        let win = name(of: view)
        logReentry(win)
        logUpdateThrottled(view, info, win: win)
        return .copy
    }

    /// Eselsohr (kein Board-Ziel): Phase bei JEDEM Update neu prüfen (C12), im expanded annehmen (C1).
    private func earUpdated(_ view: DropTargetView, _ info: NSDraggingInfo) -> NSDragOperation {
        let win = name(of: view)
        let isImage = noteSession(info, win: win, phaseLabel: "draggingUpdated")
        switch DragRules.earDrag(phase: phase, isImage: isImage) {
        case .reject:
            return []
        case .startHover:
            // ⚠️ VERIFIZIEREN: AppKit schickt draggingUpdated weiter, auch wenn draggingEntered [] geliefert hat
            // (Drag kam während collapsing/dropClosing). Nachweis: diese Logzeile.
            startHover(win: win, pos: fmt(screenPoint(view, info)), via: "draggingUpdated (Phase wieder idle)")
            return .copy
        case .keepHover:
            return .copy
        case .boardDrop:
            exitedInsideAt = nil
            logUpdateThrottled(view, info, win: win + "(expanded, Handoff nicht übernommen)")
            return .copy
        }
    }

    /// Neue Drag-Session erkennen (seq), Pasteboard einmal dumpen, „Bild?“ einmal pro Session bestimmen.
    private func noteSession(_ info: NSDraggingInfo, win: String, phaseLabel: String) -> Bool {
        let seq = info.draggingSequenceNumber
        if seq != sessionSeq {
            sessionSeq = seq
            dropReceived = false
            prepareAt = nil
            Log.line("[HANDOFF]", "neue Drag-Session seq=\(seq) phase=\(phase.rawValue)")
            importer.dumpPasteboard(info, phase: phaseLabel, window: win)
        }
        if let c = imageCheck, c.seq == seq { return c.isImage }
        let isImage = importer.looksLikeImage(info)
        imageCheck = (seq, isImage)
        return isImage
    }

    private func startHover(win: String, pos: String, via: String) {
        phase = .hovering
        Log.line("[HANDOFF]", "\(via) win=\(win) pos=\(pos) → Expand-Timer \(settings.expandDelayMs)ms")
        scheduleExpand()
    }

    /// B4: Wiedereintritt nach draggingExited mit Cursor im Board – Dauer loggen (Grundlage für exitInsideGrace).
    private func logReentry(_ win: String) {
        if let exited = exitedInsideAt {
            Log.line("[HANDOFF]", "Wiedereintritt nach \(Log.ms(since: exited))ms win=\(win) "
                + "(exitInsideGrace=\(Int((DropboardConfig.exitInsideGrace ?? 0) * 1000))ms)")
        }
        exitedInsideAt = nil
    }

    private func logUpdateThrottled(_ view: DropTargetView, _ info: NSDraggingInfo, win: String) {
        let first = !updateLoggedAfterExpand.contains(win)
        if first || Log.now - view.lastUpdateLog >= DropboardConfig.updateLogInterval {
            updateLoggedAfterExpand.insert(win)
            view.lastUpdateLog = Log.now
            Log.line("[HANDOFF]", "draggingUpdated\(first ? " (erstes nach Expand)" : "") win=\(win)\(sinceExpand()) "
                + "mausBewegtSeitExpand=\(mouseMovedSinceExpand()) pos=\(fmt(screenPoint(view, info))) n=\(view.updateCount)")
        }
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
        prepareAt = Log.now
        cancelExpand()
        Log.line("[DROP]", "prepareForDragOperation win=\(name(of: view))\(sinceExpand())")
        return true
    }

    func performDrop(_ view: DropTargetView, _ info: NSDraggingInfo) -> Bool {
        dropReceived = true
        cancelExpand()
        let win = name(of: view)
        let dropKind = DragRules.dropKind(phase: phase, onBoardTarget: isBoardTarget(view))
        let boardWasOpen = dropKind.isBoardDropAtCursor
        let viewing = dropKind == .viewing
        let kind = dropKind.rawValue
        let dropScreen = screenPoint(view, info)
        // C1: welches Panel hat den Drop bekommen? (Hardware-Nachweis für den Handoff, T4)
        Log.line("[HANDOFF]", "Drop-Panel=\(view.role == .board ? "board" : "ear") win=\(win) phase=\(phase.rawValue) "
            + "handoff=\(handoff.rawValue) → \(kind)")
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
        prepareAt = nil
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
        // E11: Ein fremder Drag bricht einen offenen Beschnitt ab; danach wie bisher annehmen.
        viewMode.cancelCrop(reason: "fremder Drag")
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

    private var hoverStartedAt: TimeInterval = 0

    private func scheduleExpand() {
        cancelExpand()
        hoverStartedAt = Log.now
        perform(#selector(expandFired), with: nil, afterDelay: settings.expandDelay, inModes: [.common])
    }

    private func cancelExpand() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(expandFired), object: nil)
    }

    @objc private func expandFired() {
        guard phase == .hovering, !dropReceived else { return }
        let scheduled = hoverStartedAt + settings.expandDelay
        phase = .expanded
        boardReached = false
        mouseMovedLogged = false
        noEnterWarned = false
        releaseSeenAt = nil
        exitedInsideAt = nil
        prepareAt = nil
        updateLoggedAfterExpand.removeAll()
        mouseAtExpand = NSEvent.mouseLocation
        expandAt = Log.now
        let animated = presenter.openForDrag(reduceMotion: motion.effective)
        let syncMs = Log.ms(since: expandAt)
        // P6: Commit sofort erzwingen und messen, BEVOR irgendetwas geloggt oder abgefragt wird.
        CATransaction.flush()
        Log.line("[HANDOFF]", "Expand commit +\(Log.ms(since: expandAt))ms")
        Log.line("[HANDOFF]", "Expand ausgelöst mode=\(handoff.rawValue) maus=\(fmt(mouseAtExpand)) "
            + "dauer(orderFront/setFrame)=\(syncMs)ms verspätung=\(String(format: "%.1f", (expandAt - scheduled) * 1000))ms "
            + "mausTaste=\(NSEvent.pressedMouseButtons)")
        Log.line("[MOTION]", "RealtimeMotion reveal animated=\(animated) dauer=\(animated ? Int(RealtimeMotion.duration * 1000) : 0)ms "
            + "reduceMotion=\(motion.effective) abgedunkelt=\(board.scene.isDimmed)")
        startPolling()
        // P6: Fokus-/Fenster-Diagnose (NSWorkspace, WindowServer-Abfragen) erst nach dem Commit, im nächsten Durchlauf.
        afterDelay(0) { [weak self] in
            guard let self = self else { return }
            self.diagnostics.logFocus("nach Expand-Commit")
            self.diagnostics.logWindows("nach Expand")
        }
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
        stopPolling()
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
        timer.tolerance = DropboardConfig.pollTolerance   // P8
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Entscheidung in `WatchdogRules.decide` (Selftest FixB): Obergrenze 30 s, Drop ohne perform (3 s),
    /// Esc per Tastenzustand (B4), Austritt im Board ohne Wiedereintritt, Maustaste los ohne Drop.
    @objc private func pollTick() {
        guard phase == .expanded else { stopPolling(); return }
        let now = Log.now
        // ⚠️ VERIFIZIEREN (aus Spike): NSEvent.mouseLocation / pressedMouseButtons liefern während eines fremden Drags aktuelle Werte.
        if !mouseMovedLogged && mouseMovedSinceExpand() {
            mouseMovedLogged = true
            Log.line("[HANDOFF]", "erste Mausbewegung nach Expand +\(Log.ms(since: expandAt))ms boardErreicht=\(boardReached) "
                + "maus=\(fmt(NSEvent.mouseLocation))")
        }
        if !boardReached && !noEnterWarned && now - expandAt >= DropboardConfig.noEnterWarnAfter {
            noEnterWarned = true
            Log.line("[HANDOFF]", "WARNUNG: \(Int(DropboardConfig.noEnterWarnAfter * 1000))ms nach Expand kein Drag-Ereignis "
                + "auf dem Board (mausBewegtSeitExpand=\(mouseMovedSinceExpand()))")
        }
        let input = WatchdogInput(elapsed: now - expandAt,
                                  dropReceived: dropReceived,
                                  sincePrepare: prepareAt.map { now - $0 },
                                  sinceExitedInside: exitedInsideAt.map { now - $0 },
                                  mouseButtonDown: NSEvent.pressedMouseButtons & 1 != 0,
                                  sinceRelease: releaseSeenAt.map { now - $0 },
                                  escDown: !dropReceived && EscapeKey.isDown())
        switch WatchdogRules.decide(input) {
        case .none:
            break
        case .noteRelease:
            releaseSeenAt = now
            Log.line("[HANDOFF]", "Maustaste losgelassen (Polling)\(sinceExpand()) cursor=\(fmt(NSEvent.mouseLocation))")
        case .clearRelease:
            releaseSeenAt = nil
        case .collapse(let reason):
            if reason == .escape {
                Log.line("[HANDOFF]", "Esc erkannt (Tastenzustand)\(sinceExpand()) "
                    + "austrittImBoardVor=\(exitedInsideAt.map { Log.ms(since: $0) + "ms" } ?? "–")")
            }
            collapse(reason: reason.text)
            stopPolling()   // collapse stoppt nur aus `expanded`; hier in jedem Fall
        }
    }
}
