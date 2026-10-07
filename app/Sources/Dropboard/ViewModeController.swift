import AppKit
import DropboardCore

/// Look der Auswahl im Ansichtsmodus: dünner Graphit-Rahmen, kein Systemblau (Briefing „Look“).
enum ViewModeStyle {
    static let selectionBorderWidth: CGFloat = 1
    static let selectionBorderAlpha: CGFloat = 0.85
}

/// Ansichtsmodus (Briefing-Schritt 7): Board per Klick aufs Eselsohr öffnen, betrachten, umsortieren, löschen,
/// schließen per Esc oder erneutem Klick aufs Eselsohr. Den Zustand (Phase .viewing/.viewClosing) hält der
/// DragCoordinator; hier liegen Auswahl, direktes Ziehen, Tastatur und die [VIEW]-Logs.
///
/// Zwei Animationspfade bleiben getrennt:
///   – während die Maus ein Bild zieht: KEINE Animation, das Bild folgt der Maus direkt (kein Jitter);
///   – alles andere ist Stop-Motion: Aufblättern/Zuklappen (StopMotionSheet, 3 Frames), Snap nach dem Loslassen
///     (StopMotionSequences.move), Löschen (StopMotionSequences.delete); jeweils mit Jitter, Reduce Motion: sofort.
///
/// Fokus: Das Board-Panel wird key, die App wird nie aktiviert. Tasten kommen über einen lokalen Key-Monitor,
/// der für jedes Fenster der App greift (Board oder – falls makeKey() nicht wirkt – das angeklickte Eselsohr).
@MainActor
final class ViewModeController {
    private struct Press {
        let id: UUID?
        let startMouse: CGPoint      // Board-Koordinaten
        let startCenter: CGPoint
        var lastMouse: CGPoint
        var dragging: Bool
    }

    private let presenter: BoardPresenter
    private let board: BoardController
    private let motion: MotionPreferences
    private let diagnostics: Diagnostics
    weak var coordinator: DragCoordinator?
    private var rng: SplitMix64
    private var keyMonitor: Any?
    /// C16: Rückfallweg für Esc, solange kein Dropboard-Panel key ist (z. B. Menü „Board öffnen“, makeKey wirkungslos).
    private var escTimer: Timer?
    private var escWasDown = false
    /// C3: Ursprungs-App beim Öffnen – nur fürs Log, sie wird NICHT aktiviert.
    private var frontAtOpen: String = "nil"
    private(set) var selectedID: UUID?
    private var press: Press?
    private var openedAt: TimeInterval = 0
    /// Beschnittmodus (E11), Unterzustand des Ansichtsmodus.
    let crop: CropController

    init(presenter: BoardPresenter, board: BoardController, motion: MotionPreferences, diagnostics: Diagnostics) {
        self.presenter = presenter
        self.board = board
        self.motion = motion
        self.diagnostics = diagnostics
        rng = SplitMix64(seed: UInt64(Date().timeIntervalSince1970 * 1000) &+ 0x5EED)
        crop = CropController(presenter: presenter, board: board)
        // Nach Übernehmen/Abbrechen bleibt das Bild ausgewählt (dünner Graphit-Rahmen wie vorher).
        crop.onEnd = { [weak self] id in
            self?.select(id, log: false)
        }
    }

    // MARK: Beschnitt (E11)

    var isCropping: Bool { crop.isActive }

    /// Klick aufs Eselsohr im Beschnittmodus: erst übernehmen (Klick daneben), dann schließt der Ansichtsmodus.
    func commitCrop(reason: String) {
        guard crop.isActive else { return }
        crop.commit(reason: reason, options: motionOptions)
    }

    /// Fremder Drag: Beschnitt abbrechen (Stop-Motion zurück), der Drop wird danach wie bisher angenommen.
    func cancelCrop(reason: String) {
        guard crop.isActive else { return }
        crop.cancel(reason: reason, options: motionOptions)
    }

    private func openCrop(id: UUID) {
        finishPress()
        press = nil
        select(nil, log: false)   // Auswahl-Rahmen aus; der Beschnittmodus hat seinen eigenen Rahmen
        if !crop.begin(id: id, options: motionOptions) {
            select(id, log: true)
        }
    }

