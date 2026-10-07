import AppKit
import ImageIO
import QuartzCore
import DropboardCore

// Export der Zeichenfläche (E12): Rendern und Schreiben. Reine Logik (Bereich, Pixelmaß, DPI-Kappung, Namen) liegt in
// DropboardCore/Export.swift. Bedienung (Menü, ⌘E, Ordner-Dialog) in ExportController.swift.
//
// Nicht an einen Actor gebunden: `Exporter.run` läuft in der App auf `Exporter.queue` (Hintergrund), im CLI
// (`--export`) und im Selftest synchron auf dem Main Thread. Benutzt nur nicht isolierte Helfer (ImageDecoder,
// PaperArt, PaperStyle, CropStyle, withoutImplicitAnimations, Log).
//
// Look wie am Bildschirm (BoardScene/Snapshot): Papier (paperHex), Noise (PaperStyle.noiseOpacity), Bilder mit hartem
// Schatten (PaperStyle.shadow…), Kipp, Beschnitt per contentsRect. KEINE UI-Layer: kein Eselsohr, keine Auswahl,
// keine Griffe, keine Abdunklung. Die Bilder werden NEU aus den Originaldateien dekodiert, in Ziel-Auflösung.

/// PDF-Variante.
enum ExportPDFMode: String, Sendable {
    /// Standard: die Szene wird wie beim PNG als Bitmap in Ziel-DPI gerendert und als EIN Bild auf die PDF-Seite
    /// (Seitengröße = Exportbereich in pt) gezeichnet. Begründung: identischer, nachweislich funktionierender Weg
    /// (CALayer.render in einen Bitmap-Kontext, wie Snapshot); ob Schatten und contentsRect beim Rendern in einen
    /// PDF-Kontext stimmen, ist unbelegt. Die Bilder liegen damit in der Ziel-DPI im PDF (E12).
    case bitmap
    /// Versuch (nur per `--pdf-layers`): Papier/Noise per CoreGraphics, die Item-Layer per CALayer.render(in:) direkt in
    /// den PDF-Kontext (Bilder als eigene Bildobjekte in Ziel-DPI, kleinere Dateien). Erst Standard, wenn auf dem Mac
    /// bestätigt ist, dass Schatten, Kipp und Beschnitt im PDF stimmen.
    case layers
}

enum ExportConfig {
    static let defaultPDFMode: ExportPDFMode = .bitmap
    /// Ab hier eine WARNUNG im Log (Bitmap-Kontext + dekodierte Bilder, geschätzt).
    static let memoryWarnBytes: Int64 = 1_200_000_000
    /// Darüber wird nicht exportiert (Schutz vor Speicherdruck). 16 384² × 4 B = 1 GiB passt noch.
    static let memoryLimitBytes: Int64 = 3_000_000_000
    static let pdfTitle = "Dropboard"
}

/// Was exportiert wird. Wert-Typ, wandert vom Main Thread auf die Export-Queue.
struct ExportRequest: Sendable {
    var format: ExportFormat
    /// angefragte DPI (Menü: 72/150/300/600; CLI/Selftest: beliebig > 0)
    var dpi: Int
    var area: ExportArea
    /// ganze Fläche = Board-Größe (Bildschirm-Frame) in pt
    var boardSize: CGSize
    /// Backing-Scale des Bildschirms: Referenz für die Körnung der Noise (1 Kachelpixel = 1/screenScale pt)
    var screenScale: Double
    var pdfMode: ExportPDFMode = ExportConfig.defaultPDFMode
    var date = Date()
    /// PDF-Metadatum „Creator“
    var creator = "Dropboard"
}

struct ExportResult: Sendable {
    let url: URL
    let format: ExportFormat
    let area: ExportArea
    /// Exportbereich in Board-Koordinaten (pt); nil beim Ordner-Export
    let rect: CGRect?
    let plan: ExportPixelPlan?
    let pdfMode: ExportPDFMode?
    /// Bilder gezeichnet bzw. kopiert
    let items: Int
    /// Bilddatei fehlte/unlesbar (gezeichnet als Platzhalter bzw. nicht kopiert)
    let missing: Int
    let durationMs: String
    let bytes: Int64

