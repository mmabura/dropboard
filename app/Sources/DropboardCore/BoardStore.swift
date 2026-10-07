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
public struct BoardStore {
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
