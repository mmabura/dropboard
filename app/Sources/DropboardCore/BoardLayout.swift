import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Alle Layout-Zahlen an einer Stelle. Gilt in Board-Koordinaten (pt, oben links, y nach unten).
public struct LayoutMetrics: Equatable {
    /// Unsichtbares Snap-Grid; der Bildmittelpunkt snappt (wie Spike board-paper).
    public var grid: Double
    /// Mindestabstand zwischen Bild-Rahmen. Deckt auch Rotation (±2° auf 220 pt ≈ 4 pt) und Schatten ab.
    public var gap: Double
    /// Rand innerhalb des sichtbaren Bereichs (visibleFrame)
    public var margin: Double
    /// Längste Bildkante in pt (wie Spike board-paper)
    public var longestEdge: Double
    /// Platzhalter bis zur Erfüllung eines Promise. Quadratisch mit longestEdge: das echte Bild passt
    /// immer hinein, die reservierte Fläche überlappt danach also nie.
    public var placeholderSize: CGSize
    /// Betrag der Zufallsrotation in Grad; Vorzeichen zufällig
    public var tiltRange: ClosedRange<Double>

    public init(grid: Double, gap: Double, margin: Double, longestEdge: Double,
                placeholderSize: CGSize, tiltRange: ClosedRange<Double>) {
        self.grid = grid
        self.gap = gap
        self.margin = margin
        self.longestEdge = longestEdge
        self.placeholderSize = placeholderSize
        self.tiltRange = tiltRange
    }

    public static let standard = LayoutMetrics(grid: 24, gap: 12, margin: 48, longestEdge: 220,
                                               placeholderSize: CGSize(width: 220, height: 220),
                                               tiltRange: 1.0...2.0)
}

public enum BoardLayout {
    /// Punkt aufs Grid runden.
    public static func snap(_ point: CGPoint, grid: Double) -> CGPoint {
        guard grid > 0 else { return point }
        let g = CGFloat(grid)
        return CGPoint(x: (point.x / g).rounded() * g, y: (point.y / g).rounded() * g)
    }

    public static func frame(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Echte Überlappung inkl. Mindestabstand `gap`. Bei gap 0 zählt bloßes Berühren der Kanten nicht.
    /// Bewusst eigene Arithmetik statt CGRect.intersects (Randfall-Semantik).
    public static func overlaps(_ a: CGRect, _ b: CGRect, gap: Double = 0) -> Bool {
        let g = CGFloat(gap)
        return a.minX < b.maxX + g && b.minX < a.maxX + g && a.minY < b.maxY + g && b.minY < a.maxY + g
    }

    /// Quick-Drop: erster Grid-Punkt in Lesereihenfolge (oben links → rechts, dann nächste Zeile),
    /// an dem ein Rahmen der Größe `size` vollständig in `area` liegt und keinen Rahmen in `occupied`
    /// (mit Abstand `gap`) überlappt. `nil`, wenn nichts frei ist.
    public static func findFreeSlot(size: CGSize, occupied: [CGRect], area: CGRect,
                                    grid: Double, gap: Double) -> CGPoint? {
        guard grid > 0, size.width > 0, size.height > 0,
              size.width <= area.width, size.height <= area.height else { return nil }
        let g = CGFloat(grid)
        let firstX = ((area.minX + size.width / 2) / g).rounded(.up) * g
        let lastX = area.maxX - size.width / 2
        let firstY = ((area.minY + size.height / 2) / g).rounded(.up) * g
        let lastY = area.maxY - size.height / 2
        var y = firstY
        while y <= lastY {
            var x = firstX
            while x <= lastX {
                let candidate = frame(center: CGPoint(x: x, y: y), size: size)
                if !occupied.contains(where: { overlaps(candidate, $0, gap: gap) }) {
                    return CGPoint(x: x, y: y)
                }
                x += g
            }
            y += g
        }
        return nil
    }

    /// Mittelpunkt so begrenzen, dass der Rahmen in `area` liegt. Passt er nicht, die Mitte von `area`.
    public static func clampCenter(_ center: CGPoint, size: CGSize, area: CGRect) -> CGPoint {
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat, _ mid: CGFloat) -> CGFloat {
            lo <= hi ? min(max(v, lo), hi) : mid
        }
        return CGPoint(x: clamp(center.x, area.minX + size.width / 2, area.maxX - size.width / 2, area.midX),
                       y: clamp(center.y, area.minY + size.height / 2, area.maxY - size.height / 2, area.midY))
    }

