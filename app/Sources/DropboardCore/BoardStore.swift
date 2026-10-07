import Foundation

public enum BoardStoreError: Error, CustomStringConvertible {
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v):
            return "board.json hat Version \(v), unterstützt bis \(BoardDocument.currentVersion)"
        }
    }
}

/// Dateiablage eines Boards:
///   <boardDirectory>/board.json        Layout (Codable, atomisch geschrieben)
///   <boardDirectory>/images/<uuid>.<ext>  Bildkopien
///   <boardDirectory>/incoming/<uuid>/  Zielordner für File-Promises (danach nach images/ verschoben)
public struct BoardStore: Sendable {
    public static let documentFileName = "board.json"
    public static let fallbackExtension = "png"

    public let boardDirectory: URL

    public init(boardDirectory: URL) {
        self.boardDirectory = boardDirectory
    }

    /// ~/Library/Application Support/Dropboard/Boards/default
    public static func defaultBoardDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Dropboard/Boards/default", isDirectory: true)
    }

    public var imagesDirectory: URL { boardDirectory.appendingPathComponent("images", isDirectory: true) }
    public var incomingDirectory: URL { boardDirectory.appendingPathComponent("incoming", isDirectory: true) }
    public var documentURL: URL { boardDirectory.appendingPathComponent(Self.documentFileName) }

    public func imageURL(fileName: String) -> URL {
        imagesDirectory.appendingPathComponent(fileName)
    }

    /// `<UUID>.<ext>`; ext klein geschrieben, nur [a-z0-9], sonst "png".
    public static func imageFileName(id: UUID, fileExtension: String) -> String {
        let ext = fileExtension.lowercased()
        let valid = !ext.isEmpty && ext.count <= 8 && ext.unicodeScalars.allSatisfy {
            ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39)
        }
        return "\(id.uuidString).\(valid ? ext : fallbackExtension)"
    }

    public func prepareDirectories() throws {
        let fm = FileManager.default
        for dir in [boardDirectory, imagesDirectory, incomingDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Fehlt board.json, ist das Board leer. Defekte oder zu neue Dateien werfen.
    public func load() throws -> BoardDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return BoardDocument() }
        let data = try Data(contentsOf: documentURL)
        let document = try Self.makeDecoder().decode(BoardDocument.self, from: data)
        guard document.version <= BoardDocument.currentVersion else {
            throw BoardStoreError.unsupportedVersion(document.version)
        }
        return document
    }

    /// Atomisch: Foundation schreibt in eine Hilfsdatei und benennt sie dann um.
    public func save(_ document: BoardDocument) throws {
        let data = try Self.makeEncoder().encode(document)
        try data.write(to: documentURL, options: .atomic)
    }

    /// Benennt eine nicht lesbare board.json in `board.corrupt-<unix>.json` um, damit sie nicht überschrieben wird.
    @discardableResult
    public func quarantineDocument(now: Date = Date()) throws -> URL {
        let target = boardDirectory.appendingPathComponent("board.corrupt-\(Int(now.timeIntervalSince1970)).json")
        try FileManager.default.moveItem(at: documentURL, to: target)
        return target
    }

    /// Laden mit Quarantäne (C20). Siehe `resolveLoad`.
    public func loadOrQuarantine(now: Date = Date()) -> BoardLoadOutcome {
        Self.resolveLoad(load: { try load() }, quarantine: { try quarantineDocument(now: now) })
    }

    /// Reine Entscheidung (testbar mit Closures):
    ///   lesbar                      → .loaded
    ///   nicht lesbar, umbenannt     → .quarantined  (leer starten, Speichern erlaubt – die alte Datei ist gesichert)
    ///   nicht lesbar, Umbenennen scheitert → .unrecoverable (leer starten, Speichern GESPERRT: sonst würde das
    ///                                        nächste Speichern die nicht gesicherte board.json überschreiben)
    public static func resolveLoad(load: () throws -> BoardDocument, quarantine: () throws -> URL) -> BoardLoadOutcome {
        do {
            return .loaded(try load())
        } catch let loadError {
            do {
                return .quarantined(error: loadError, movedTo: try quarantine())
            } catch let quarantineError {
                return .unrecoverable(error: loadError, quarantineError: quarantineError)
            }
        }
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Ergebnis von `BoardStore.loadOrQuarantine()`.
public enum BoardLoadOutcome {
    case loaded(BoardDocument)
    case quarantined(error: Error, movedTo: URL)
    case unrecoverable(error: Error, quarantineError: Error)

    /// Startdokument: geladen oder leer.
    public var document: BoardDocument {
        if case .loaded(let document) = self { return document }
        return BoardDocument()
    }

    /// Darf diese Sitzung board.json schreiben? Nein nur bei `.unrecoverable` (C20).
    public var allowsSaving: Bool {
        if case .unrecoverable = self { return false }
        return true
    }
}

/// P10: Kodieren und atomisches Schreiben von board.json auf einer seriellen Hintergrund-Queue.
/// Der Aufrufer übergibt einen Wert-Snapshot des Dokuments (Struct-Kopie); Schreibreihenfolge = Aufrufreihenfolge,
/// das zuletzt übergebene Dokument liegt also am Ende auf der Platte. `completion` läuft auf der Queue,
/// direkt nach dem Schreiben – dort darf der Aufrufer Folgearbeit anhängen, die erst nach erfolgreichem
/// Speichern passieren darf (C10: Bilddatei nach trash/), sie bleibt in derselben Reihenfolge.
public final class BoardSaveQueue: @unchecked Sendable {
    // @unchecked: einzige gespeicherte Eigenschaft ist die (thread-sichere) DispatchQueue.
    private let queue: DispatchQueue

    public init(label: String = "Dropboard.save") {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Erfolg: Dauer in ms (Kodieren + Schreiben).
    public func save(_ document: BoardDocument, to store: BoardStore,
                     completion: @escaping @Sendable (Result<Double, Error>) -> Void) {
        queue.async {
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                try store.save(document)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                completion(.success(ms))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Wartet, bis alle bis jetzt eingereihten Schreibvorgänge (inkl. completion) fertig sind.
    /// Für Beenden und Selftests; nicht im Drag-Pfad aufrufen.
    public func flush() {
        queue.sync {}
    }
}