    /// Im Ansichtsmodus gilt Stop-Motion mit Jitter (Briefing: „Jitter nur nach dem Drop und im Ansichtsmodus“).
    var motionOptions: PlanOptions {
        PlanOptions(jitter: true, reduceMotion: motion.effective, backingScale: Double(board.scene.scale))
    }

    // MARK: Öffnen / Schließen

    func open(reason: String) {
        openedAt = Log.now
        press = nil
        selectedID = nil
        frontAtOpen = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        let plan = presenter.openForViewing(options: motionOptions, using: &rng)
        installKeyMonitor()
        startEscFallback()
        Log.line("[VIEW]", "Ansichtsmodus geöffnet grund=\(reason) mode=\(presenter.handoff.rawValue) "
            + "items=\(board.document.items.count) StopMotion reveal frames=\(plan.frames.count) "
            + "duration=\(String(format: "%.3f", plan.duration))s animated=\(plan.isAnimated) jitter=\(motionOptions.jitter) "
            + "reduceMotion=\(motion.effective) abgedunkelt=\(board.scene.isDimmed)")
        diagnostics.logWindows("Ansichtsmodus offen")
        diagnostics.logFocus("Ansichtsmodus offen")
        if !dropboardPanelIsKey {
            Log.line("[FOCUS]", "WARNUNG Ansichtsmodus offen, aber kein Dropboard-Panel key (makeKey wirkungslos?) → "
                + "Esc über Tastenzustand-Rückfallweg, Klick aufs Board macht es key")
        }
    }

    private var dropboardPanelIsKey: Bool {
        presenter.ear.isKeyWindow || presenter.board?.isKeyWindow == true
    }

    /// Stop-Motion-Zuklappen (reveal rückwärts, 3 Frames), dann orderOut; `completion` danach.
    func close(reason: String, completion: @escaping @MainActor () -> Void) {
        crop.endImmediately(reason: "Ansichtsmodus schließt (\(reason))")
        finishPress()
        select(nil, log: false)
        removeKeyMonitor()
        stopEscFallback()
        let frames = motion.effective ? 1 : ViewModeSequences.frameCount
        Log.line("[VIEW]", "Ansichtsmodus schließen grund=\(reason) StopMotion reveal rückwärts frames=\(frames) "
            + "duration=\(String(format: "%.3f", motion.effective ? 0 : Double(frames) * StopMotionClock.frameDuration))s "
            + "animated=\(!motion.effective) reduceMotion=\(motion.effective)")
        let t = Log.now
        let opened = openedAt
        presenter.closeViewing(options: motionOptions, using: &rng) { [weak self] in
            Log.line("[VIEW]", "Ansichtsmodus geschlossen grund=\(reason) offen=\(String(format: "%.1f", (Log.now - opened) * 1000))ms "
                + "schließen=\(Log.ms(since: t))ms")
            self?.logFocusAfterClose()
            completion()
        }
    }

    /// Ohne Animation beenden (z. B. Bildschirmwechsel).
    func endImmediately(reason: String) {
        crop.endImmediately(reason: reason)
        finishPress()
        select(nil, log: false)
        removeKeyMonitor()
        stopEscFallback()
        presenter.closeImmediately()
        Log.line("[VIEW]", "Ansichtsmodus sofort geschlossen grund=\(reason)")
        logFocusAfterClose()
    }

    /// C3: Nach dem Schließen darf kein Dropboard-Panel key sein (BoardPresenter.closeImmediately nimmt die
    /// Key-Fähigkeit zurück). Die Ursprungs-App wird NICHT aktiviert, Dropboard nicht deaktiviert/versteckt:
    /// NSApp.hide würde auch das Eselsohr verstecken, NSApp.deactivate ist für eine nie aktive App nicht belegt.
    /// ⚠️ VERIFIZIEREN: Ohne Key-Window bei Dropboard gehen Tasten wieder an die Ursprungs-App (Hardware: nach Esc
    /// in TextEdit weitertippen). Bleibt Dropboard aktiv (NSApp.isActive=true), nur WARNUNG loggen.
    private func logFocusAfterClose() {
        diagnostics.logWindows("nach Ansichtsmodus")
        diagnostics.logFocus("nach Ansichtsmodus")
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        Log.line("[FOCUS]", "nach Ansichtsmodus frontmost vorher=\(frontAtOpen) jetzt=\(front) NSApp.isActive=\(NSApp.isActive) "
            + "keyWindow=\(windowName(NSApp.keyWindow)) dropboardKey=\(dropboardPanelIsKey)")
        if dropboardPanelIsKey {
            Log.line("[FOCUS]", "WARNUNG nach Ansichtsmodus: Dropboard-Panel ist key → Tastatur bleibt bei Dropboard")
        }
        if NSApp.isActive {
            Log.line("[FOCUS]", "WARNUNG nach Ansichtsmodus: Dropboard ist aktiv (nicht vorgesehen) – kein Gegenmittel ohne Beleg")
        }
    }

