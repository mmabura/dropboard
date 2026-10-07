import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Board-Koordinaten: pt, Ursprung OBEN LINKS des Boards (= Bildschirm-Frame), y nach unten.
// So entspricht die Lesereihenfolge (oben links → rechts → nächste Zeile) aufsteigendem y/x,
// und Inhalte bleiben oben links verankert, wenn sich die Bildschirmhöhe ändert.
// Die Umrechnung in Layer-Koordinaten (y nach oben) passiert an genau einer Stelle (BoardScene).

public struct BoardPoint: Codable, Equatable {
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

public struct BoardSize: Codable, Equatable {
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
public struct ItemSource: Codable, Equatable {
    /// "promise", "fileURL" oder "imageData"
    public var route: String
    /// Quellpfad (nur Weg fileURL)
    public var originalPath: String?
    /// Ursprünglicher Dateiname (Promise: erster Eintrag von fileNames)
    public var originalName: String?
    /// Bundle-ID der vordersten App beim Drop (die Ursprungs-App)
    public var app: String?

    public init(route: String, originalPath: String? = nil, originalName: String? = nil, app: String? = nil) {
        self.route = route
        self.originalPath = originalPath
        self.originalName = originalName
        self.app = app
    }
}

public struct BoardItem: Codable, Equatable, Identifiable {
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

    public init(id: UUID, fileName: String, center: BoardPoint, rotation: Double, size: BoardSize,
                addedAt: Date, source: ItemSource? = nil) {
        self.id = id
        self.fileName = fileName
        self.center = center
        self.rotation = rotation
        self.size = size
        self.addedAt = addedAt
        self.source = source
    }

    /// Achsenparalleler Rahmen in Board-Koordinaten (Rotation unberücksichtigt, siehe LayoutMetrics.gap).
    public var frame: CGRect { BoardLayout.frame(center: center.cgPoint, size: size.cgSize) }
}

public struct BoardDocument: Codable, Equatable {
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
}

public enum BoardClock {
    /// Zeitstempel auf ganze Sekunden. Das JSON speichert ISO 8601 ohne Sekundenbruchteile;
    /// so ist der Roundtrip verlustfrei.
    public static func timestamp(_ date: Date = Date()) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
