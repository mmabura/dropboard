import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Export der Zeichenfläche (E12): reine Logik, nur Foundation/CoreGraphics, deshalb im Selftest prüfbar
// (SelfTestExport.swift). Rendern und Schreiben liegen im App-Target (Exporter.swift).
//
// Koordinaten wie überall in DropboardCore: Board-Koordinaten in pt, Ursprung oben links, y nach unten.
// Rotation in Grad, positiv = gegen den Uhrzeigersinn auf dem Bildschirm (CropMath.toBoard).

/// Exportformat. `folder` = Ordner mit den Originaldateien (Briefing „Features nach dem Prototyp“).
public enum ExportFormat: String, CaseIterable, Sendable {
    case png, pdf, folder

    /// Dateiendung; der Ordner-Export hat keine.
    public var fileExtension: String? {
        switch self {
        case .png: return "png"
        case .pdf: return "pdf"
        case .folder: return nil
        }
    }

    /// Format aus einer Dateiendung (`--export x.pdf`); unbekannt → nil.
    public static func fromExtension(_ ext: String) -> ExportFormat? {
        switch ext.lowercased() {
        case "png": return .png
        case "pdf": return .pdf
        default: return nil
        }
    }
}

/// Exportbereich: nur Inhalt (umschließendes Rechteck aller Bilder + Papierrand) oder die ganze Fläche (Board = Bildschirm).
public enum ExportArea: String, CaseIterable, Sendable {
    case content, full
}

/// Pixelmaß einer Exportseite. `effectiveDPI` < `requestedDPI`, wenn die Obergrenze (16 384 px pro Seite) griff.
public struct ExportPixelPlan: Equatable, Sendable {
    /// Seitengröße in pt (= Exportbereich)
    public let sizePoints: CGSize
    public let requestedDPI: Int
    public let effectiveDPI: Double
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(sizePoints: CGSize, requestedDPI: Int, effectiveDPI: Double, pixelWidth: Int, pixelHeight: Int) {
        self.sizePoints = sizePoints
        self.requestedDPI = requestedDPI
        self.effectiveDPI = effectiveDPI
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Wurde die DPI wegen der Obergrenze abgesenkt?
    public var capped: Bool { effectiveDPI < Double(requestedDPI) - 1e-9 }

    /// Pixel pro pt (nominell, aus der effektiven DPI).
    public var scale: Double { effectiveDPI / ExportMath.pointsPerInch }

    /// Speicher eines RGBA-Bitmap-Kontexts in dieser Größe (4 Byte je Pixel).
    public var bitmapBytes: Int64 { Int64(pixelWidth) * Int64(pixelHeight) * 4 }

    /// Kurzform fürs Log: `300→300 dpi 4167x2917px` bzw. `600→460.8 dpi (gekappt) …`.
    public var describe: String {
        "\(requestedDPI)→\(String(format: "%.1f", effectiveDPI)) dpi\(capped ? " (gekappt)" : "") \(pixelWidth)x\(pixelHeight)px"
    }
}

public enum ExportMath {
    /// Wählbare DPI (Menü), Standard 300 (E12).
    public static let dpiChoices = [72, 150, 300, 600]
    public static let defaultDPI = 300
    public static let defaultFormat: ExportFormat = .png
    public static let defaultArea: ExportArea = .content
    public static let pointsPerInch = 72.0
    /// Obergrenze je Seite (E12). Darüber sinkt die DPI.
    public static let maxPixelsPerSide = 16_384
    /// Papierrand um den Inhalt beim Bereich „nur Inhalt“ (pt). Gleich dem Ablage-Rand (LayoutMetrics.margin).
    public static let paperMargin = 48.0
    /// Obergrenze der Dekodier-Zielgröße je Bild im Export (längste Kante des GANZEN Bildes, Pixel). 8192² × 4 Byte
    /// = 256 MB im schlimmsten Fall (stark beschnittenes, sehr großes Original); ImageIO vergrößert nie über die Quelle.
    public static let maxDecodePixel = 8192

    public static func isValidDPI(_ dpi: Int) -> Bool { dpiChoices.contains(dpi) }

    // MARK: Bereich