    /// Logzeile [EXPORT]: Format, Bereich in pt, angefragte/effektive DPI, Pixelmaß, Dauer, Dateigröße, Pfad.
    var logLine: String {
        var s = "Export fertig format=\(format.rawValue)"
        if let mode = pdfMode { s += " pdf=\(mode.rawValue)" }
        s += " bereich=\(area.rawValue)"
        if let r = rect {
            s += String(format: " rect=(%.0f,%.0f %.0fx%.0f)pt", r.minX, r.minY, r.width, r.height)
        }
        if let p = plan {
            let effective = String(format: "%.1f", p.effectiveDPI)
            let cappedNote = p.capped ? " (gekappt auf \(ExportMath.maxPixelsPerSide) px)" : ""
            s += " dpi=\(p.requestedDPI)→\(effective)\(cappedNote) pixel=\(p.pixelWidth)x\(p.pixelHeight)"
        }
        s += " bilder=\(items) fehlend=\(missing) dauer=\(durationMs)ms größe=\(bytes)B (\(Exporter.megabytes(bytes)) MB) pfad=\(url.path)"
        return s
    }
}

/// Ergebnis für den Main Actor (Sendable, Fehler als Text).
enum ExportOutcome: Sendable {
    case success(ExportResult)
    case failure(String)
}

struct ExportFailure: Error, CustomStringConvertible, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

enum Exporter {
    /// Seriell, ein Export nach dem anderen (ExportController lässt ohnehin nur einen gleichzeitig zu).
    static let queue = DispatchQueue(label: "Dropboard.export", qos: .userInitiated)

