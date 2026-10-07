import AppKit
import DropboardCore

enum ImportResult {
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
///   1. File-Promise (asynchron, eigene OperationQueue) → incoming/<drop>/ → images/<uuid>.<ext>
///   2. fileURL (synchron in performDragOperation kopiert) → images/<uuid>.<ext>
///   3. Bilddaten (png/tiff/jpeg/heic) → images/<uuid>.png
///   4. Web-URL → nur geloggt
/// Danach wird jedes Bild im Hintergrund dekodiert; das Ergebnis geht an den ImportSink.
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
    static let imageDataTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, jpeg, heic]

    weak var sink: ImportSink?
    var scale: CGFloat
    private let store: BoardStore
    private let promiseQueue: OperationQueue
    private var lastSourcePaths: [String] = []
    private var sources: [UUID: ItemSource] = [:]
    private var deliveredPromiseTickets = Set<UUID>()

    init(store: BoardStore, scale: CGFloat) {
        self.store = store
        self.scale = scale
        promiseQueue = OperationQueue()
        promiseQueue.name = "Dropboard.promises"
        promiseQueue.qualityOfService = .userInitiated
    }

    // MARK: Vorab-Prüfung (draggingEntered)

    /// Enthält der Drag voraussichtlich ein Bild? Liest nur Typen und fileURLs, löst kein Promise aus.
    func looksLikeImage(_ info: NSDraggingInfo) -> Bool {
        let pb = info.draggingPasteboard
        let types = Set((pb.types ?? []).map { $0.rawValue })
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes)
        if !types.isDisjoint(with: promiseTypes) { return true }
        if Self.imageDataTypes.contains(where: { types.contains($0.rawValue) }) { return true }
        return fileURLs(pb).contains { Self.imageExtensions.contains(resolved($0).pathExtension.lowercased()) }
    }

    // MARK: Annahme (performDragOperation)

    /// Muss in performDragOperation laufen (Promise nur während des Drops, Temp-Datei kurzlebig).
    /// Liefert die Tickets, für die der Aufrufer sofort Platzhalter anlegt. Leer = nichts angenommen.
    func receive(_ info: NSDraggingInfo, app: String?) -> [ImportTicket] {
        let pb = info.draggingPasteboard
        let urls = fileURLs(pb)
        lastSourcePaths = urls.map { resolved($0).path }
        probeSources("t=0 (performDragOperation)")
        FileProbe.scheduleLifetimeChecks(lastSourcePaths)

        let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                         as? [NSFilePromiseReceiver]) ?? []
        if !receivers.isEmpty { return receivePromises(receivers, app: app) }

        let copied = copyFileURLs(urls, app: app)
        if !copied.isEmpty { return copied }

        if let written = writeImageData(pb, app: app) { return [written] }

        if let s = pb.string(forType: .URL) {
            Log.line("[DROP]", "Weg=Web-URL nur geloggt, kein Download im Prototyp: \(s)")
        } else {
            Log.line("[DROP]", "Kein verwertbarer Typ – nichts gesichert")
        }
        return []
    }

    /// 1. File-Promise: alle Receiver eines Drags bekommen denselben Zielordner (Report 01, [Q3]).
    private func receivePromises(_ receivers: [NSFilePromiseReceiver], app: String?) -> [ImportTicket] {
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
            sources[ticketID] = ItemSource(route: "promise", originalName: receiver.fileNames.first, app: app)
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
            sources[itemID] = sources[ticketID]
            Log.line("[DROP]", "weitere Promise-Datei zu \(ticketID.uuidString) → neues Item \(itemID.uuidString)")
        }
        deliveredPromiseTickets.insert(ticketID)
        if let message = errorMessage {
            try? FileManager.default.removeItem(at: url)
            finish(itemID, .failed("Promise-Fehler: \(message)"))
            return
        }
        let fileName = BoardStore.imageFileName(id: itemID, fileExtension: url.pathExtension)
        let target = store.imageURL(fileName: fileName)
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            finish(itemID, .failed("Verschieben nach images/ fehlgeschlagen: \(error.localizedDescription)"))
            return
        }
        removeIfEmpty(url.deletingLastPathComponent())
        decode(itemID, url: target, fileName: fileName)
    }

    /// 2. fileURL: synchron kopieren (Thumbnail-Temp-Datei lebt nur kurz).
    private func copyFileURLs(_ urls: [URL], app: String?) -> [ImportTicket] {
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
            do {
                try FileManager.default.copyItem(at: src, to: target)
                Log.line("[DROP]", "Weg=fileURL kopiert in \(Log.ms(since: t))ms quelle=\(src.path) | \(FileProbe.info(target))")
            } catch {
                Log.line("[DROP]", "Weg=fileURL FEHLER nach \(Log.ms(since: t))ms quelle=\(src.path): \(error.localizedDescription)")
                continue
            }
            sources[id] = ItemSource(route: "fileURL", originalPath: src.path, originalName: src.lastPathComponent, app: app)
            tickets.append(ImportTicket(id: id, route: "fileURL"))
            decode(id, url: target, fileName: fileName)
        }
        return tickets
    }

    /// 3. Bilddaten → PNG (wie Spike).
    private func writeImageData(_ pb: NSPasteboard, app: String?) -> ImportTicket? {
        for type in Self.imageDataTypes {
            guard let data = pb.data(forType: type) else { continue }
            let t = Log.now
            let png: Data? = type == .png ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            guard let out = png else {
                Log.line("[DROP]", "Weg=Bilddaten \(type.rawValue) (\(data.count)B) PNG-Konvertierung fehlgeschlagen")
                continue
            }
            let id = UUID()
            let fileName = BoardStore.imageFileName(id: id, fileExtension: "png")
            let target = store.imageURL(fileName: fileName)
            do {
                try out.write(to: target, options: .atomic)
            } catch {
                Log.line("[DROP]", "Weg=Bilddaten FEHLER: \(error.localizedDescription)")
                continue
            }
            Log.line("[DROP]", "Weg=Bilddaten \(type.rawValue) → PNG in \(Log.ms(since: t))ms | \(FileProbe.info(target))")
            sources[id] = ItemSource(route: "imageData", originalName: nil, app: app)
            decode(id, url: target, fileName: fileName)
            return ImportTicket(id: id, route: "imageData")
        }
        return nil
    }

    // MARK: Dekodieren und abliefern

    private func decode(_ id: UUID, url: URL, fileName: String) {
        ImageDecoder.decodeInBackground(url: url, size: nil, scale: scale) { [weak self] decoded, elapsed in
            guard let self = self else { return }
            guard let decoded = decoded else {
                try? FileManager.default.removeItem(at: url)
                self.finish(id, .failed("kein lesbares Bild (\(fileName)), Datei entfernt"))
                return
            }
            Log.line("[DROP]", "dekodiert id=\(id.uuidString) in \(elapsed)ms größe=\(Int(decoded.size.width))x\(Int(decoded.size.height))pt")
            let source = self.sources[id] ?? ItemSource(route: "unbekannt")
            self.finish(id, .image(fileName: fileName, image: decoded, source: source))
        }
    }

    private func finish(_ id: UUID, _ result: ImportResult) {
        if case .failed(let reason) = result {
            Log.line("[DROP]", "Import FEHLER id=\(id.uuidString): \(reason)")
        }
        sources[id] = nil
        sink?.importFinished(id: id, result: result)
    }

    // MARK: Pasteboard-Logging (aus dem Spike)

    func dumpPasteboard(_ info: NSDraggingInfo, phase: String, window: String) {
        let pb = info.draggingPasteboard
        let source = info.draggingSource == nil ? "nil (fremder Prozess)" : "eigener Prozess"
        let types = (pb.types ?? []).map { $0.rawValue }.joined(separator: ",")
        Log.line("[PB]", "\(phase) win=\(window) seq=\(info.draggingSequenceNumber) draggingSource=\(source) "
            + "sourceOpMask=0x\(String(info.draggingSourceOperationMask.rawValue, radix: 16)) "
            + "items=\(pb.pasteboardItems?.count ?? 0) validItems=\(info.numberOfValidItemsForDrop) "
            + "changeCount=\(pb.changeCount) types=[\(types)]")
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
    func probeSources(_ label: String) {
        for path in lastSourcePaths {
            Log.line("[DROP]", "Quelle \(label) exists=\(FileManager.default.fileExists(atPath: path)) \(path)")
        }
    }

    // MARK: Hilfen

    private func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func resolved(_ url: URL) -> URL { (url as NSURL).filePathURL ?? url }

    private func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }
}