    /// Achsenparalleles umschließendes Rechteck eines Items inkl. Rotation und hartem Schatten (Board-Koordinaten).
    /// `shadowOffset` in LOKALEN Item-Koordinaten mit y nach unten (Layer-Wert (2, −2) bei y-oben → (2, 2)).
    /// Der Schattenversatz dreht mit dem Item (Schatten wird im Layer-Raum gezeichnet).
    // ⚠️ VERIFIZIEREN: shadowOffset wirkt im Koordinatensystem des gedrehten Layers (dreht mit). Bei ±2° ist der
    // Unterschied zur ungedrehten Variante < 0,1 pt und liegt ohnehin im Papierrand.
    public static func itemBounds(center: CGPoint, size: CGSize, rotation: Double, shadowOffset: CGSize = .zero) -> CGRect {
        let hw = Double(size.width) / 2, hh = Double(size.height) / 2
        let sx = Double(shadowOffset.width), sy = Double(shadowOffset.height)
        var corners: [CGPoint] = []
        for (x, y) in [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)] {
            corners.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            if sx != 0 || sy != 0 { corners.append(CGPoint(x: CGFloat(x + sx), y: CGFloat(y + sy))) }
        }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for c in corners {
            let b = CropMath.toBoard(c, rotation: rotation)
            let x = Double(center.x + b.x), y = Double(center.y + b.y)
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }

    public static func itemBounds(_ item: BoardItem, shadowOffset: CGSize = .zero) -> CGRect {
        itemBounds(center: item.center.cgPoint, size: item.size.cgSize, rotation: item.rotation, shadowOffset: shadowOffset)
    }

    /// Vereinigung aller Item-Rahmen (inkl. Rotation und Schatten); nil ohne Items.
    public static func contentBounds(_ items: [BoardItem], shadowOffset: CGSize = .zero) -> CGRect? {
        var result: CGRect?
        for item in items {
            let b = itemBounds(item, shadowOffset: shadowOffset)
            guard b.minX.isFinite, b.minY.isFinite, b.width.isFinite, b.height.isFinite else { continue }
            result = result.map { $0.union(b) } ?? b
        }
        return result
    }

