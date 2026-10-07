import AppKit
import QuartzCore
import DropboardCore

/// Beschnittmodus (E11), nur im Ansichtsmodus. Doppelklick auf ein Bild öffnet ihn (ViewModeController), das Item wird
/// gerade und zeigt das ganze Bild; außerhalb des Rahmens warm abgedunkelt, 8 Griffe. Logik in DropboardCore/Crop.swift
/// (CropEditor), Darstellung in BoardScene/CropOverlay, Übernehmen/Speichern in BoardController.applyCrop. Tag `[CROP]`.
///
/// Zwei Animationspfade bleiben getrennt:
///   – Griff-/Pan-Drag: KEINE Animation, Overlay und Bild folgen der Maus direkt (Model-Werte, kein Jitter); jeder Wert
///     wird aus Startzustand + Gesamt-Mausweg berechnet (kein Aufaddieren → kein Zittern);
///   – Öffnen, Abbrechen, Übernehmen: Stop-Motion (CropSequences über den Planer, 2 Frames, Jitter nur im Zwischenframe),
///     Reduce Motion: sofort.
///
/// Übernehmen: Return/Enter, Doppelklick, Klick neben das Bild (auch aufs Eselsohr, danach schließt der Ansichtsmodus).
/// Abbrechen: Esc (Ansichtsmodus bleibt offen), fremder Drag, endAllImmediately (ohne Animation). R: ganzes Bild.
@MainActor
final class CropController {
    private struct Session {
        let id: UUID
        let original: BoardItem
        let stackIndex: Int?
        var editor: CropEditor
        let openedAt: TimeInterval
    }

    private enum PressKind {
        case handle(CropHandle)
        case pan

        var text: String {
            switch self {
            case .handle(let h): return "Griff \(h.rawValue)"
            case .pan: return "Verschieben"
            }
        }
    }

    private struct Press {
        let kind: PressKind
        let start: CropEditor
        let startMouse: CGPoint
        var moved: Bool
        var shift: Bool
    }

    private let presenter: BoardPresenter
    private let board: BoardController
    private var rng: SplitMix64
    private var session: Session?
    private var press: Press?
    private var cursorName = ""
    private var cursorMismatchLogged = false
    /// Zeitpunkt des letzten Endes (übernommen/abgebrochen) – ViewModeController ignoriert kurz danach Esc-Wiederholungen.
    private(set) var lastEndedAt: TimeInterval = -1000
    /// Nach Übernehmen/Abbrechen (nicht bei endImmediately): Auswahl wiederherstellen.
    var onEnd: ((UUID) -> Void)?

    init(presenter: BoardPresenter, board: BoardController) {
        self.presenter = presenter
        self.board = board
        rng = SplitMix64(seed: UInt64(Date().timeIntervalSince1970 * 1000) &+ 0xC209)
    }

    var isActive: Bool { session != nil }
    var editingID: UUID? { session?.id }

    // MARK: Öffnen

    /// Doppelklick auf ein Bild. Rückgabe: geöffnet? (Platzhalter/fehlendes Bild: nein)
    @discardableResult
    func begin(id: UUID, options: PlanOptions) -> Bool {
        guard session == nil else { return false }
        guard let item = board.croppableItem(id: id) else {
            Log.line("[CROP]", "Beschnitt öffnen ignoriert id=\(id.uuidString) (Platzhalter oder Bild nicht geladen)")
            return false
        }
        let scene = board.scene
        // Darstellung gerade (Rotation 0) um den Mittelpunkt des sichtbaren Teils: der bleibt an seinem Ort.
        let editor = CropEditor(itemCenter: item.center.cgPoint, itemSize: item.size.cgSize, crop: item.crop, rotation: 0)
        // Startpose: ganzes Bild, noch so gedreht wie das Item (sichtbarer Teil am selben Ort) → 2 Frames → gerade.
        let tilted = CropEditor(itemCenter: item.center.cgPoint, itemSize: item.size.cgSize, crop: item.crop,
                                rotation: item.rotation)
        let plan = CropSequences.turn(from: scene.pose(center: tilted.imageCenter, rotation: item.rotation),
                                      to: scene.pose(center: editor.imageCenter, rotation: 0),
                                      options: options, using: &rng)
        let index = scene.bringToFront(id: id)
        StopMotion.batch {
            scene.beginCropEditing(id: id, fullSize: editor.fullSize, crop: editor.crop)
            if let layer = scene.itemLayer(id: id) { StopMotion.apply(plan, to: layer) }
        }
        session = Session(id: id, original: item, stackIndex: index, editor: editor, openedAt: Log.now)
        press = nil
        presenter.setCropTracking(true)
        cursorName = ""
        updateCursor(at: presenter.boardPoint(fromScreen: NSEvent.mouseLocation))
        Log.line("[CROP]", "Beschnitt geöffnet id=\(id.uuidString) datei=\(item.fileName) crop=\(BoardCrop.describe(item.crop)) "
            + "größe=\(sizeText(item.size.cgSize)) voll=\(sizeText(editor.fullSize)) mitte=\(fmt(item.center.cgPoint)) "
            + "rotation=\(String(format: "%.2f", item.rotation))°→0° StopMotion turn frames=\(plan.frames.count) "
            + "duration=\(String(format: "%.3f", plan.duration))s animated=\(plan.isAnimated) jitter=\(options.jitter) "
            + "reduceMotion=\(options.reduceMotion)")
        return true
    }