    // MARK: Esc-Rückfallweg (C16)

    /// Läuft nur, solange der Ansichtsmodus offen ist. Fragt Esc nur ab, wenn KEIN Dropboard-Panel key ist –
    /// sonst ist der lokale Key-Monitor zuständig. Flankengesteuert (gedrückt halten schließt nicht doppelt).
    private func startEscFallback() {
        stopEscFallback()
        escWasDown = EscapeKey.isDown()
        // ⚠️ VERIFIZIEREN: MainActor.assumeIsolated im Timer-Block (Timer auf RunLoop.main → Main Thread).
        let timer = Timer(timeInterval: DropboardConfig.viewEscPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.escPollTick()
                return
            }
        }
        timer.tolerance = DropboardConfig.viewEscPollInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        escTimer = timer
    }

    private func stopEscFallback() {
        escTimer?.invalidate()
        escTimer = nil
    }

    private func escPollTick() {
        guard coordinator?.phase == .viewing else { stopEscFallback(); return }
        guard !dropboardPanelIsKey else { escWasDown = false; return }
        let down = EscapeKey.isDown()
        defer { escWasDown = down }
        guard down && !escWasDown else { return }
        Log.line("[VIEW]", "Esc erkannt (Tastenzustand-Rückfallweg, kein Dropboard-Panel key) NSApp.isActive=\(NSApp.isActive)")
        if crop.isActive {
            crop.cancel(reason: "Esc (Tastenzustand)", options: motionOptions)   // E11: erst Beschnitt abbrechen
        } else {
            coordinator?.closeViewing(reason: "Esc (Tastenzustand)")
        }
    }

    // MARK: Maus (Board-Koordinaten)

    /// `clickCount` (E11): 2 auf einem Bild öffnet den Beschnittmodus; im Beschnittmodus geht alles an CropController.
    func mouseDown(at point: CGPoint, clickCount: Int = 1) {
        if crop.isActive {
            crop.mouseDown(at: point, clickCount: clickCount, options: motionOptions)
            return
        }
        finishPress()
        let hit = board.hitItem(at: point)
        if clickCount == 2, let id = hit {
            openCrop(id: id)
            return
        }
        select(hit, log: true)
        if let id = hit, let item = board.item(id: id) {
            press = Press(id: id, startMouse: point, startCenter: item.center.cgPoint, lastMouse: point, dragging: false)
        } else {
            press = nil
        }
    }

    func mouseDragged(to point: CGPoint, shift: Bool = false) {
        if crop.isActive {
            crop.mouseDragged(to: point, shift: shift)
            return
        }
        guard var p = press, let id = p.id else { return }
        p.lastMouse = point
        let dx = point.x - p.startMouse.x
        let dy = point.y - p.startMouse.y
        if !p.dragging {
            guard (dx * dx + dy * dy).squareRoot() >= DropboardConfig.viewDragThreshold else {
                press = p
                return
            }
            p.dragging = true
            board.beginDrag(id: id)
            Log.line("[VIEW]", "Umsortieren Start id=\(id.uuidString) von=\(fmt(p.startCenter)) (Bild folgt der Maus direkt, ohne Jitter)")
        }
        press = p
        board.dragUpdate(id: id, center: CGPoint(x: p.startCenter.x + dx, y: p.startCenter.y + dy))
    }

    func mouseUp(at point: CGPoint) {
        if crop.isActive {
            crop.mouseUp(at: point)
            return
        }
        if var p = press {
            p.lastMouse = point
            press = p
        }
        finishPress()
    }

    func mouseMoved(at point: CGPoint) {
        crop.mouseMoved(at: point)
    }

    /// Ein laufendes Ziehen abschließen: Snap aufs Grid, neue Zufallsrotation, Stop-Motion-move, speichern.
    private func finishPress() {
        guard let p = press else { return }
        press = nil
        guard p.dragging, let id = p.id else { return }
        let dragged = CGPoint(x: p.startCenter.x + p.lastMouse.x - p.startMouse.x,
                              y: p.startCenter.y + p.lastMouse.y - p.startMouse.y)
        guard let r = board.dropDragged(id: id, draggedCenter: dragged, options: motionOptions) else {
            Log.line("[VIEW]", "Umsortieren FEHLER id=\(id.uuidString) nicht mehr im Board")
            return
        }
        Log.line("[VIEW]", "Umsortieren id=\(id.uuidString) von=\(fmt(r.from.center.cgPoint)) losgelassen=\(fmt(dragged)) "
            + "nach=\(fmt(r.to.center.cgPoint)) rotation=\(String(format: "%.2f", r.from.rotation))°→\(String(format: "%.2f", r.to.rotation))° "
            + "StopMotion move frames=\(r.plan.frames.count) duration=\(String(format: "%.3f", r.plan.duration))s "
            + "animated=\(r.plan.isAnimated) jitter=\(motionOptions.jitter)")
    }

    // MARK: Auswahl

    private func select(_ id: UUID?, log: Bool) {
        guard id != selectedID else { return }
        if let old = selectedID { board.scene.setSelected(false, id: old) }
        selectedID = id
        if let id = id { board.scene.setSelected(true, id: id) }
        guard log else { return }
        if let id = id, let item = board.item(id: id) {
            Log.line("[VIEW]", "Auswahl id=\(id.uuidString) datei=\(item.fileName) mitte=\(fmt(item.center.cgPoint))")
        } else {
            Log.line("[VIEW]", "Auswahl aufgehoben (Klick aufs Papier)")
        }
    }

    // MARK: Löschen

    private func deleteSelected(key: String) {
        guard let id = selectedID else {
            Log.line("[VIEW]", "\(key) ohne Auswahl → nichts gelöscht")
            return
        }
        if press?.id == id { finishPress() }
        selectedID = nil
        guard let r = board.deleteItem(id: id, options: motionOptions) else {
            Log.line("[VIEW]", "Löschen FEHLER id=\(id.uuidString) nicht mehr im Board")
            return
        }
        Log.line("[VIEW]", "Löschen id=\(id.uuidString) taste=\(key) datei=\(r.item.fileName) StopMotion delete frames=\(r.plan.frames.count) "
            + "duration=\(String(format: "%.3f", r.plan.duration))s animated=\(r.plan.isAnimated) papierkorb=\(r.trash) "
            + "items=\(board.document.items.count)")
    }

    // MARK: Tastatur

    private func installKeyMonitor() {
        removeKeyMonitor()
        // Muster aus Spike eselsohr-drop (dort kompiliert): lokaler Monitor, greift nur, wenn ein Panel der App key ist.
        // ⚠️ VERIFIZIEREN: MainActor.assumeIsolated im Monitor-Handler (läuft auf dem Main Thread, Rückgabe Bool).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// true = verbraucht (kein Beep, nicht weitergereicht).
    private func handleKey(_ event: NSEvent) -> Bool {
        // E11: im Beschnittmodus Return/Enter/Esc/R; Backspace löscht dort NICHT.
        if crop.isActive {
            return crop.handleKey(event, windowName: windowName(event.window), options: motionOptions)
        }
        // Esc gedrückt gehalten nach dem Abbrechen eines Beschnitts: die Wiederholung schließt den Ansichtsmodus nicht.
        if event.keyCode == 53 && event.isARepeat && Log.now - crop.lastEndedAt < 1.0 {
            return true
        }
        let key: String
        switch event.keyCode {
        case 53: key = "Esc"
        case 51: key = "Backspace"
        case 117: key = "Entf"
        default: return false
        }
        Log.line("[VIEW]", "Taste \(key) fenster=\(windowName(event.window)) NSApp.isActive=\(NSApp.isActive)")
        if key == "Esc" {
            coordinator?.closeViewing(reason: "Esc")
        } else if !event.isARepeat {
            deleteSelected(key: key)
        }
        return true
    }

    private func windowName(_ w: NSWindow?) -> String {
        guard let w = w else { return "nil" }
        if w === presenter.board { return "board" }
        if w === presenter.ear { return presenter.handoff == .grow ? "ear(grown)" : "ear" }
        return "andere"
    }
}