    /// Harter Schatten in lokalen Item-Koordinaten mit y nach unten (Layer-Wert (2, −2) bei y-oben → (2, 2)).
    static var shadowOffsetBoard: CGSize {
        CGSize(width: PaperStyle.shadowOffset.width, height: -PaperStyle.shadowOffset.height)
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    /// Exportbereich für ein Dokument (Board-Koordinaten), inkl. Rotation, Schatten und Papierrand.
    static func exportRect(_ document: BoardDocument, area: ExportArea, boardSize: CGSize) -> CGRect? {
        ExportMath.exportRect(items: document.items, area: area, boardSize: boardSize, shadowOffset: shadowOffsetBoard)
    }

    /// Kollisionsfreies Ziel im Ordner: `Dropboard <Datum Uhrzeit>[ n].<ext>` bzw. Unterordner beim Ordner-Export.
    static func targetURL(in directory: URL, format: ExportFormat, date: Date) -> URL {
        let fm = FileManager.default
        let name = ExportNaming.exportName(date: date, format: format) {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        return directory.appendingPathComponent(name, isDirectory: format == .folder)
    }

    /// Im Hintergrund exportieren; `completion` auf dem Main Actor. Main Thread nur Start/Ende.
    static func exportInBackground(document: BoardDocument, store: BoardStore, request: ExportRequest, to url: URL,
                                   completion: @escaping @MainActor @Sendable (ExportOutcome) -> Void) {
        queue.async {
            let outcome: ExportOutcome
            do {
                outcome = .success(try run(document: document, store: store, request: request, to: url))
            } catch {
                outcome = .failure("\(error)")
            }
            Task { @MainActor in completion(outcome) }
        }
    }

    // MARK: Einstieg (synchron)

    /// Exportiert `document` nach `url` (Datei bzw. Ordner). Wirft bei leerem Board, Speichergrenze, Schreibfehlern.
    static func run(document: BoardDocument, store: BoardStore, request: ExportRequest, to url: URL) throws -> ExportResult {
        let start = Log.now
        guard !document.items.isEmpty else { throw ExportFailure("Board ist leer – nichts zu exportieren") }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if request.format == .folder {
            let r = try exportFolder(document: document, store: store, to: url, date: request.date)
            return ExportResult(url: url, format: .folder, area: request.area, rect: nil, plan: nil, pdfMode: nil,
                                items: r.copied, missing: r.missing, durationMs: Log.ms(since: start), bytes: r.bytes)
        }

        guard let rect = exportRect(document, area: request.area, boardSize: request.boardSize) else {
            throw ExportFailure("kein Exportbereich (Board leer oder Fläche 0)")
        }
        guard let plan = ExportMath.pixelPlan(size: rect.size, dpi: request.dpi) else {
            throw ExportFailure("ungültige DPI \(request.dpi) oder Größe \(rect.size)")
        }
        let usesBitmap = request.format == .png || request.pdfMode == .bitmap
        let bitmapBytes = usesBitmap ? plan.bitmapBytes : 0
        let decodeBytes = ExportMath.estimatedDecodeBytes(items: document.items, scale: plan.scale)
        let total = bitmapBytes + decodeBytes
        var startLine = "Start format=\(request.format.rawValue)"
        if request.format == .pdf { startLine += " pdf=\(request.pdfMode.rawValue)" }
        startLine += " bereich=\(request.area.rawValue)"
        startLine += String(format: " rect=(%.0f,%.0f %.0fx%.0f)pt", rect.minX, rect.minY, rect.width, rect.height)
        startLine += " \(plan.describe) items=\(document.items.count)"
        startLine += " speicher≈\(megabytes(total)) MB (bitmap \(megabytes(bitmapBytes)) MB + bilder ≤\(megabytes(decodeBytes)) MB)"
        let grain = String(format: "%.2f", 1 / max(request.screenScale, 0.01))
        startLine += " noise=1px/\(grain)pt ziel=\(url.path)"
        Log.line("[EXPORT]", startLine)
        if plan.capped {
            let effective = String(format: "%.1f", plan.effectiveDPI)
            let longest = String(format: "%.0f", max(rect.width, rect.height))
            Log.line("[EXPORT]", "DPI abgesenkt: angefragt \(plan.requestedDPI) → effektiv \(effective) "
                + "(Obergrenze \(ExportMath.maxPixelsPerSide) px pro Seite, längere Seite \(longest) pt)")
        }
        if total > ExportConfig.memoryLimitBytes {
            throw ExportFailure("Speicherbedarf ≈\(megabytes(total)) MB über der Grenze \(megabytes(ExportConfig.memoryLimitBytes)) MB – "
                + "kleinere DPI oder Bereich „Nur Inhalt“ wählen")
        }
        if total > ExportConfig.memoryWarnBytes {
            Log.line("[EXPORT]", "WARNUNG großer Export: ≈\(megabytes(total)) MB Arbeitsspeicher")
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tmp) }
        let stats: SceneStats
        switch request.format {
        case .png:
            let rendered = try renderBitmap(document: document, store: store, rect: rect, plan: plan,
                                            screenScale: request.screenScale)
            stats = rendered.stats
            try writePNG(rendered.image, dpi: plan.effectiveDPI, to: tmp)
        case .pdf:
            if request.pdfMode == .bitmap {
                let rendered = try renderBitmap(document: document, store: store, rect: rect, plan: plan,
                                                screenScale: request.screenScale)
                stats = rendered.stats
                try writePDF(pageSize: rect.size, title: ExportConfig.pdfTitle, creator: request.creator, to: tmp) { ctx in
                    ctx.interpolationQuality = .high
                    ctx.draw(rendered.image, in: CGRect(origin: .zero, size: rect.size))
                }
            } else {
                var layerStats = SceneStats(drawn: 0, missing: 0)
                try writePDF(pageSize: rect.size, title: ExportConfig.pdfTitle, creator: request.creator, to: tmp) { ctx in
                    let page = CGRect(origin: .zero, size: rect.size)
                    // Noise in pt: Originalkachel, 1 Kachelpixel = 1/screenScale pt (wie am Bildschirm).
                    let tile = PaperArt.loadNoiseTile()
                    let s = CGFloat(max(request.screenScale, 0.01))
                    let tileRect = tile.map { CGRect(x: 0, y: 0, width: CGFloat($0.width) / s, height: CGFloat($0.height) / s) } ?? .zero
                    drawPaper(ctx, in: page, noiseTile: tile, tileRect: tileRect)
                    let scene = buildItemLayers(document: document, store: store, rect: rect, scale: plan.scale)
                    layerStats = scene.stats
                    // ⚠️ VERIFIZIEREN: CALayer.render(in:) in einen PDF-Kontext – harter Schatten (shadowPath),
                    // Rotation und contentsRect (Beschnitt) im PDF wie im PNG? Deshalb nicht Standard.
                    scene.root.render(in: ctx)
                }
                stats = layerStats
            }
        case .folder:
            throw ExportFailure("unerreichbar")
        }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }   // nur CLI mit festem Pfad; App-Namen sind frei
        try fm.moveItem(at: tmp, to: url)
        let bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return ExportResult(url: url, format: request.format, area: request.area, rect: rect, plan: plan,
                            pdfMode: request.format == .pdf ? request.pdfMode : nil, items: stats.drawn,
                            missing: stats.missing, durationMs: Log.ms(since: start), bytes: bytes)
    }

    // MARK: Szene

    struct SceneStats {
        var drawn: Int
        var missing: Int
    }