    // MARK: Maus (Board-Koordinaten)

    func mouseDown(at p: CGPoint, clickCount: Int, options: PlanOptions) {
        guard let s = session else { return }
        press = nil
        if clickCount == 2 {
            commit(reason: "Doppelklick", options: options)
            return
        }
        let hit = s.editor.hit(p, tolerance: CropStyle.handleHitTolerance)
        switch hit {
        case .handle(let h):
            beginPress(.handle(h), at: p, session: s)
            updateCursor(at: p)
        case .frame, .image:
            beginPress(.pan, at: p, session: s)
            setCursor(.closedHand, "closedHand")
        case .outside:
            commit(reason: "Klick daneben", options: options)
        }
    }

    private func beginPress(_ kind: PressKind, at p: CGPoint, session s: Session) {
        // Laufende Öffnen-Frames beenden: ab jetzt folgt alles direkt der Maus (Model = sichtbar, kein Jitter).
        board.scene.stopItemAnimations(id: s.id)
        board.scene.updateCropEditing(id: s.id, fullSize: s.editor.fullSize, crop: s.editor.crop, imageCenter: s.editor.imageCenter)
        press = Press(kind: kind, start: s.editor, startMouse: p, moved: false, shift: false)
    }

    func mouseDragged(to p: CGPoint, shift: Bool) {
        guard var s = session, var pr = press else { return }
        let delta = CGPoint(x: p.x - pr.startMouse.x, y: p.y - pr.startMouse.y)
        switch pr.kind {
        case .handle(let h):
            s.editor.dragHandle(h, from: pr.start, mouseDelta: delta, keepAspect: shift)
        case .pan:
            s.editor.pan(from: pr.start, mouseDelta: delta)
        }
        if !pr.moved {
            pr.moved = true
            Log.line("[CROP]", "\(pr.kind.text) Start id=\(s.id.uuidString) crop=\(BoardCrop.describe(pr.start.crop)) "
                + "(folgt der Maus direkt, ohne Jitter)\(shift ? " ⇧ Seitenverhältnis" : "")")
        }
        pr.shift = pr.shift || shift
        press = pr
        session = s
        board.scene.updateCropEditing(id: s.id, fullSize: s.editor.fullSize, crop: s.editor.crop, imageCenter: s.editor.imageCenter)
    }

    func mouseUp(at p: CGPoint) {
        if let pr = press, pr.moved, let s = session {
            Log.line("[CROP]", "\(pr.kind.text) Ende id=\(s.id.uuidString) crop=\(BoardCrop.describe(pr.start.crop))→"
                + "\(BoardCrop.describe(s.editor.crop)) rahmen=\(sizeText(s.editor.frameSize)) mitte=\(fmt(s.editor.frameCenter))"
                + (pr.shift ? " (⇧)" : "") + " – noch nicht übernommen")
        }
        press = nil
        if session != nil { cursorName = ""; updateCursor(at: p) }
    }

    /// Nur mit Tracking-Area im Beschnittmodus (BoardPresenter.setCropTracking).
    func mouseMoved(at p: CGPoint) {
        guard session != nil, press == nil else { return }
        updateCursor(at: p)
    }