    /// Drop aufs Board: Cursor → begrenzt → aufs Grid gesnappt. Schiebt der Snap den Rahmen aus
    /// `area`, geht es ein Grid-Feld nach innen; passt auch das nicht, bleibt der begrenzte Punkt.
    public static func dropCenter(cursor: CGPoint, size: CGSize, area: CGRect, grid: Double) -> CGPoint {
        let clamped = clampCenter(cursor, size: size, area: area)
        guard grid > 0 else { return clamped }
        let g = CGFloat(grid)
        var p = snap(clamped, grid: grid)
        let loX = area.minX + size.width / 2, hiX = area.maxX - size.width / 2
        let loY = area.minY + size.height / 2, hiY = area.maxY - size.height / 2
        if p.x < loX { p.x += g }
        if p.x > hiX { p.x -= g }
        if p.y < loY { p.y += g }
        if p.y > hiY { p.y -= g }
        if p.x < loX || p.x > hiX { p.x = clamped.x }
        if p.y < loY || p.y > hiY { p.y = clamped.y }
        return p
    }

    /// Anzeigegröße bei längster Kante `longestEdge` (Seitenverhältnis erhalten, auf ganze pt gerundet).
    public static func fittedSize(pixelWidth: Int, pixelHeight: Int, longestEdge: Double) -> CGSize? {
        guard pixelWidth > 0, pixelHeight > 0, longestEdge > 0 else { return nil }
        let w = Double(pixelWidth), h = Double(pixelHeight)
        let k = longestEdge / max(w, h)
        return CGSize(width: CGFloat(max(1, (w * k).rounded())), height: CGFloat(max(1, (h * k).rounded())))
    }

    /// Pixelgröße nach Anwendung der EXIF/TIFF-Orientierung (C7). Werte 5–8 drehen um 90°, Breite und Höhe
    /// tauschen. Fehlende oder unbekannte Werte verhalten sich wie 1 (unverändert).
    public static func orientedPixelSize(width: Int, height: Int, orientation: Int) -> (width: Int, height: Int) {
        (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// Gespeicherte Anzeigegröße gegen die orientierte Pixelgröße prüfen (C7: ältere Einträge haben evtl. das
    /// ungedrehte Seitenverhältnis gespeichert). Passt das Seitenverhältnis bis auf Rundung (±1 pt), bleibt
    /// `stored` exakt; sonst neu eingepasst mit derselben längsten Kante.
    public static func reconciledSize(stored: CGSize, orientedPixelWidth: Int, orientedPixelHeight: Int) -> CGSize {
        let longest = Double(max(stored.width, stored.height))
        guard longest > 0,
              let refit = fittedSize(pixelWidth: orientedPixelWidth, pixelHeight: orientedPixelHeight, longestEdge: longest)
        else { return stored }
        if abs(refit.width - stored.width) <= 1 && abs(refit.height - stored.height) <= 1 { return stored }
        return refit
    }

    /// C11: Mittelpunkte so verschieben, dass jeder Rahmen in `area` liegt (wie clampCenter; passt ein Rahmen
    /// nicht hinein, die Mitte von `area`). Items, die schon drin liegen, bleiben bitgenau. Reine Layout-Logik,
    /// keine Bildschirm-Kenntnis. Rückgabe: ids der verschobenen Items. Leere/ungültige Fläche: nichts passiert.
    @discardableResult
    public static func clampIntoArea(_ items: inout [BoardItem], area: CGRect) -> [UUID] {
        guard area.width > 0, area.height > 0 else { return [] }
        var moved: [UUID] = []
        for i in items.indices {
            let center = items[i].center.cgPoint
            let clamped = clampCenter(center, size: items[i].size.cgSize, area: area)
            if clamped != center {
                items[i].center = BoardPoint(clamped)
                moved.append(items[i].id)
            }
        }
        return moved
    }

    /// Zufallsrotation: Betrag in `range`, Vorzeichen zufällig. Zieht genau zwei Zufallswerte.
    public static func randomTilt<G: RandomNumberGenerator>(range: ClosedRange<Double>, using rng: inout G) -> Double {
        let magnitude = rng.nextDouble(in: range.lowerBound, range.upperBound)
        return rng.nextUnit() < 0.5 ? -magnitude : magnitude
    }
}
