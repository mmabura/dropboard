import AppKit
import Darwin
import UniformTypeIdentifiers
import DropboardCore

enum ImportResult {
    /// B2, Weg imageData: Bild aus den Drop-Daten schon dekodiert, Datei wird noch geschrieben.
    /// Nur anzeigen (Platzhalter ersetzen), nicht speichern; `.image` oder `.failed` folgt.
    case preview(image: DecodedImage)
    case image(fileName: String, image: DecodedImage, source: ItemSource)
    case failed(String)
}

/// Empfänger der fertigen Importe (BoardController). Wird immer auf dem Main Actor aufgerufen,
/// frühestens nach Rückkehr aus performDragOperation.
@MainActor
protocol ImportSink: AnyObject {
    func importFinished(id: UUID, result: ImportResult)
}

/// Ein angenommenes Bild, für das sofort ein Platzhalter angelegt wird.
struct ImportTicket {
    let id: UUID
    let route: String
}

/// Drop-Annahme wie Spike eselsohr-drop (DropSaver), Reihenfolge nach Report 01, Abschnitt 5:
///   1. File-Promise mit Bild-UTI (C14; asynchron, eigene OperationQueue) → incoming/<drop>/ → images/<uuid>.<ext>
///   2. fileURL → images/<uuid>.<ext>: synchron nur ein APFS-Klon (clonefile, < 1 ms) bzw. bei kurzlebigen
///      Temp-Dateien eine Kopie; alle anderen Quellen werden im Hintergrund kopiert (P3/C15)
///   3. Bilddaten (png/jpeg/heic/tiff): synchron nur `data(forType:)` lesen; Schreiben (TIFF → PNG) und
///      Dekodieren im Hintergrund (P2), Vorschau sofort aus den Daten (B2)
///   4. Web-URL → nur geloggt
/// In performDragOperation läuft kein Dekodieren/Kodieren mehr. Schwere Arbeit: ImageDecoder.importQueue (seriell).
/// Ergebnisse gehen auf dem Main Actor an den ImportSink.
@MainActor
final class ImageImporter {
    static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    static let heic = NSPasteboard.PasteboardType("public.heic")

