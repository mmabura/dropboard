import AppKit
import DropboardCore

/// Hält das Board-Dokument, die Szene und die Platzierung. Speichert nach jeder Änderung atomisch.
/// Kennt keine Fenster und keine Drag-Sessions (die liegen in BoardPresenter und DragCoordinator).
/// Ansichtsmodus (Schritt 7): Auswahl-Treffer, direktes Ziehen, Umsortieren (StopMotionSequences.move) und
/// Löschen (StopMotionSequences.delete, Datei nach trash/) – Modell-Logik in DropboardCore.BoardEditing.
@MainActor
final class BoardController: ImportSink {
    enum Placement {
        /// Quick-Drop: nächste freie Stelle in Lesereihenfolge
        case nextFreeSlot
        /// Drop aufs Board: Cursor in Board-Koordinaten, gesnappt
        case atCursor(CGPoint)
    }

    /// Bild, dessen Datei noch nicht da ist (Promise) oder noch dekodiert wird. Nicht persistiert,
    /// belegt aber Platz für den Free-Slot-Finder.
    private struct PendingItem {
        let center: CGPoint
        let rotation: Double
        let size: CGSize
        let addedAt: Date
    }

    let store: BoardStore
    let scene: BoardScene
    let metrics = LayoutMetrics.standard
    /// Ablagefläche in Board-Koordinaten; setzt der Presenter aus dem visibleFrame.
    var usableArea: CGRect
    private(set) var document = BoardDocument()
    private var pending: [UUID: PendingItem] = [:]
    private var rng: SplitMix64

    init(store: BoardStore, scene: BoardScene, usableArea: CGRect, seed: UInt64) {
        self.store = store
        self.scene = scene
        self.usableArea = usableArea
        rng = SplitMix64(seed: seed)
    }

    // MARK: Laden

    /// Beim Start: board.json lesen, Platzhalter sofort, Bilder im Hintergrund dekodieren.
    func loadFromDisk() {
        let t = Log.now
        do {
            document = try store.load()
        } catch {
            Log.line("[STORE]", "FEHLER board.json nicht lesbar: \(error) → starte leer")
            if let moved = try? store.quarantineDocument() {
                Log.line("[STORE]", "defekte Datei gesichert als \(moved.path)")
            }
            document = BoardDocument()
        }
        Log.line("[STORE]", "geladen items=\(document.items.count) in \(Log.ms(since: t))ms datei=\(store.documentURL.path)")
        for item in document.items {
            let url = store.imageURL(fileName: item.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Log.line("[STORE]", "Bilddatei fehlt, Item übersprungen id=\(item.id.uuidString) datei=\(item.fileName)")
                continue
            }
            let size = item.size.cgSize
            StopMotion.batch {
                let layer = scene.addPlaceholder(id: item.id, size: size)
                StopMotion.setModel(scene.pose(center: item.center.cgPoint, rotation: item.rotation), on: layer)
            }
            let id = item.id
            ImageDecoder.decodeInBackground(url: url, size: size, scale: scene.scale) { [weak self] decoded, _ in
                guard let self = self else { return }
                if let decoded = decoded {
                    self.scene.setImage(decoded.cgImage, size: decoded.size, for: id)
                } else {
                    Log.line("[STORE]", "Bild nicht lesbar, Platzhalter bleibt id=\(id.uuidString)")
                }
            }
        }
    }

    // MARK: Ablegen