    /// Exportbereich in Board-Koordinaten. `.content`: umschließendes Rechteck + `margin`, nach außen auf ganze pt
    /// gerundet. `.full`: die ganze Fläche (0, 0, boardSize). Leeres Board → nil (nichts zu exportieren).
    public static func exportRect(items: [BoardItem], area: ExportArea, boardSize: CGSize, margin: Double = paperMargin,
                                  shadowOffset: CGSize = .zero) -> CGRect? {
        guard let content = contentBounds(items, shadowOffset: shadowOffset) else { return nil }
        switch area {
        case .full:
            guard boardSize.width > 0, boardSize.height > 0 else { return nil }
            return CGRect(origin: .zero, size: boardSize)
        case .content:
            let m = CGFloat(margin)
            let r = content.insetBy(dx: -m, dy: -m)
            let minX = r.minX.rounded(.down), minY = r.minY.rounded(.down)
            let maxX = r.maxX.rounded(.up), maxY = r.maxY.rounded(.up)
            guard maxX > minX, maxY > minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    // MARK: Pixelmaß

    /// Pixelmaß = pt × DPI ÷ 72 (gerundet, mindestens 1). Überschreitet die längere Seite `maxPixels`, sinkt die DPI so,
    /// dass sie genau `maxPixels` hat. nil bei leerer Größe oder DPI ≤ 0.
    public static func pixelPlan(size: CGSize, dpi: Int, maxPixels: Int = maxPixelsPerSide) -> ExportPixelPlan? {
        let w = Double(size.width), h = Double(size.height)
        guard w > 0, h > 0, w.isFinite, h.isFinite, dpi > 0, maxPixels > 0 else { return nil }
        var scale = Double(dpi) / pointsPerInch
        let longest = max(w, h)
        if longest * scale > Double(maxPixels) {
            scale = Double(maxPixels) / longest
        }
        func px(_ v: Double) -> Int { min(maxPixels, max(1, Int((v * scale).rounded()))) }
        return ExportPixelPlan(sizePoints: size, requestedDPI: dpi, effectiveDPI: scale * pointsPerInch,
                               pixelWidth: px(w), pixelHeight: px(h))
    }

    /// Dekodier-Zielgröße (längste Kante in Pixeln) eines Bildes für den Export: das GANZE Bild in voller Größe F
    /// (= Anzeigegröße ÷ Crop-Anteil) × Exportskala (dpi ÷ 72), höchstens `cap`. Gleiche Formel wie am Bildschirm
    /// (CropMath.decodeMaxPixel), nur mit Exportskala und höherer Obergrenze.
    public static func decodeMaxPixel(itemSize: CGSize, crop: BoardCrop?, scale: Double, cap: Int = maxDecodePixel) -> Int {
        CropMath.decodeMaxPixel(displaySize: itemSize, crop: crop, scale: scale, cap: cap)
    }

    /// Item-Mittelpunkt (Board-Koordinaten) → Layer-Position in der Export-Szene (Ursprung unten links des
    /// Exportbereichs, y nach oben).
    public static func layerPosition(center: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: center.x - rect.minX, y: rect.maxY - center.y)
    }

    /// Kantenlänge der Noise-Kachel in Export-Pixeln, damit ein Kachelpixel physisch so groß ist wie am Bildschirm
    /// (dort 1 Kachelpixel = 1 Device-Pixel = 1/screenScale pt): tilePixels × exportScale ÷ screenScale, mindestens 1.
    public static func noiseTilePixels(tilePixels: Int, exportScale: Double, screenScale: Double) -> Int {
        guard tilePixels > 0, exportScale > 0, screenScale > 0 else { return max(1, tilePixels) }
        return max(1, Int((Double(tilePixels) * exportScale / screenScale).rounded()))
    }

    /// PNG pHYs speichert Pixel pro Meter (ganzzahlig): dpi ÷ 0,0254.
    public static func pixelsPerMeter(dpi: Double) -> Int {
        Int((dpi / 0.0254).rounded())
    }

    /// Ungefährer Speicher der dekodierten Bilder (längste Kante² × 4 Byte, obere Schranke), fürs Log vor dem Rendern.
    public static func estimatedDecodeBytes(items: [BoardItem], scale: Double, cap: Int = maxDecodePixel) -> Int64 {
        items.reduce(Int64(0)) { sum, item in
            let px = Int64(decodeMaxPixel(itemSize: item.size.cgSize, crop: item.crop, scale: scale, cap: cap))
            return sum + px * px * 4
        }
    }
}

/// Dateinamen (E12): `Dropboard <yyyy-MM-dd HH.mm.ss>.<ext>`, kollisionsfrei mit Zähler (`… 2.png`, `… 3.png`).
/// Ordner-Export: Ordner `Dropboard <yyyy-MM-dd HH.mm.ss>` mit den Originalen, `board.json` und `index.txt`.
public enum ExportNaming {
    public static let baseName = "Dropboard"
    public static let indexFileName = "index.txt"
    public static let documentFileName = BoardStore.documentFileName
    /// Höchster Zähler, danach eine UUID (praktisch nie erreicht).
    public static let maxCounter = 9999

    /// `yyyy-MM-dd HH.mm.ss` (Punkte statt Doppelpunkte: Finder zeigt „:“ als „/“).
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }

    /// Erster freier Name: `stem.ext`, dann `stem 2.ext`, `stem 3.ext` … (`ext` nil → ohne Endung).
    /// `taken` prüft, ob es den Namen schon gibt (Dateisystem oder eine Menge im Selftest).
    public static func uniqueName(stem: String, ext: String?, taken: (String) -> Bool) -> String {
        func name(_ n: Int) -> String {
            let s = n <= 1 ? stem : "\(stem) \(n)"
            guard let e = ext, !e.isEmpty else { return s }
            return "\(s).\(e)"
        }
        for n in 1...maxCounter where !taken(name(n)) {
            return name(n)
        }
        let fallback = "\(stem) \(UUID().uuidString)"
        return ext.map { "\(fallback).\($0)" } ?? fallback
    }

    /// Exportdatei bzw. Exportordner (`format == .folder`): `Dropboard <Zeitstempel>[.<ext>]`, kollisionsfrei.
    public static func exportName(date: Date, format: ExportFormat, timeZone: TimeZone = .current,
                                  taken: (String) -> Bool) -> String {
        uniqueName(stem: "\(baseName) \(timestamp(date, timeZone: timeZone))", ext: format.fileExtension, taken: taken)
    }

