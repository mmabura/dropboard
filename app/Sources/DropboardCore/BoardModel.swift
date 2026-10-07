import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Board-Koordinaten: pt, Ursprung OBEN LINKS des Boards (= Bildschirm-Frame), y nach unten.
// So entspricht die Lesereihenfolge (oben links → rechts → nächste Zeile) aufsteigendem y/x,
// und Inhalte bleiben oben links verankert, wenn sich die Bildschirmhöhe ändert.
// Die Umrechnung in Layer-Koordinaten (y nach oben) passiert an genau einer Stelle (BoardScene).

public struct BoardPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }

    public var cgPoint: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
}

public struct BoardSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        width = Double(size.width)
        height = Double(size.height)
    }

    public var cgSize: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
}

/// Herkunft eines Bildes, soweit beim Drop bekannt.
/// Abwärtskompatibel: alle Felder außer `route` sind optional; der synthetisierte Codable-Code liest fehlende
/// Schlüssel als nil (decodeIfPresent) und schreibt nil-Felder nicht (encodeIfPresent). Alte board.json laden weiter.
public struct ItemSource: Codable, Equatable, Sendable {
    /// "promise", "fileURL" oder "imageData"
    public var route: String
    /// Quellpfad (nur Weg fileURL)
    public var originalPath: String?
    /// Ursprünglicher Dateiname (Promise: Name der gelieferten Datei, je Datei)
    public var originalName: String?
    /// Bundle-ID der vordersten App beim Drop (die Ursprungs-App)
    public var app: String?
    /// Web-Herkunft (B8): `public.url` bzw. NSURL aus dem Drag-Pasteboard, nur http/https/ftp. Neu; in alten Dateien nil.
    public var originalURL: String?

    public init(route: String, originalPath: String? = nil, originalName: String? = nil, app: String? = nil,
                originalURL: String? = nil) {
        self.route = route
        self.originalPath = originalPath
        self.originalName = originalName
        self.app = app
        self.originalURL = originalURL
    }
}

public struct BoardItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Dateiname in images/ (`<uuid>.<ext>`)
    public var fileName: String
    /// Mittelpunkt in Board-Koordinaten (oben links, y nach unten)
    public var center: BoardPoint
    /// Grad; positiv = gegen den Uhrzeigersinn auf dem Bildschirm (Core-Animation-Konvention)
    public var rotation: Double
    /// Anzeigegröße in pt (ohne Rotation)
    public var size: BoardSize
    /// Zeitpunkt des Drops, auf ganze Sekunden (siehe BoardClock)
    public var addedAt: Date
    public var source: ItemSource?
    /// Beschnitt (E11): sichtbarer Ausschnitt, normiert im orientierten Bildraum (oben links). nil = ganzes Bild.
    /// `size` ist dann die Anzeigegröße des AUSSCHNITTS. Abwärtskompatibel wie `source`: fehlt in alten Dateien
    /// (decodeIfPresent → nil) und wird bei nil nicht geschrieben (encodeIfPresent).
    public var crop: BoardCrop?

    public init(id: UUID, fileName: String, center: BoardPoint, rotation: Double, size: BoardSize,
                addedAt: Date, source: ItemSource? = nil, crop: BoardCrop? = nil) {
        self.id = id
        self.fileName = fileName
        self.center = center
        self.rotation = rotation
        self.size = size
        self.addedAt = addedAt
        self.source = source
        self.crop = crop
    }

    /// Achsenparalleler Rahmen in Board-Koordinaten (Rotation unberücksichtigt, siehe LayoutMetrics.gap).
    public var frame: CGRect { BoardLayout.frame(center: center.cgPoint, size: size.cgSize) }
}

public struct BoardDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Reihenfolge = Stapelreihenfolge (letztes Element liegt oben).
    public var items: [BoardItem]

    public init(version: Int = BoardDocument.currentVersion, items: [BoardItem] = []) {
        self.version = version
        self.items = items
    }

    public func item(id: UUID) -> BoardItem? {
        items.first { $0.id == id }
    }

    /// Ersetzt ein vorhandenes Item mit gleicher id oder hängt es oben an.
    public mutating func upsert(_ item: BoardItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.append(item)
        }
    }

    @discardableResult
    public mutating func remove(id: UUID) -> BoardItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    /// Position in der Stapelreihenfolge.
    public func index(id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// Wieder einfügen (Rückrollen eines Löschens, C10). `index` wird auf 0...items.count begrenzt.
    /// Gibt es die id schon, wird nur ersetzt (kein Duplikat).
    public mutating func insert(_ item: BoardItem, at index: Int) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
            return
        }
        items.insert(item, at: min(max(0, index), items.count))
    }

    /// Entfernt alle Items, auf die `shouldRemove` zutrifft (C9: Bilddatei fehlt). Reihenfolge der übrigen bleibt.
    /// Rückgabe: die entfernten Items in ihrer bisherigen Reihenfolge.
    @discardableResult
    public mutating func removeItems(where shouldRemove: (BoardItem) throws -> Bool) rethrows -> [BoardItem] {
        var kept: [BoardItem] = []
        var removed: [BoardItem] = []
        for item in items {
            if try shouldRemove(item) { removed.append(item) } else { kept.append(item) }
        }
        items = kept
        return removed
    }
}

public enum BoardClock {
    /// Zeitstempel auf ganze Sekunden. Das JSON speichert ISO 8601 ohne Sekundenbruchteile;
    /// so ist der Roundtrip verlustfrei.
    public static func timestamp(_ date: Date = Date()) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
