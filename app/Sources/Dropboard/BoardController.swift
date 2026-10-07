import AppKit
import DropboardCore

/// Hält das Board-Dokument, die Szene und die Platzierung. Speichert nach jeder Änderung atomisch, kodiert und
/// geschrieben auf einer seriellen Hintergrund-Queue (P10, BoardSaveQueue; Snapshot des Dokuments als Wert).
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
        /// Log.now beim Anlegen des Platzhalters (B2: Messung Platzhalter → Bild sichtbar)
        let placedAt: TimeInterval
    }

    let store: BoardStore
    let scene: BoardScene
    let metrics = LayoutMetrics.standard
    /// Ablagefläche in Board-Koordinaten; setzt der Presenter aus dem visibleFrame.
    var usableArea: CGRect
    private(set) var document = BoardDocument()
    private var pending: [UUID: PendingItem] = [:]
    private var rng: SplitMix64
    private let saveQueue = BoardSaveQueue()
    /// C20: board.json war nicht lesbar UND ließ sich nicht wegsichern → in dieser Sitzung nie überschreiben.
    private(set) var saveLocked = false
    private var sizeFixSaveScheduled = false

    init(store: BoardStore, scene: BoardScene, usableArea: CGRect, seed: UInt64) {
        self.store = store
        self.scene = scene
        self.usableArea = usableArea
        rng = SplitMix64(seed: seed)
        // C19 (Hook aus Gruppe C): neuer Backing-Scale → alle Bilder in der neuen Pixelgröße neu dekodieren.
        scene.onBackingScaleChange = { [weak self] old, new in
            self?.redecodeAll(oldScale: old, newScale: new)
        }
    }

    /// C19: Thumbnail-Dekodierung mit neuer Ziel-Pixelgröße (Anzeigegröße × neuer Scale) über die Start-Queue
    /// (max. 3 parallel, .utility). Die alten Bitmaps bleiben sichtbar, bis das neue Bild da ist. Ergebnisse eines
    /// inzwischen wieder geänderten Scale werden verworfen. Offene Drops (pending) dekodiert der Importer selbst.
    private func redecodeAll(oldScale: CGFloat, newScale: CGFloat) {
        let items = document.items.filter { scene.itemLayer(id: $0.id) != nil && pending[$0.id] == nil }
        Log.line("[STORE]", "Backing-Scale \(oldScale) → \(newScale): \(items.count) Bild(er) neu dekodieren")
        for item in items {
            let id = item.id
            let url = store.imageURL(fileName: item.fileName)
            ImageDecoder.decodeInBackground(url: url, size: item.size.cgSize, crop: item.crop, scale: newScale,
                                            priority: .startup) { [weak self] decoded, _ in
                guard let self = self, self.scene.scale == newScale, let current = self.document.item(id: id),
                      let decoded = decoded else { return }
                // E11: Die Bitmap ist das ganze Bild in voller Größe F; F bleibt beim Beschneiden gleich. Größe und
                // Crop deshalb aus dem AKTUELLEN Item (könnte inzwischen beschnitten worden sein).
                self.scene.setImage(decoded.cgImage, size: current.size.cgSize, crop: current.crop, for: id)
            }
        }
    }

    // MARK: Laden

    /// Beim Start: board.json lesen, Items ohne Bilddatei entfernen (C9), in die Ablagefläche klemmen (C11),
    /// Platzhalter sofort, Bilder im Hintergrund dekodieren (begrenzt parallel, P4/C8).
    func loadFromDisk() {
        let t = Log.now
        switch store.loadOrQuarantine() {
        case .loaded(let loaded):
            document = loaded
        case .quarantined(let error, let movedTo):
            Log.line("[STORE]", "FEHLER board.json nicht lesbar: \(error) → defekte Datei gesichert als \(movedTo.path), starte leer")
            document = BoardDocument()
        case .unrecoverable(let error, let quarantineError):
            saveLocked = true
            document = BoardDocument()
            Log.line("[STORE]", "!!! FEHLER board.json nicht lesbar: \(error) – UND Wegsichern fehlgeschlagen: \(quarantineError) "
                + "→ starte leer, SPEICHERN GESPERRT für diese Sitzung (board.json bleibt unangetastet: \(store.documentURL.path))")
        }
        Log.line("[STORE]", "geladen items=\(document.items.count) in \(Log.ms(since: t))ms datei=\(store.documentURL.path)")

        // C9: Items ohne Bilddatei aus dem Dokument nehmen (belegen sonst unsichtbar Platz für den Quick-Drop).
        let fm = FileManager.default
        let imageStore = store
        let missing = document.removeItems { !fm.fileExists(atPath: imageStore.imageURL(fileName: $0.fileName).path) }
        for item in missing {
            Log.line("[STORE]", "Bilddatei fehlt → Item aus dem Dokument entfernt id=\(item.id.uuidString) datei=\(item.fileName) "
                + "mitte=\(fmt(item.center.cgPoint))")
        }

        // C11: nur Layout – Mittelpunkte in die aktuelle Ablagefläche ziehen. Im Speicher (Auswahl/Ziehen/Löschen
        // brauchen dieselben Koordinaten wie die Anzeige); auf die Platte erst mit dem nächsten Speichern.
        let clamped = BoardLayout.clampIntoArea(&document.items, area: usableArea)
        if !clamped.isEmpty {
            Log.line("[STORE]", "\(clamped.count) Item(s) außerhalb der Ablagefläche \(fmt(usableArea)) → hineingeklemmt "
                + "ids=\(clamped.map { $0.uuidString }.joined(separator: ","))")
        }

        for item in document.items {
            showStoredItem(item)
        }
        if !missing.isEmpty {
            save(reason: "\(missing.count) Item(s) ohne Bilddatei entfernt")
        }
    }

    /// Gespeichertes Item anzeigen: Platzhalter sofort, Bild über die Start-Queue (max. 3 parallel, .utility).
    private func showStoredItem(_ item: BoardItem) {
        guard scene.itemLayer(id: item.id) == nil else { return }
        let url = store.imageURL(fileName: item.fileName)
        let size = item.size.cgSize
        StopMotion.batch {
            let layer = scene.addPlaceholder(id: item.id, size: size)
            StopMotion.setModel(scene.pose(center: item.center.cgPoint, rotation: item.rotation), on: layer)
        }
        let id = item.id
        let crop = item.crop
        ImageDecoder.decodeInBackground(url: url, size: size, crop: crop, scale: scene.scale, priority: .startup) { [weak self] decoded, _ in
            guard let self = self else { return }
            if let decoded = decoded {
                self.scene.setImage(decoded.cgImage, size: decoded.size, crop: crop, for: id)
                self.adoptDecodedSize(id: id, size: decoded.size)
            } else {
                Log.line("[STORE]", "Bild nicht lesbar, Platzhalter bleibt id=\(id.uuidString)")
            }
        }
    }

    /// C7: Ältere Einträge können die Größe ohne EXIF-Drehung gespeichert haben. Der Dekoder liefert dann die
    /// orientierte Größe (BoardLayout.reconciledSize); hier ins Dokument übernehmen und gebündelt speichern.
    private func adoptDecodedSize(id: UUID, size: CGSize) {
        guard var item = document.item(id: id), item.size.cgSize != size else { return }
        let old = item.size
        item.size = BoardSize(size)
        document.upsert(item)
        Log.line("[STORE]", "Größe korrigiert (EXIF-Orientierung) id=\(id.uuidString) \(Int(old.width))x\(Int(old.height)) → "
            + "\(Int(size.width))x\(Int(size.height))pt")
        guard !sizeFixSaveScheduled else { return }
        sizeFixSaveScheduled = true
        afterDelay(0.5) { [weak self] in
            guard let self = self else { return }
            self.sizeFixSaveScheduled = false
            self.save(reason: "Größen nach EXIF-Orientierung korrigiert")
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
            pending[ticket.id] = PendingItem(center: center, rotation: rotation, size: size, addedAt: BoardClock.timestamp(),
                                             placedAt: Log.now)
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
        case .preview(let image):
            // B2: Bild aus den Drop-Daten ist dekodiert, die Datei wird noch geschrieben → Platzhalter jetzt ersetzen.
            guard let p = pending[id] else { return }
            scene.setImage(image.cgImage, size: image.size, for: id)
            Log.line("[DROP]", "Vorschau sichtbar id=\(id.uuidString) +\(Log.ms(since: p.placedAt))ms nach Platzhalter (Datei folgt)")
        case .failed:
            pending[id] = nil
            scene.removeItem(id: id)
        case .image(let fileName, let image, let source):
            let item: BoardItem
            if let p = pending.removeValue(forKey: id) {
                scene.setImage(image.cgImage, size: image.size, for: id)
                // B2-Messung: liegt der Wert unter ~167 ms, zeigt spätestens der zweite Drop-Frame das Bild.
                Log.line("[DROP]", "Bild sichtbar id=\(id.uuidString) +\(Log.ms(since: p.placedAt))ms nach Platzhalter")
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

    /// C10: Erst board.json speichern, dann – nur bei Erfolg und auf derselben seriellen Queue – die Bilddatei
    /// nach trash/. Scheitert das Speichern, wird das Löschen zurückgerollt (Item wieder ins Dokument an seine
    /// alte Stelle, Layer nach Ende der Lösch-Animation wieder anzeigen); die Datei bleibt in images/.
    /// Rückgabe `trash`: nur ein Hinweis (das Ergebnis kommt asynchron, siehe [STORE]-Log).
    private func finishDelete(_ item: BoardItem, plan: StopMotionPlan) -> (item: BoardItem, plan: StopMotionPlan, trash: String) {
        let index = document.index(id: item.id) ?? document.items.count
        BoardEditing.delete(&document, id: item.id)
        guard !saveLocked else {
            Log.line("[STORE]", "Löschen nur im Speicher (Speichern gesperrt, C20) – Bilddatei bleibt in images/ \(item.fileName)")
            return (item, plan, "nicht verschoben (Speichern gesperrt)")
        }
        let store = self.store
        let count = document.items.count
        let reappearAfter = plan.isAnimated ? plan.duration + 0.05 : 0
        saveQueue.save(document, to: store) { result in
            switch result {
            case .success(let ms):
                Log.line("[STORE]", "gespeichert items=\(count) in \(String(format: "%.1f", ms))ms im Hintergrund (Löschen \(item.id.uuidString))")
                do {
                    let trashed = try store.moveImageToTrash(fileName: item.fileName)
                    Log.line("[STORE]", "Bilddatei nach erfolgreichem Speichern im Papierkorb \(trashed.path)")
                } catch {
                    Log.line("[STORE]", "Bilddatei nicht in den Papierkorb verschoben \(item.fileName): \(error)")
                }
            case .failure(let error):
                Log.line("[STORE]", "FEHLER Speichern beim Löschen \(store.documentURL.path): \(error.localizedDescription) "
                    + "→ Löschen wird zurückgerollt, Bilddatei bleibt in images/")
                Task { @MainActor in
                    self.rollbackDelete(item, index: index, after: reappearAfter)
                }
            }
        }
        return (item, plan, "nach dem Speichern (asynchron, siehe [STORE])")
    }

    private func rollbackDelete(_ item: BoardItem, index: Int, after delay: Double) {
        guard document.item(id: item.id) == nil else { return }
        document.insert(item, at: index)
        Log.line("[STORE]", "Löschen zurückgerollt id=\(item.id.uuidString) stapelIndex=\(index) items=\(document.items.count)")
        // Erst nach dem Entfernen des Layers durch die Lösch-Animation (afterDelay(plan.duration)) wieder anzeigen.
        afterDelay(delay) { [weak self] in
            guard let self = self, self.document.item(id: item.id) != nil else { return }
            self.showStoredItem(item)
        }
    }

    // MARK: Beschnitt (E11)

    /// Item, das beschnitten werden kann: gespeichert, kein offener Platzhalter, Bild sichtbar. Sonst nil.
    func croppableItem(id: UUID) -> BoardItem? {
        guard pending[id] == nil, scene.hasImage(id: id) else { return nil }
        return document.item(id: id)
    }

    /// Beschnitt übernehmen: neuer Crop, Größe und Mittelpunkt des Rahmens (sichtbarer Teil bleibt an Ort und Größe,
    /// CropEditor.result), Mittelpunkt nur in die Ablagefläche geklemmt (kein Grid-Snap – das würde den Ausschnitt
    /// verschieben), neue Zufallsrotation ±1–2° wie beim Ablegen. Stop-Motion-Settle (2 Frames: gerade → final mit
    /// Kipp), Item oben im Stapel, atomisch gespeichert. Rückgabe fürs Log.
    func applyCrop(id: UUID, crop: BoardCrop?, center: CGPoint, size: CGSize, options: PlanOptions)
        -> (before: BoardItem, after: BoardItem, plan: StopMotionPlan, clamped: Bool)? {
        guard let before = document.item(id: id), let layer = scene.itemLayer(id: id) else { return nil }
        let target = BoardLayout.clampCenter(center, size: size, area: usableArea)
        let rotation = BoardLayout.randomTilt(range: metrics.tiltRange, using: &rng)
        let plan = CropSequences.settle(from: scene.pose(center: center, rotation: 0),
                                        to: scene.pose(center: target, rotation: rotation), options: options, using: &rng)
        StopMotion.batch {
            scene.endCropEditing(id: id, size: size, crop: crop)
            StopMotion.apply(plan, to: layer)
        }
        guard let after = CropEditing.apply(&document, id: id, crop: crop, center: target, size: size, rotation: rotation)
        else { return nil }
        save(reason: "Beschnitt \(id.uuidString) crop=\(BoardCrop.describe(after.crop)) "
            + "größe=\(String(format: "%.1fx%.1f", after.size.width, after.size.height))pt mitte=\(fmt(target))")
        return (before, after, plan, target != center)
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

    /// P10: Snapshot (Wert-Kopie) an die serielle Save-Queue; Kodieren und atomisches Schreiben im Hintergrund.
    /// C20: bei gesperrtem Speichern nur loggen.
    private func save(reason: String) {
        guard !saveLocked else {
            Log.line("[STORE]", "Speichern GESPERRT (board.json nicht lesbar und nicht gesichert) – nicht geschrieben (\(reason))")
            return
        }
        let count = document.items.count
        let path = store.documentURL.path
        saveQueue.save(document, to: store) { result in
            switch result {
            case .success(let ms):
                Log.line("[STORE]", "gespeichert items=\(count) in \(String(format: "%.1f", ms))ms im Hintergrund (\(reason))")
            case .failure(let error):
                Log.line("[STORE]", "FEHLER Speichern \(path): \(error.localizedDescription) (\(reason))")
            }
        }
    }

    /// Wartet, bis alle eingereihten Speichervorgänge geschrieben sind (z. B. vor dem Beenden). Additiv; der
    /// Orchestrator kann es in applicationWillTerminate/SIGINT-Handler einhängen.
    func flushPendingSaves() {
        saveQueue.flush()
    }
}