    /// Unerlaubte Zeichen ersetzen („/“ und „:“ → „-“, Steuerzeichen weg), Leerraum trimmen, führenden Punkt
    /// entfernen (keine versteckten Dateien), höchstens 200 Zeichen. Leer → "Bild".
    public static func sanitize(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                out.unicodeScalars.append("-")
            } else if scalar.value < 0x20 || scalar.value == 0x7F {
                continue
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        if out.count > 200 { out = String(out.prefix(200)) }
        return out.isEmpty ? "Bild" : out
    }

    /// Dateiname eines Originals im Export-Ordner, noch ohne Kollisionsprüfung: Herkunft `originalName`, wenn vorhanden,
    /// sonst der gespeicherte Name. Die Endung ist immer die der gespeicherten Datei (deren Inhalt wird kopiert; Bilddaten
    /// aus dem Browser sind z. B. als PNG gespeichert). Rückgabe: (Stamm, Endung).
    public static func originalNameParts(_ item: BoardItem) -> (stem: String, ext: String) {
        let storedExt = (item.fileName as NSString).pathExtension
        let storedStem = (item.fileName as NSString).deletingPathExtension
        guard let raw = item.source?.originalName,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (sanitize(storedStem), storedExt)
        }
        let original = sanitize(raw)
        let originalExt = (original as NSString).pathExtension
        let originalStem = (original as NSString).deletingPathExtension
        if !originalExt.isEmpty, originalExt.lowercased() == storedExt.lowercased(), !originalStem.isEmpty {
            return (originalStem, originalExt)   // Schreibweise des Originals behalten (z. B. .HEIC)
        }
        return (original, storedExt)
    }

    /// Kollisionsfreie Dateinamen für alle Items in Dokument-Reihenfolge. Vergleich ohne Groß-/Kleinschreibung
    /// (APFS ist standardmäßig case-insensitive), `board.json` und `index.txt` sind reserviert.
    public static func originalFileNames(_ items: [BoardItem]) -> [String] {
        var used = Set([documentFileName.lowercased(), indexFileName.lowercased()])
        var names: [String] = []
        for item in items {
            let parts = originalNameParts(item)
            let name = uniqueName(stem: parts.stem, ext: parts.ext.isEmpty ? nil : parts.ext) { used.contains($0.lowercased()) }
            used.insert(name.lowercased())
            names.append(name)
        }
        return names
    }

    /// Inhalt der `index.txt`: Reihenfolge (Stapel, unten → oben), Datei, Herkunft (App, Pfad, URL), Zeitstempel.
    public static func indexText(items: [BoardItem], fileNames: [String], exportedAt: Date,
                                 boardDirectory: String, timeZone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        var lines: [String] = []
        lines.append("Dropboard – Export der Originaldateien")
        lines.append("Exportiert: \(timestamp(exportedAt, timeZone: timeZone))")
        lines.append("Board: \(boardDirectory)")
        lines.append("Bilder: \(items.count) (Reihenfolge = Stapel, 1 liegt unten)")
        lines.append("Layout (Position, Kipp, Beschnitt): \(documentFileName)")
        lines.append("")
        for (i, item) in items.enumerated() {
            let name = i < fileNames.count ? fileNames[i] : item.fileName
            lines.append("\(i + 1). \(name)")
            lines.append("   gespeichert: \(item.fileName)")
            lines.append("   hinzugefügt: \(iso.string(from: item.addedAt))")
            if let s = item.source {
                lines.append("   weg: \(s.route)")
                if let app = s.app { lines.append("   app: \(app)") }
                if let path = s.originalPath { lines.append("   quelle: \(path)") }
                if let url = s.originalURL { lines.append("   url: \(url)") }
                if let original = s.originalName { lines.append("   originalname: \(original)") }
            }
            if item.crop != nil { lines.append("   beschnitt: \(BoardCrop.describe(item.crop))") }
            lines.append(String(format: "   mitte: (%.1f, %.1f) pt  größe: %.1f×%.1f pt  kipp: %.2f°",
                                item.center.x, item.center.y, item.size.width, item.size.height, item.rotation))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