    /// Legt für jedes Ticket sofort einen Platzhalter an. `dropMotion == nil`: keine Animation (Quick-Drop).
    /// Sonst Stop-Motion-Drop-Sequenz (2 Frames) mit diesen Optionen.
    func place(_ tickets: [ImportTicket], placement: Placement, dropMotion: PlanOptions?) {
        let size = metrics.placeholderSize
        for (index, ticket) in tickets.enumerated() {
            let center: CGPoint
            if case .atCursor(let cursor) = placement, index == 0 {
                center = BoardLayout.dropCenter(cursor: cursor, size: size, area: usableArea, grid: metrics.grid)
            } else {
                center = freeSlot(size: size)
            }
            let rotation = BoardLayout.randomTilt(range: metrics.tiltRange, using: &rng)
            pending[ticket.id] = PendingItem(center: center, rotation: rotation, size: size, addedAt: BoardClock.timestamp())
            let target = scene.pose(center: center, rotation: rotation)
            if let options = dropMotion {
                let plan = StopMotionSequences.drop(target: target, options: options, using: &rng)
                StopMotion.batch {
                    let layer = scene.addPlaceholder(id: ticket.id, size: size)
                    StopMotion.apply(plan, to: layer)
                }
                Log.line("[MOTION]", "StopMotion drop id=\(ticket.id.uuidString) frames=\(plan.frames.count) "
                    + "duration=\(String(format: "%.3f", plan.duration))s animated=\(plan.isAnimated) "
                    + "jitter=\(options.jitter) reduceMotion=\(options.reduceMotion)")
            } else {
                StopMotion.batch {
                    let layer = scene.addPlaceholder(id: ticket.id, size: size)
                    StopMotion.setModel(target, on: layer)
                }
            }
            Log.line("[STORE]", "Platzhalter id=\(ticket.id.uuidString) weg=\(ticket.route) mitte=\(fmt(center)) "
                + "rotation=\(String(format: "%.2f", rotation))° art=\(dropMotion == nil ? "Quick-Drop (keine Animation)" : "Board-Drop")")
        }
    }

    // MARK: ImportSink

    func importFinished(id: UUID, result: ImportResult) {
        switch result {
        case .failed:
            pending[id] = nil
            scene.removeItem(id: id)
        case .image(let fileName, let image, let source):
            let item: BoardItem
            if let p = pending.removeValue(forKey: id) {
                scene.setImage(image.cgImage, size: image.size, for: id)
                item = BoardItem(id: id, fileName: fileName, center: BoardPoint(p.center), rotation: p.rotation,
                                 size: BoardSize(image.size), addedAt: p.addedAt, source: source)
            } else {
                // Ohne Platzhalter (weitere Datei desselben Promise): freie Stelle, keine Animation.
                let center = freeSlot(size: image.size)
                let rotation = BoardLayout.randomTilt(range: metrics.tiltRange, using: &rng)
                StopMotion.batch {
                    let layer = scene.addImage(id: id, image: image.cgImage, size: image.size)
                    StopMotion.setModel(scene.pose(center: center, rotation: rotation), on: layer)
                }
                item = BoardItem(id: id, fileName: fileName, center: BoardPoint(center), rotation: rotation,
                                 size: BoardSize(image.size), addedAt: BoardClock.timestamp(), source: source)
            }
            document.upsert(item)
            save(reason: "Bild \(fileName) \(Int(image.size.width))x\(Int(image.size.height))pt mitte=\(fmt(item.center.cgPoint))")
        }
    }

    // MARK: Ansichtsmodus (Schritt 7)

    func item(id: UUID) -> BoardItem? { document.item(id: id) }

    /// Oberstes gespeichertes Bild unter `point` (Board-Koordinaten). Offene Platzhalter (Promise/Dekodieren)
    /// und Items ohne Layer (Datei fehlte beim Laden) sind nicht wählbar.
    func hitItem(at point: CGPoint) -> UUID? {
        BoardEditing.hitTest(document.items.filter { scene.itemLayer(id: $0.id) != nil }, at: point)
    }

    /// Ziehen beginnt: Bild nach oben, laufende Sequenzen weg.
    func beginDrag(id: UUID) {
        scene.beginDirectManipulation(id: id)
    }

    /// Während des Ziehens: Model-Wert hart setzen (folgt der Maus direkt, kein Jitter, keine Animation).
    func dragUpdate(id: UUID, center: CGPoint) {
        guard let item = document.item(id: id), let layer = scene.itemLayer(id: id) else { return }
        StopMotion.setModel(scene.pose(center: center, rotation: item.rotation), on: layer)
    }