    /// Registrierte Typen (wie Spike).
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            + [.fileURL, .png, .tiff, jpeg, heic, .URL]
    }

    /// Nur Bilder im Prototyp: Finder-Dateien werden nach Endung gefiltert, bevor kopiert wird.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]
    /// Reihenfolge = Vorrang beim Weg imageData: komprimierte Formate vor TIFF (TIFF ist groß; jedes
    /// `data(forType:)` kopiert den Inhalt synchron per IPC aus der Quell-App).
    static let imageDataTypes: [NSPasteboard.PasteboardType] = [.png, jpeg, heic, .tiff]

    weak var sink: ImportSink?
    var scale: CGFloat
    /// `--diag-pasteboard`: voller Pasteboard-Dump (liest Daten aller Typen) und Lebensdauer-Checks der
    /// Quelldateien. Ohne: nur Typnamen und Anzahl Items (P1/C6/P9).
    var diagPasteboard = LaunchOptions.diagPasteboardRequested
    private let store: BoardStore
    private let promiseQueue: OperationQueue
    private var lastSourcePaths: [String] = []
    private var sources: [UUID: ItemSource] = [:]
    private var deliveredPromiseTickets = Set<UUID>()

    /// C17: Herkunft je Promise-Receiver, bis alle versprochenen Dateien geliefert sind.
    private struct PromiseGroup {
        let base: ItemSource
        let expected: Int
        var delivered: Int
    }
    private var promiseGroups: [UUID: PromiseGroup] = [:]

    init(store: BoardStore, scale: CGFloat) {
        self.store = store
        self.scale = scale
        promiseQueue = OperationQueue()
        promiseQueue.name = "Dropboard.promises"
        promiseQueue.qualityOfService = .userInitiated
    }

    // MARK: Vorab-Prüfung (draggingEntered)

    /// Enthält der Drag voraussichtlich ein Bild? Liest nur Typen, Promise-Receiver (fileTypes) und fileURLs,
    /// löst kein Promise aus und liest keine Bilddaten.
    func looksLikeImage(_ info: NSDraggingInfo) -> Bool {
        let pb = info.draggingPasteboard
        let types = Set((pb.types ?? []).map { $0.rawValue })
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes)
        // C14: ein Promise zählt nur, wenn es einen Bild-UTI ankündigt (sonst z. B. PDF aus Mail).
        // ⚠️ VERIFIZIEREN: readObjects(NSFilePromiseReceiver) in draggingEntered löst das Promise nicht aus
        // (laut Review C14; erst receivePromisedFiles schreibt).
        if !types.isDisjoint(with: promiseTypes),
           promiseReceivers(pb).contains(where: { Self.announcesImage($0.fileTypes) }) {
            return true
        }
        if Self.imageDataTypes.contains(where: { types.contains($0.rawValue) }) { return true }
        return fileURLs(pb).contains { Self.imageExtensions.contains(resolved($0).pathExtension.lowercased()) }
    }

    /// Kündigt ein Promise mindestens einen Bildtyp an? `fileTypes` sind UTIs; ältere Quellen liefern evtl.
    /// Dateiendungen. Leer = unbekannt = kein Bild.
    // ⚠️ VERIFIZIEREN: UTType("jpg") ist nil (kein UTI), UTType(filenameExtension: "jpg") = .jpeg.
    nonisolated static func announcesImage(_ fileTypes: [String]) -> Bool {
        fileTypes.contains { raw in
            if let type = UTType(raw), type.conforms(to: .image) { return true }
            if let type = UTType(filenameExtension: raw), type.conforms(to: .image) { return true }
            return false
        }
    }

    // MARK: Annahme (performDragOperation)

    /// Muss in performDragOperation laufen (Promise nur während des Drops, Temp-Datei kurzlebig).
    /// Liefert die Tickets, für die der Aufrufer sofort Platzhalter anlegt. Leer = nichts angenommen.
    /// Auf dem Main Thread nur: Typen/URLs lesen, ggf. Bilddaten lesen, APFS-Klon bzw. Kopie kurzlebiger Temp-Dateien.
    func receive(_ info: NSDraggingInfo, app: String?) -> [ImportTicket] {
        let start = Log.now
        let pb = info.draggingPasteboard
        let urls = fileURLs(pb)
        let origin = originURL(pb)
        lastSourcePaths = urls.map { resolved($0).path }
        if diagPasteboard {
            probeSources("t=0 (performDragOperation)")
            FileProbe.scheduleLifetimeChecks(lastSourcePaths)   // P9: nur noch mit --diag-pasteboard
        }
        if let origin = origin {
            Log.line("[DROP]", "Herkunft url=\(origin) app=\(app ?? "nil")")
        }

        var tickets: [ImportTicket] = []
        let allReceivers = promiseReceivers(pb)
        let receivers = allReceivers.filter { Self.announcesImage($0.fileTypes) }
        if receivers.count < allReceivers.count {
            Log.line("[DROP]", "Promise ohne Bild-UTI ignoriert (\(allReceivers.count - receivers.count) von \(allReceivers.count)) "
                + "fileTypes=\(allReceivers.map { $0.fileTypes })")
        }
        if !receivers.isEmpty {
            tickets = receivePromises(receivers, app: app, origin: origin)
        } else {
            tickets = secureFileURLs(urls, app: app, origin: origin)
            if tickets.isEmpty, let written = receiveImageData(pb, app: app, origin: origin) {
                tickets = [written]
            }
        }
        if tickets.isEmpty {
            if let s = pb.string(forType: .URL) {
                Log.line("[DROP]", "Weg=Web-URL nur geloggt, kein Download im Prototyp: \(s)")
            } else {
                Log.line("[DROP]", "Kein verwertbarer Typ – nichts gesichert")
            }
        }
        Log.line("[DROP]", "receive Main-Thread \(Log.ms(since: start))ms tickets=\(tickets.count) (Sichern/Dekodieren läuft im Hintergrund)")
        return tickets
    }

    /// 1. File-Promise: alle Receiver eines Drags bekommen denselben Zielordner (Report 01, [Q3]).
    private func receivePromises(_ receivers: [NSFilePromiseReceiver], app: String?, origin: String?) -> [ImportTicket] {
        let start = Log.now
        let dest = store.incomingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            Log.line("[DROP]", "FEHLER Zielordner \(dest.path): \(error.localizedDescription)")
            return []
        }
        Log.line("[DROP]", "Weg=File-Promise receiver=\(receivers.count) ziel=\(dest.path)")
        var tickets: [ImportTicket] = []
        for (i, receiver) in receivers.enumerated() {
            let ticketID = UUID()
            let base = ItemSource(route: "promise", originalName: receiver.fileNames.first, app: app, originalURL: origin)
            promiseGroups[ticketID] = PromiseGroup(base: base, expected: max(1, receiver.fileNames.count), delivered: 0)
            tickets.append(ImportTicket(id: ticketID, route: "promise"))
            Log.line("[DROP]", "Promise\(i) id=\(ticketID.uuidString) fileNames=\(receiver.fileNames) fileTypes=\(receiver.fileTypes)")
            // Reader läuft auf promiseQueue: dort nur Log/FileProbe, dann per Task zurück auf den Main Actor.
            receiver.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: promiseQueue) { @Sendable url, error in
                let elapsed = Log.ms(since: start)
                let message: String? = error.map { $0.localizedDescription }
                if let message = message {
                    Log.line("[DROP]", "Promise\(i) FEHLER nach \(elapsed)ms: \(message) | \(FileProbe.info(url))")
                } else {
                    Log.line("[DROP]", "Promise\(i) vollständig nach \(elapsed)ms | \(FileProbe.info(url))")
                }
                Task { @MainActor in
                    self.promiseDelivered(ticketID: ticketID, url: url, errorMessage: message)
                }
            }
        }
        Log.line("[DROP]", "receivePromisedFiles zurückgekehrt nach \(Log.ms(since: start))ms (Datei folgt asynchron)")
        return tickets
    }

    private func promiseDelivered(ticketID: UUID, url: URL, errorMessage: String?) {
        // Ein Receiver kann mehrere Dateien versprechen: die erste füllt den Platzhalter, jede weitere wird ein neues Item.
        var itemID = ticketID
        if deliveredPromiseTickets.contains(ticketID) {
            itemID = UUID()
            Log.line("[DROP]", "weitere Promise-Datei zu \(ticketID.uuidString) → neues Item \(itemID.uuidString)")
        }
        deliveredPromiseTickets.insert(ticketID)

        // C17: Herkunft je Datei aus der Gruppe des Receivers; die Gruppe lebt, bis alle Dateien da sind.
        var source = ItemSource(route: "promise")
        if var group = promiseGroups[ticketID] {
            source = group.base
            group.delivered += 1
            promiseGroups[ticketID] = group.delivered >= group.expected ? nil : group
        }
        if !url.lastPathComponent.isEmpty { source.originalName = url.lastPathComponent }
        sources[itemID] = source

        if let message = errorMessage {
            try? FileManager.default.removeItem(at: url)
            finish(itemID, .failed("Promise-Fehler: \(message)"))
            return
        }
        let fileName = BoardStore.imageFileName(id: itemID, fileExtension: url.pathExtension)
        let target = store.imageURL(fileName: fileName)
        let incoming = url.deletingLastPathComponent()
        runImport(itemID, fileName: fileName, target: target, data: nil, label: "Promise") {
            try FileManager.default.moveItem(at: url, to: target)
            ImageImporter.removeIfEmpty(incoming)
        }
    }

    /// 2. fileURL. Die Thumbnail-Temp-Datei (TemporaryItems/NSIRD_screencaptureui_*) verschwindet kurz nach dem
    /// Drag (Report 01, Q11/Q12/Q17: synchron lesen ging, asynchron ENOENT) → sie wird vor der Rückkehr gesichert:
    ///   a) clonefile(2): APFS-Klon, O(1) unabhängig von der Größe, schlägt über Volumegrenzen/ohne APFS sofort fehl.
    ///      /var/folders und ~/Library liegen auf demselben Daten-Volume → der Thumbnail-Fall ist immer ein Klon.
    ///   b) Klon geht nicht und Quelle ist kurzlebig (Temp-Pfad): synchrone Kopie (Korrektheit vor Latenz).
    ///   c) sonst (Finder, externes Volume, NAS, iCloud): Kopie im Hintergrund, Platzhalter sofort.
    private func secureFileURLs(_ urls: [URL], app: String?, origin: String?) -> [ImportTicket] {
        var tickets: [ImportTicket] = []
        for url in urls {
            let src = resolved(url)
            let ext = src.pathExtension.lowercased()
            guard Self.imageExtensions.contains(ext) else {
                Log.line("[DROP]", "Weg=fileURL übersprungen (kein Bild nach Endung): \(src.path)")
                continue
            }
            let id = UUID()
            let fileName = BoardStore.imageFileName(id: id, fileExtension: ext)
            let target = store.imageURL(fileName: fileName)
            let t = Log.now
            let how: String
            let prepare: @Sendable () throws -> Void
            let cloneErrno = Self.isUbiquitous(src) ? ENOTSUP : Self.cloneFile(from: src, to: target)
            if cloneErrno == 0 {
                how = "APFS-Klon synchron"
                prepare = {}
            } else if Self.isShortLivedTemporary(path: src.path) {
                do {
                    try FileManager.default.copyItem(at: src, to: target)
                } catch {
                    Log.line("[DROP]", "Weg=fileURL FEHLER Sync-Kopie nach \(Log.ms(since: t))ms quelle=\(src.path): \(error.localizedDescription)")
                    continue
                }
                how = "Sync-Kopie (kurzlebige Temp-Datei, Klon errno=\(cloneErrno))"
                prepare = {}
            } else {
                how = "Kopie im Hintergrund (Klon errno=\(cloneErrno))"
                prepare = { try FileManager.default.copyItem(at: src, to: target) }
            }
            Log.line("[DROP]", "Weg=fileURL \(how) Main-Thread \(Log.ms(since: t))ms quelle=\(src.path)")
            sources[id] = ItemSource(route: "fileURL", originalPath: src.path, originalName: src.lastPathComponent,
                                     app: app, originalURL: origin)
            tickets.append(ImportTicket(id: id, route: "fileURL"))
            runImport(id, fileName: fileName, target: target, data: nil, label: "fileURL", prepare: prepare)
        }
        return tickets
    }

    /// 3. Bilddaten: synchron nur lesen (geht nur während der Drag-Session). PNG/JPEG/HEIC werden unverändert
    /// geschrieben, TIFF wird im Hintergrund nach PNG gewandelt (Platz). Kein Kodieren auf dem Main Thread (P2).
    private func receiveImageData(_ pb: NSPasteboard, app: String?, origin: String?) -> ImportTicket? {
        for type in Self.imageDataTypes {
            let t = Log.now
            guard let data = pb.data(forType: type) else { continue }
            let readMs = Log.ms(since: t)
            let convertTIFF = type == .tiff
            let ext: String
            switch type {
            case .png, .tiff: ext = "png"
            case Self.jpeg: ext = "jpg"
            default: ext = "heic"
            }
            let id = UUID()
            let fileName = BoardStore.imageFileName(id: id, fileExtension: ext)
            let target = store.imageURL(fileName: fileName)
            Log.line("[DROP]", "Weg=Bilddaten \(type.rawValue) \(data.count)B gelesen in \(readMs)ms → "
                + (convertTIFF ? "PNG-Wandlung" : "Schreiben") + " und Dekodieren im Hintergrund")
            sources[id] = ItemSource(route: "imageData", originalName: nil, app: app, originalURL: origin)
            runImport(id, fileName: fileName, target: target, data: data, label: "Bilddaten \(type.rawValue)") {
                if convertTIFF {
                    try ImageDecoder.writePNG(from: data, to: target)
                } else {
                    try data.write(to: target, options: .atomic)
                }
            }
            return ImportTicket(id: id, route: "imageData")
        }
        return nil
    }

    // MARK: Sichern + Dekodieren im Hintergrund, Abliefern auf dem Main Actor

    private func runImport(_ id: UUID, fileName: String, target: URL, data: Data?, label: String,
                           prepare: @escaping @Sendable () throws -> Void) {
        ImageDecoder.importInBackground(target: target, data: data, scale: scale, prepare: prepare,
                                        preview: { [weak self] image in
            guard let self = self else { return }
            self.sink?.importFinished(id: id, result: .preview(image: image))
        }, completion: { [weak self] outcome in
            guard let self = self else { return }
            self.importDone(id, fileName: fileName, target: target, label: label, outcome: outcome)
        })
    }

    private func importDone(_ id: UUID, fileName: String, target: URL, label: String, outcome: ImportOutcome) {
        if let error = outcome.error {
            finish(id, .failed("\(label): Sichern fehlgeschlagen nach \(outcome.prepareMs)ms: \(error)"))
            return
        }
        guard let decoded = outcome.image else {
            try? FileManager.default.removeItem(at: target)
            finish(id, .failed("kein lesbares Bild (\(fileName)), eigene Kopie entfernt"))
            return
        }
        Log.line("[DROP]", "\(label) gesichert in \(outcome.prepareMs)ms, dekodiert in \(outcome.decodeMs)ms (Hintergrund) "
            + "id=\(id.uuidString) größe=\(Int(decoded.size.width))x\(Int(decoded.size.height))pt")
        let source = sources[id] ?? ItemSource(route: "unbekannt")
        finish(id, .image(fileName: fileName, image: decoded, source: source))
    }

    private func finish(_ id: UUID, _ result: ImportResult) {
        if case .failed(let reason) = result {
            Log.line("[DROP]", "Import FEHLER id=\(id.uuidString): \(reason)")
        }
        sources[id] = nil
        sink?.importFinished(id: id, result: result)
    }

    // MARK: Pasteboard-Logging

    /// Normalbetrieb (P1/C6): eine Zeile mit Typnamen und Anzahl Items – kein `data(forType:)`, kein Dateizugriff.
    /// Mit `--diag-pasteboard`: zusätzlich der volle Dump aus dem Spike (liest die Daten aller Typen synchron!).
    func dumpPasteboard(_ info: NSDraggingInfo, phase: String, window: String) {
        let pb = info.draggingPasteboard
        let source = info.draggingSource == nil ? "nil (fremder Prozess)" : "eigener Prozess"
        let types = (pb.types ?? []).map { $0.rawValue }.joined(separator: ",")
        Log.line("[PB]", "\(phase) win=\(window) seq=\(info.draggingSequenceNumber) draggingSource=\(source) "
            + "sourceOpMask=0x\(String(info.draggingSourceOperationMask.rawValue, radix: 16)) "
            + "items=\(pb.pasteboardItems?.count ?? 0) validItems=\(info.numberOfValidItemsForDrop) "
            + "changeCount=\(pb.changeCount) types=[\(types)]" + (diagPasteboard ? " (diag: voller Dump)" : ""))
        guard diagPasteboard else { return }
        for (i, item) in (pb.pasteboardItems ?? []).enumerated() {
            for type in item.types {
                Log.line("[PB]", "  item\(i) \(type.rawValue): \(describe(item, type))")
            }
        }
        for url in fileURLs(pb) {
            Log.line("[PB]", "  readObjects(NSURL) \(FileProbe.info(url))")
        }
    }

    private func describe(_ item: NSPasteboardItem, _ type: NSPasteboard.PasteboardType) -> String {
        let raw = type.rawValue
        // Promise-Rohtypen nicht anfassen (Report 01 Q6). ⚠️ VERIFIZIEREN (aus Spike): ob Lesen Nebenwirkungen hätte.
        if raw.lowercased().contains("promise") { return "(Promise-Typ, Inhalt nicht gelesen)" }
        if type == .fileURL {
            guard let s = item.string(forType: type) else { return "string=nil" }
            guard let url = URL(string: s) else { return s }
            return "\(s) → \(FileProbe.info(url))"
        }
        guard let data = item.data(forType: type) else { return "data=nil" }
        var d = "\(data.count)B"
        if type == .URL || type == .string || raw == "public.url-name" || raw.hasPrefix("public.utf8") {
            if let s = String(data: data.prefix(200), encoding: .utf8) { d += " \"\(s)\"" }
        }
        return d
    }

    /// Existenz der Quell-fileURLs zu einem benannten Zeitpunkt (z. B. concludeDragOperation).
    /// P9: nur mit `--diag-pasteboard` (Lebensdauer-Diagnose aus dem Spike).
    func probeSources(_ label: String) {
        guard diagPasteboard else { return }
        for path in lastSourcePaths {
            Log.line("[DROP]", "Quelle \(label) exists=\(FileManager.default.fileExists(atPath: path)) \(path)")
        }
    }

    // MARK: Hilfen

    private func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func promiseReceivers(_ pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
    }

    /// B8: Web-Herkunft aus dem Drag (NSURL-Objekte ohne fileURLs, sonst `public.url`). Kleine Strings, keine Bilddaten.
    private func originURL(_ pb: NSPasteboard) -> String? {
        let objects = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        var candidates = objects.filter { !$0.isFileURL }.map { $0.absoluteString }
        if let s = pb.string(forType: .URL) { candidates.append(s) }
        return candidates.lazy.compactMap { Self.sanitizedOriginURL($0) }.first
    }

    /// Nur http/https/ftp, getrimmt, höchstens 2048 Zeichen (keine data:-URLs mit eingebettetem Bild, keine file:).
    nonisolated static func sanitizedOriginURL(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 2048, let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme) else { return nil }
        return s
    }

    /// Pfade, deren Dateien nach dem Drag verschwinden können (Screenshot-Thumbnail: TemporaryItems unter /var/folders).
    nonisolated static func isShortLivedTemporary(path: String) -> Bool {
        if path.contains("/TemporaryItems/") { return true }
        let prefixes = ["/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    /// clonefile(2) ohne Flags (Symlinks werden aufgelöst). Rückgabe 0 = geklont, sonst errno
    /// (z. B. EXDEV über Volumegrenzen, ENOTSUP ohne APFS, EEXIST). Legt bei Fehlschlag keine Teildatei an.
    // ⚠️ VERIFIZIEREN: clonefile aus sys/clonefile.h ist über `import Darwin` als clonefile(_:_:_:) sichtbar.
    nonisolated static func cloneFile(from src: URL, to dst: URL) -> Int32 {
        src.withUnsafeFileSystemRepresentation { s -> Int32 in
            dst.withUnsafeFileSystemRepresentation { d -> Int32 in
                guard let s = s, let d = d else { return EINVAL }
                if clonefile(s, d, 0) == 0 { return 0 }
                let code = errno   // direkt nach dem Aufruf lesen
                return code == 0 ? EINVAL : code
            }
        }
    }

    /// iCloud-Dateien evtl. noch nicht lokal (dataless): nie synchron klonen/kopieren, sondern im Hintergrund.
    // ⚠️ VERIFIZIEREN: Verhalten von clonefile auf dataless Dateien (Fehler oder blockierender Download) ist
    // unbelegt; deshalb vorher isUbiquitousItemKey prüfen (getattrlist, ohne Download).
    nonisolated static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }

    private func resolved(_ url: URL) -> URL { (url as NSURL).filePathURL ?? url }

    nonisolated static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }
}
