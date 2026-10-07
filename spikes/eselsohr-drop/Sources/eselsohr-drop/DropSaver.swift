import AppKit

/// Pasteboard-Logging und Sicherung eines Drops nach Report 01, Abschnitt 5:
/// 1. File-Promise (asynchron, eigene OperationQueue) → 2. fileURL (synchron kopieren) → 3. Bilddaten als PNG.
@MainActor
final class DropSaver {
    static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    static let heic = NSPasteboard.PasteboardType("public.heic")

    /// Registrierte Typen nach Report 01 (Ergebnis + Testplan T1).
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            + [.fileURL, .png, .tiff, jpeg, heic, .URL]
    }

    let incomingRoot: URL
    private let promiseQueue: OperationQueue
    private var lastSourcePaths: [String] = []

    init() {
        incomingRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DropboardSpike/Incoming", isDirectory: true)
        promiseQueue = OperationQueue()
        promiseQueue.name = "DropboardSpike.promises"
        promiseQueue.qualityOfService = .userInitiated
    }

    // MARK: Logging

    /// Alle Items mit allen Typen, Quelle, Operation-Mask, Promise-Receiver und fileURLs.
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
        // ⚠️ VERIFIZIEREN: readObjects(NSFilePromiseReceiver) schon in draggingEntered ist harmlos (Report 01 liest nur beim Drop).
        for (i, r) in promiseReceivers(pb).enumerated() {
            Log.line("[PB]", "  promise\(i) fileNames=\(r.fileNames) fileTypes=\(r.fileTypes)")
        }
        for url in fileURLs(pb) {
            Log.line("[PB]", "  readObjects(NSURL) \(FileProbe.info(url))")
        }
    }

    private func describe(_ item: NSPasteboardItem, _ type: NSPasteboard.PasteboardType) -> String {
        let raw = type.rawValue
        // Promise-Rohtypen nicht anfassen: Daten anzufordern könnte das Promise auslösen (alte API, Report 01 Q6).
        // ⚠️ VERIFIZIEREN: Ob das Lesen dieser Typen wirklich Nebenwirkungen hätte.
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

    private func promiseReceivers(_ pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
    }

    private func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Existenz der Quell-fileURLs zu einem benannten Zeitpunkt (z. B. concludeDragOperation).
    func probeSources(_ label: String) {
        for path in lastSourcePaths {
            Log.line("[DROP]", "Quelle \(label) exists=\(FileManager.default.fileExists(atPath: path)) \(path)")
        }
    }

    // MARK: Sichern

    /// Muss in performDragOperation aufgerufen werden (Report 01: Promise nur während des Drops, Temp-Datei kurzlebig).
    func save(_ info: NSDraggingInfo) -> Bool {
        let pb = info.draggingPasteboard
        let start = Log.now
        let dest = incomingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            Log.line("[DROP]", "FEHLER Zielordner \(dest.path): \(error.localizedDescription)")
            return false
        }

        let urls = fileURLs(pb)
        lastSourcePaths = urls.map { (($0 as NSURL).filePathURL ?? $0).path }
        probeSources("t=0 (performDragOperation)")
        FileProbe.scheduleLifetimeChecks(lastSourcePaths)

        // 1. File-Promise
        let receivers = promiseReceivers(pb)
        if !receivers.isEmpty {
            Log.line("[DROP]", "Weg=File-Promise receiver=\(receivers.count) ziel=\(dest.path)")
            for (i, receiver) in receivers.enumerated() {
                // Reader läuft auf promiseQueue: nur Log/FileProbe benutzen, keinen MainActor-Zustand.
                receiver.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: promiseQueue) { @Sendable url, error in
                    let elapsed = Log.ms(since: start)
                    if let error = error {
                        Log.line("[DROP]", "Promise\(i) FEHLER nach \(elapsed)ms: \(error.localizedDescription) | \(FileProbe.info(url))")
                    } else {
                        Log.line("[DROP]", "Promise\(i) vollständig nach \(elapsed)ms | \(FileProbe.info(url))")
                    }
                }
            }
            Log.line("[DROP]", "receivePromisedFiles zurückgekehrt nach \(Log.ms(since: start))ms (Datei folgt asynchron)")
            return true
        }

        // 2. fileURL, synchron
        var copied = 0
        for url in urls {
            let src = (url as NSURL).filePathURL ?? url
            let target = dest.appendingPathComponent(src.lastPathComponent)
            let t = Log.now
            do {
                try FileManager.default.copyItem(at: src, to: target)
                copied += 1
                Log.line("[DROP]", "Weg=fileURL kopiert in \(Log.ms(since: t))ms quelle=\(src.path) | \(FileProbe.info(target))")
            } catch {
                Log.line("[DROP]", "Weg=fileURL FEHLER nach \(Log.ms(since: t))ms quelle=\(src.path): \(error.localizedDescription)")
            }
        }
        if copied > 0 { return true }

        // 3. Bilddaten → PNG
        for type in [NSPasteboard.PasteboardType.png, .tiff, DropSaver.jpeg, DropSaver.heic] {
            guard let data = pb.data(forType: type) else { continue }
            let t = Log.now
            let png: Data? = type == .png ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            guard let out = png else {
                Log.line("[DROP]", "Weg=Bilddaten \(type.rawValue) (\(data.count)B) PNG-Konvertierung fehlgeschlagen")
                continue
            }
            let target = dest.appendingPathComponent("drop.png")
            do {
                try out.write(to: target, options: .atomic)
                Log.line("[DROP]", "Weg=Bilddaten \(type.rawValue) → PNG in \(Log.ms(since: t))ms | \(FileProbe.info(target))")
                return true
            } catch {
                Log.line("[DROP]", "Weg=Bilddaten FEHLER: \(error.localizedDescription)")
            }
        }

        // 4. Web-URL: im Spike nur geloggt (Report 01: Priorität 2)
        if let s = pb.string(forType: .URL) {
            Log.line("[DROP]", "Weg=Web-URL nur geloggt, kein Download im Spike: \(s)")
        } else {
            Log.line("[DROP]", "Kein verwertbarer Typ – nichts gesichert")
        }
        try? FileManager.default.removeItem(at: dest)
        return false
    }
}