    /// Loslassen: aufs Grid snappen, neue kleine Zufallsrotation, Stop-Motion-move von der gezogenen Position
    /// zum Ziel. Speichert atomisch. Rückgabe: (vorher, nachher, Plan) für das Log.
    func dropDragged(id: UUID, draggedCenter: CGPoint, options: PlanOptions) -> (from: BoardItem, to: BoardItem, plan: StopMotionPlan)? {
        guard let before = document.item(id: id), let layer = scene.itemLayer(id: id) else { return nil }
        let target = BoardEditing.snappedCenter(dragged: draggedCenter, size: before.size.cgSize, area: usableArea, grid: metrics.grid)
        let rotation = BoardLayout.randomTilt(range: metrics.tiltRange, using: &rng)
        let plan = StopMotionSequences.move(from: scene.pose(center: draggedCenter, rotation: before.rotation),
                                            to: scene.pose(center: target, rotation: rotation),
                                            options: options, using: &rng)
        StopMotion.apply(plan, to: layer)
        guard let after = BoardEditing.move(&document, id: id, to: target, rotation: rotation) else { return nil }
        save(reason: "Umsortieren \(id.uuidString) mitte=\(fmt(target))")
        return (before, after, plan)
    }

    /// Löschen: Stop-Motion-delete (2 Frames), Eintrag aus board.json, Bilddatei nach trash/. Kein Undo.
    /// Rückgabe: (Item, Plan, Papierkorb-Pfad oder Fehlertext) für das Log.
    func deleteItem(id: UUID, options: PlanOptions) -> (item: BoardItem, plan: StopMotionPlan, trash: String)? {
        guard let current = document.item(id: id) else { return nil }
        if let layer = scene.itemLayer(id: id) {
            scene.setSelected(false, id: id)
            let plan = StopMotionSequences.delete(from: scene.pose(center: current.center.cgPoint, rotation: current.rotation),
                                                  options: options, using: &rng)
            StopMotion.apply(plan, to: layer)   // Model-Wert = weg (opacity 0), danach Layer entfernen
            let itemScene = scene
            if plan.isAnimated {
                afterDelay(plan.duration) { itemScene.removeItem(id: id) }
            } else {
                itemScene.removeItem(id: id)
            }
            return finishDelete(current, plan: plan)
        }
        return finishDelete(current, plan: StopMotionPlan(frames: [], keyTimes: [0, 1], duration: 0))
    }

    private func finishDelete(_ item: BoardItem, plan: StopMotionPlan) -> (item: BoardItem, plan: StopMotionPlan, trash: String) {
        BoardEditing.delete(&document, id: item.id)
        save(reason: "Löschen \(item.id.uuidString)")   // erst das Modell (atomisch), dann die Datei
        let trash: String
        do {
            trash = try store.moveImageToTrash(fileName: item.fileName).path
        } catch {
            trash = "FEHLER \(error)"
            Log.line("[STORE]", "Bilddatei nicht in den Papierkorb verschoben \(item.fileName): \(error)")
        }
        return (item, plan, trash)
    }

    // MARK: Hilfen

    /// Belegte Rahmen: gespeicherte Items und offene Platzhalter.
    private func occupiedRects() -> [CGRect] {
        document.items.map { $0.frame }
            + pending.values.map { BoardLayout.frame(center: $0.center, size: $0.size) }
    }

    private func freeSlot(size: CGSize) -> CGPoint {
        if let p = BoardLayout.findFreeSlot(size: size, occupied: occupiedRects(), area: usableArea,
                                            grid: metrics.grid, gap: metrics.gap) {
            return p
        }
        let fallback = BoardLayout.dropCenter(cursor: CGPoint(x: usableArea.midX, y: usableArea.midY),
                                              size: size, area: usableArea, grid: metrics.grid)
        Log.line("[STORE]", "kein freier Platz – lege auf die Mitte \(fmt(fallback))")
        return fallback
    }

    private func save(reason: String) {
        let t = Log.now
        do {
            try store.save(document)
            Log.line("[STORE]", "gespeichert items=\(document.items.count) in \(Log.ms(since: t))ms (\(reason))")
        } catch {
            Log.line("[STORE]", "FEHLER Speichern \(store.documentURL.path): \(error.localizedDescription)")
        }
    }
}