    // MARK: Tasten

    /// Tasten im Beschnittmodus. Rückgabe: verbraucht (kein Beep, nicht weitergereicht).
    func handleKey(_ event: NSEvent, windowName: String, options: PlanOptions) -> Bool {
        guard session != nil else { return false }
        let repeatText = event.isARepeat ? " (Wiederholung, ignoriert)" : ""
        switch event.keyCode {
        case 53:
            Log.line("[CROP]", "Taste Esc fenster=\(windowName)\(repeatText)")
            if !event.isARepeat { cancel(reason: "Esc", options: options) }
            return true
        case 36, 76:
            let key = event.keyCode == 36 ? "Return" : "Enter"
            Log.line("[CROP]", "Taste \(key) fenster=\(windowName)\(repeatText)")
            if !event.isARepeat { commit(reason: key, options: options) }
            return true
        case 51, 117:
            Log.line("[CROP]", "Taste \(event.keyCode == 51 ? "Backspace" : "Entf") im Beschnittmodus → nichts gelöscht")
            return true
        default:
            break
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "r" {
            Log.line("[CROP]", "Taste R fenster=\(windowName)\(repeatText)")
            if !event.isARepeat { reset() }
            return true
        }
        return false
    }

    // MARK: Übernehmen / Abbrechen / Zurücksetzen

    func commit(reason: String, options: PlanOptions) {
        guard let s = session else { return }
        endSession()
        let r = s.editor.result
        let o = s.original
        let oldCrop = CropMath.effective(o.crop)
        let unchanged = r.crop == oldCrop && near(r.center, o.center.cgPoint) && near(r.size, o.size.cgSize)
        if unchanged {
            let plan = restoreOriginal(s, options: options)
            Log.line("[CROP]", "Beschnitt übernommen grund=\(reason) id=\(o.id.uuidString) ohne Änderung → Ursprungszustand, "
                + "nicht gespeichert StopMotion turn frames=\(plan.frames.count) animated=\(plan.isAnimated)")
            onEnd?(o.id)
            return
        }
        guard let result = board.applyCrop(id: o.id, crop: r.crop, center: r.center, size: r.size, options: options) else {
            Log.line("[CROP]", "Beschnitt übernehmen FEHLER id=\(o.id.uuidString) nicht mehr im Board")
            board.scene.endCropEditing(id: o.id, size: nil, crop: nil)
            return
        }
        let a = result.after
        Log.line("[CROP]", "Beschnitt übernommen grund=\(reason) id=\(o.id.uuidString) crop=\(BoardCrop.describe(o.crop))→"
            + "\(BoardCrop.describe(a.crop)) größe=\(sizeText(o.size.cgSize))→\(sizeText(a.size.cgSize)) "
            + "mitte=\(fmt(o.center.cgPoint))→\(fmt(a.center.cgPoint))\(result.clamped ? " (in Ablagefläche geklemmt)" : "") "
            + "rotation=\(String(format: "%.2f", o.rotation))°→\(String(format: "%.2f", a.rotation))° "
            + "StopMotion settle frames=\(result.plan.frames.count) duration=\(String(format: "%.3f", result.plan.duration))s "
            + "animated=\(result.plan.isAnimated) jitter=\(options.jitter) offen=\(Log.ms(since: s.openedAt))ms")
        onEnd?(o.id)
    }

    /// Esc, fremder Drag: zurück in den Ursprungszustand (Stop-Motion), Ansichtsmodus bleibt offen.
    func cancel(reason: String, options: PlanOptions) {
        guard let s = session else { return }
        endSession()
        let plan = restoreOriginal(s, options: options)
        Log.line("[CROP]", "Beschnitt abgebrochen grund=\(reason) id=\(s.id.uuidString) crop bleibt \(BoardCrop.describe(s.original.crop)) "
            + "(verworfen: \(BoardCrop.describe(s.editor.crop))) StopMotion turn frames=\(plan.frames.count) "
            + "duration=\(String(format: "%.3f", plan.duration))s animated=\(plan.isAnimated)")
        onEnd?(s.id)
    }

    /// Ohne Animation abbrechen (Ansichtsmodus schließt, Eckwechsel, Ausblenden, Bildschirmwechsel – endAllImmediately).
    func endImmediately(reason: String) {
        guard let s = session else { return }
        endSession()
        let still = PlanOptions(jitter: false, reduceMotion: true, backingScale: Double(board.scene.scale))
        _ = restoreOriginal(s, options: still)
        Log.line("[CROP]", "Beschnitt abgebrochen grund=\(reason) id=\(s.id.uuidString) ohne Animation, crop bleibt "
            + "\(BoardCrop.describe(s.original.crop))")
    }

    /// R: ganzes Bild zeigen (das Bild bleibt liegen, der Rahmen umfasst es ganz). Noch nicht übernommen.
    func reset() {
        guard var s = session else { return }
        let old = s.editor.crop
        s.editor.reset()
        press = nil
        session = s
        board.scene.stopItemAnimations(id: s.id)
        board.scene.updateCropEditing(id: s.id, fullSize: s.editor.fullSize, crop: s.editor.crop, imageCenter: s.editor.imageCenter)
        Log.line("[CROP]", "Beschnitt zurückgesetzt id=\(s.id.uuidString) crop=\(BoardCrop.describe(old))→ganz "
            + "rahmen=\(sizeText(s.editor.frameSize)) – noch nicht übernommen (Return übernimmt, Esc verwirft)")
    }

    // MARK: Hilfen

    private func endSession() {
        session = nil
        press = nil
        lastEndedAt = Log.now
        presenter.setCropTracking(false)
        cursorName = ""
        setCursor(.arrow, "arrow")
    }

    /// Ursprüngliche Geometrie, Stapel-Index und Pose wiederherstellen (2 Frames: halb zurückgedreht, dann exakt).
    private func restoreOriginal(_ s: Session, options: PlanOptions) -> StopMotionPlan {
        let scene = board.scene
        let o = s.original
        let plan = CropSequences.turn(from: scene.pose(center: o.center.cgPoint, rotation: 0),
                                      to: scene.pose(center: o.center.cgPoint, rotation: o.rotation),
                                      options: options, using: &rng)
        StopMotion.batch {
            if let index = s.stackIndex { scene.restoreStackIndex(id: o.id, index: index) }
            scene.endCropEditing(id: o.id, size: o.size.cgSize, crop: o.crop)
            if let layer = scene.itemLayer(id: o.id) { StopMotion.apply(plan, to: layer) }
        }
        return plan
    }

    private func updateCursor(at p: CGPoint) {
        guard let s = session else { return }
        let hit = s.editor.hit(p, tolerance: CropStyle.handleHitTolerance)
        switch hit {
        case .handle(let h):
            if h.isCorner {
                // Kein diagonaler Resize-Cursor vor macOS 15 (NSCursor.frameResize) – Fadenkreuz.
                setCursor(.crosshair, "crosshair")
            } else if h == .left || h == .right {
                setCursor(.resizeLeftRight, "resizeLeftRight")
            } else {
                setCursor(.resizeUpDown, "resizeUpDown")
            }
        case .frame, .image:
            setCursor(.openHand, "openHand")
        case .outside:
            setCursor(.arrow, "arrow")
        }
    }

    /// ⚠️ VERIFIZIEREN: NSCursor.set() wirkt, obwohl Dropboard nie aktiv ist (nicht aktivierendes Panel, evtl. key).
    /// Greift es nicht, nur einmal pro Sitzung loggen – kein Gegenmittel (Aktivieren wäre Fokusraub).
    private func setCursor(_ cursor: NSCursor, _ name: String) {
        guard name != cursorName else { return }
        cursorName = name
        cursor.set()
        if NSCursor.current != cursor && !cursorMismatchLogged {
            cursorMismatchLogged = true
            Log.line("[CROP]", "Cursor \(name) gesetzt, aber NSCursor.current weicht ab (App inaktiv?) – nur Log, "
                + "kein Gegenmittel ohne Fokusraub")
        }
    }

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 1e-6 && abs(a.y - b.y) <= 1e-6 }
    private func near(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) <= 1e-6 && abs(a.height - b.height) <= 1e-6 }

    private func sizeText(_ s: CGSize) -> String { String(format: "%.1fx%.1fpt", s.width, s.height) }
}