    struct ItemScene {
        let root: CALayer
        let stats: SceneStats
    }

    /// Item-Layer wie BoardScene.makeItemLayer: harter Schatten (Radius 0, expliziter Pfad), Kantenglättung, Kipp,
    /// Beschnitt per contentsRect. Root = Exportbereich (Ursprung unten links, y nach oben), transparent.
    /// Bilder NEU aus den Originalen dekodiert: ganzes Bild in voller Größe F × Exportskala (ExportMath.decodeMaxPixel,
    /// höchstens ExportMath.maxDecodePixel; ImageIO vergrößert nie über die Quelle, der Layer skaliert dann).
    // ⚠️ VERIFIZIEREN: CALayer anlegen/ändern und render(in:) auf einer Hintergrund-Queue (Core Animation ist laut Doku
    // thread-sicher; explizite Transaktion per withoutImplicitAnimations, kein Run-Loop nötig, weil render(in:) den
    // Model-Baum zeichnet). Log `[EXPORT] Export fertig` mit plausiblen Bildern = belegt.
    static func buildItemLayers(document: BoardDocument, store: BoardStore, rect: CGRect, scale: Double) -> ItemScene {
        // Erst dekodieren (lang), dann Layer in einer kurzen Transaktion bauen.
        var decoded: [(BoardItem, DecodedImage?)] = []
        for item in document.items {
            let url = store.imageURL(fileName: item.fileName)
            let image = ImageDecoder.decode(url: url, size: item.size.cgSize, crop: item.crop, scale: CGFloat(scale),
                                            cap: ExportMath.maxDecodePixel)
            if image == nil {
                Log.line("[EXPORT]", "Bild fehlt/unlesbar \(item.fileName) → Platzhalter")
            }
            decoded.append((item, image))
        }
        let root = CALayer()
        var stats = SceneStats(drawn: 0, missing: 0)
        withoutImplicitAnimations {
            root.frame = CGRect(origin: .zero, size: rect.size)
            root.contentsScale = CGFloat(scale)
            for (item, image) in decoded {
                let layer = CALayer()
                layer.contentsScale = CGFloat(scale)
                layer.allowsEdgeAntialiasing = true
                layer.shadowColor = PaperStyle.cgColor(PaperStyle.graphiteHex)
                layer.shadowOpacity = PaperStyle.shadowOpacity
                layer.shadowRadius = PaperStyle.shadowRadius
                layer.shadowOffset = PaperStyle.shadowOffset
                if let image = image {
                    layer.bounds = CGRect(origin: .zero, size: image.size)
                    layer.contents = image.cgImage
                    layer.contentsRect = CropMath.contentsRect(item.crop, originTop: CropStyle.contentsRectOriginTop)
                    stats.drawn += 1
                } else {
                    layer.bounds = CGRect(origin: .zero, size: item.size.cgSize)
                    layer.backgroundColor = PaperStyle.cgColor(PaperStyle.placeholderHex)
                    stats.missing += 1
                }
                layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)
                layer.position = ExportMath.layerPosition(center: item.center.cgPoint, in: rect)
                // wie StopMotion.transform(for:) mit Scale 1: Grad, positiv = gegen den Uhrzeigersinn
                layer.transform = CATransform3DMakeRotation(CGFloat(item.rotation * Double.pi / 180), 0, 0, 1)
                root.addSublayer(layer)
            }
        }
        return ItemScene(root: root, stats: stats)
    }

    /// Szene als Bitmap in Ziel-Pixelgröße (sRGB, ohne Alpha): Papier + Noise im Pixelraum, dann die Item-Layer per
    /// CALayer.render(in:) mit scaleBy(px/pt) (wie Snapshot.renderPNG).
    // ⚠️ VERIFIZIEREN: CGImageAlphaInfo.noneSkipLast (RGBX, deckend) als Ziel von CALayer.render(in:) – Snapshot nutzt
    // premultipliedLast. Ohne Alpha wird das PNG kleiner (RGB). Selftest `export render: …` liest Farben zurück.
    static func renderBitmap(document: BoardDocument, store: BoardStore, rect: CGRect, plan: ExportPixelPlan,
                             screenScale: Double) throws -> (image: CGImage, stats: SceneStats) {
        let pw = plan.pixelWidth, ph = plan.pixelHeight
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExportFailure("Bitmap-Kontext \(pw)x\(ph) nicht anlegbar (Speicher?)") }
        let pixelRect = CGRect(x: 0, y: 0, width: pw, height: ph)
        let tile = PaperArt.loadNoiseTile().flatMap { scaledNoiseTile($0, exportScale: plan.scale, screenScale: screenScale) }
        drawPaper(ctx, in: pixelRect, noiseTile: tile,
                  tileRect: tile.map { CGRect(x: 0, y: 0, width: $0.width, height: $0.height) } ?? .zero)
        let sx = CGFloat(pw) / rect.width, sy = CGFloat(ph) / rect.height
        let scene = buildItemLayers(document: document, store: store, rect: rect, scale: Double(max(sx, sy)))
        ctx.saveGState()
        ctx.scaleBy(x: sx, y: sy)
        scene.root.render(in: ctx)
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { throw ExportFailure("Bitmap → Bild fehlgeschlagen") }
        return (image, scene.stats)
    }

    /// Flaches Papier + Noise (Deckkraft PaperStyle.noiseOpacity), gekachelt ab dem Ursprung. Keine Vignette, kein Verlauf.
    static func drawPaper(_ ctx: CGContext, in rect: CGRect, noiseTile: CGImage?, tileRect: CGRect) {
        ctx.setFillColor(PaperStyle.cgColor(PaperStyle.paperHex))
        ctx.fill(rect)
        guard let tile = noiseTile, tileRect.width > 0, tileRect.height > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setAlpha(CGFloat(PaperStyle.noiseOpacity))
        ctx.draw(tile, in: tileRect, byTiling: true)   // wie PaperArt (aus Spike board-paper)
        ctx.restoreGState()
    }

    /// Noise-Kachel in Exportskala: ein Kachelpixel ist physisch so groß wie am Bildschirm (1 Device-Pixel =
    /// 1/screenScale pt), also tile × exportScale ÷ screenScale Pixel. Vergrößern ohne Interpolation (Körnung bleibt
    /// hart wie am Bildschirm), Verkleinern mit Interpolation (Körnung feiner als ein Pixel → gemittelt).
    static func scaledNoiseTile(_ tile: CGImage, exportScale: Double, screenScale: Double) -> CGImage? {
        let w = ExportMath.noiseTilePixels(tilePixels: tile.width, exportScale: exportScale, screenScale: screenScale)
        let h = ExportMath.noiseTilePixels(tilePixels: tile.height, exportScale: exportScale, screenScale: screenScale)
        if w == tile.width && h == tile.height { return tile }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = w >= tile.width ? .none : .high
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Schreiben

    /// PNG mit DPI-Metadaten.
    // ⚠️ VERIFIZIEREN: ImageIO schreibt aus kCGImagePropertyDPIWidth/Height den PNG-Chunk pHYs (Pixel pro Meter,
    // ganzzahlig → 144 dpi wird 5669 px/m ≈ 143.99 dpi). Der Selftest liest DPIWidth/Height zurück. Falls dort FAIL:
    // zusätzlich kCGImagePropertyPNGDictionary mit kCGImagePropertyPNGXPixelsPerMeter/YPixelsPerMeter
    // (ExportMath.pixelsPerMeter) setzen – diese Konstanten sind hier bewusst nicht verwendet, weil ihre Verfügbarkeit
    // im SDK nicht belegt ist.
    static func writePNG(_ image: CGImage, dpi: Double, to url: URL) throws {
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ExportFailure("PNG-Ziel nicht anlegbar \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportFailure("PNG schreiben fehlgeschlagen \(url.path)") }
    }

    /// Eine PDF-Seite, Seitengröße in pt, Metadaten Titel/Creator.
    // ⚠️ VERIFIZIEREN: CGContext(_ url: CFURL, mediaBox: UnsafePointer<CGRect>?, _ auxiliaryInfo: CFDictionary?),
    // beginPDFPage(_:)/endPDFPage()/closePDF() und kCGPDFContextTitle/kCGPDFContextCreator (CoreGraphics, kein Spike).
    static func writePDF(pageSize: CGSize, title: String, creator: String, to url: URL, draw: (CGContext) -> Void) throws {
        var box = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextCreator: creator,
        ]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ExportFailure("PDF-Kontext nicht anlegbar \(url.path)")
        }
        ctx.beginPDFPage(nil)
        draw(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: Ordner mit Originaldateien

    /// Unterordner mit Kopien der Originale (Namen aus `source.originalName`, sonst gespeicherter Name, kollisionsfrei),
    /// `board.json` (Stand des übergebenen Dokuments, gleich kodiert wie BoardStore.save) und `index.txt`.
    static func exportFolder(document: BoardDocument, store: BoardStore, to folder: URL, date: Date) throws
        -> (copied: Int, missing: Int, bytes: Int64) {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ExportNaming.originalFileNames(document.items)
        var copied = 0, missing = 0
        var bytes: Int64 = 0
        func size(_ url: URL) -> Int64 {
            ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        for (item, name) in zip(document.items, names) {
            let source = store.imageURL(fileName: item.fileName)
            let target = folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else {
                Log.line("[EXPORT]", "Original fehlt \(item.fileName) → nicht kopiert")
                missing += 1
                continue
            }
            try fm.copyItem(at: source, to: target)   // APFS: Klon, schnell
            bytes += size(target)
            copied += 1
        }
        let json = folder.appendingPathComponent(ExportNaming.documentFileName)
        try BoardStore.makeEncoder().encode(document).write(to: json, options: .atomic)
        bytes += size(json)
        let index = folder.appendingPathComponent(ExportNaming.indexFileName)
        let text = ExportNaming.indexText(items: document.items, fileNames: names, exportedAt: date,
                                          boardDirectory: store.boardDirectory.path)
        try Data(text.utf8).write(to: index, options: .atomic)
        bytes += size(index)
        return (copied, missing, bytes)
    }
}

/// `--export <pfad> [--format png|pdf|folder] [--dpi N] [--area content|full] [--board-dir …] [--snapshot-demo]
/// [--pdf-layers]`: ohne Fenster exportieren (wie Snapshot), dann Ende (Exit 0/1).
/// Pfad = vorhandener Ordner → automatischer Name darin (`Dropboard <Datum Uhrzeit>.<ext>`); sonst genau dieser Pfad
/// (eine vorhandene Datei wird ersetzt). Format ohne `--format` aus der Endung (.pdf/.png), sonst PNG.
/// `--snapshot-demo`: temporäres Demo-Board (wie Snapshot, inkl. beschnittenem Bild), danach gelöscht.
@MainActor
enum ExportCLI {
    static func run(_ options: LaunchOptions) -> Bool {
        guard let path = options.exportPath else { return false }
        let screen = ScreenGeometry.primaryScreen()
        let boardSize = screen?.frame.size ?? CGSize(width: 1512, height: 982)
        let screenScale = Double(screen?.backingScaleFactor ?? 2)
        let metrics = LayoutMetrics.standard
        let area = screen.map { ScreenGeometry.usableArea($0, metrics: metrics) }
            ?? CGRect(origin: .zero, size: boardSize).insetBy(dx: CGFloat(metrics.margin), dy: CGFloat(metrics.margin))

        var tempDir: URL?
        let store: BoardStore
        if options.snapshotDemo {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dropboard-export-\(UUID().uuidString)", isDirectory: true)
            tempDir = dir
            store = BoardStore(boardDirectory: dir)
        } else {
            store = BoardStore(boardDirectory: options.boardDirectory ?? BoardStore.defaultBoardDirectory())
        }
        defer {
            if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        }
        do {
            if options.snapshotDemo {
                try Snapshot.populateDemo(store, area: area, metrics: metrics)
            }
            let document = try store.load()
            let target = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            let isDirectory = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) && isDir.boolValue
            let format = options.exportFormat ?? ExportFormat.fromExtension(target.pathExtension) ?? ExportMath.defaultFormat
            let date = Date()
            let url = isDirectory ? Exporter.targetURL(in: target, format: format, date: date) : target
            let request = ExportRequest(format: format, dpi: options.exportDPI ?? ExportMath.defaultDPI,
                                        area: options.exportArea ?? ExportMath.defaultArea, boardSize: boardSize,
                                        screenScale: screenScale, pdfMode: options.pdfLayers ? .layers : ExportConfig.defaultPDFMode,
                                        date: date, creator: "Dropboard \(StatusMenuController.versionText)")
            Log.line("[EXPORT]", "CLI items=\(document.items.count) board=\(store.boardDirectory.path) "
                + "fläche=\(Int(boardSize.width))x\(Int(boardSize.height))pt screenScale=\(screenScale)")
            let result = try Exporter.run(document: document, store: store, request: request, to: url)
            Log.line("[EXPORT]", result.logLine)
            return true
        } catch {
            Log.line("[EXPORT]", "CLI FEHLER: \(error)")
            return false
        }
    }
}
