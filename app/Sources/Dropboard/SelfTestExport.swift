import AppKit
import ImageIO
import DropboardCore

/// Export (E12): Bereichsberechnung (Rotation, Schatten, Rand), Pixelmaß/DPI-Kappung, Dateinamen (Zeitstempel,
/// Kollision, Originalnamen), Dekodier-Zielgröße mit Crop, Noise-Körnung, Settings-Roundtrip, Startargumente, ⌘E-Erkennung
/// und ein Mini-Render: kleines Board als PNG (144 dpi) und PDF in einen temporären Ordner exportieren und zurücklesen
/// (Pixelmaß, DPI-Property, Farben, Schatten, Seitengröße), dazu der Ordner-Export. Eingetragen in SelfTest.run.
enum ExportSelfTest {
    static let suiteName = "dropboard.selftest.export"

    static func run(_ t: SelfTestChecker) {
        area(t)
        pixels(t)
        naming(t)
        settingsAndOptions(t)
        render(t)
        shadowWidth(t)
    }

    // MARK: Hilfen

    private static func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }
    private static func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-9) -> Bool { abs(a - b) <= eps }
    private static func near(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-6) -> Bool {
        abs(a.minX - b.minX) <= eps && abs(a.minY - b.minY) <= eps
            && abs(a.width - b.width) <= eps && abs(a.height - b.height) <= eps
    }

    private static func item(_ center: CGPoint, _ size: CGSize, rotation: Double = 0, fileName: String = "x.png",
                             source: ItemSource? = nil, crop: BoardCrop? = nil) -> BoardItem {
        BoardItem(id: UUID(), fileName: fileName, center: BoardPoint(center), rotation: rotation, size: BoardSize(size),
                  addedAt: Date(timeIntervalSince1970: 0), source: source, crop: crop)
    }

    // MARK: 1 – Bereich

    private static func area(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("export area: " + name, ok) }
        let c = CGPoint(x: 100, y: 100), s = CGSize(width: 40, height: 20)
        check("ohne Kipp und Schatten = Rahmen (80,90 40×20)",
              near(ExportMath.itemBounds(center: c, size: s, rotation: 0), CGRect(x: 80, y: 90, width: 40, height: 20)))
        check("90° tauscht Breite und Höhe (90,80 20×40)",
              near(ExportMath.itemBounds(center: c, size: s, rotation: 90), CGRect(x: 90, y: 80, width: 20, height: 40)))
        let r30 = ExportMath.itemBounds(center: c, size: s, rotation: 30)
        let r30Size = abs(Double(r30.width) - 44.641016151377546) < 1e-6 && abs(Double(r30.height) - 37.32050807568877) < 1e-6
        let r30Mid = abs(Double(r30.midX) - 100) < 1e-9 && abs(Double(r30.midY) - 100) < 1e-9
        check("30°: umschließend 44,64×37,32 pt, Mitte bleibt", r30Size && r30Mid)
        check("harter Schatten (2, 2) verlängert nach rechts unten (80,90 42×22)",
              near(ExportMath.itemBounds(center: c, size: s, rotation: 0, shadowOffset: CGSize(width: 2, height: 2)),
                   CGRect(x: 80, y: 90, width: 42, height: 22)))
        let tilted = ExportMath.itemBounds(center: c, size: s, rotation: -1.5, shadowOffset: CGSize(width: 2, height: 2))
        let tiltedNoShadow = ExportMath.itemBounds(center: c, size: s, rotation: -1.5)
        let reachesX = Double(tilted.maxX) > Double(tiltedNoShadow.maxX) + 1.9
        let reachesY = Double(tilted.maxY) > Double(tiltedNoShadow.maxY) + 1.9
        check("Kipp + Schatten umfasst den gekippten Rahmen und reicht weiter nach rechts unten",
              tilted.contains(tiltedNoShadow) && reachesX && reachesY)
        check("Schatten der App: Layer (2, −2) y-oben → lokal (2, 2) y-unten",
              Exporter.shadowOffsetBoard == CGSize(width: 2, height: 2) && PaperStyle.shadowOffset == CGSize(width: 2, height: -2))

        let a = item(CGPoint(x: 100, y: 100), CGSize(width: 40, height: 20))
        let b = item(CGPoint(x: 300, y: 200), CGSize(width: 20, height: 20))
        check("Inhalt = Vereinigung (80,90 230×120)",
              ExportMath.contentBounds([a, b]).map { near($0, CGRect(x: 80, y: 90, width: 230, height: 120)) } == true)
        check("leer: kein Inhalt", ExportMath.contentBounds([]) == nil)
        let board = CGSize(width: 1512, height: 982)
        check("nur Inhalt: + 48 pt Papierrand (32,42 326×216)",
              ExportMath.exportRect(items: [a, b], area: .content, boardSize: board)
                .map { near($0, CGRect(x: 32, y: 42, width: 326, height: 216)) } == true)
        check("Papierrand = 48 pt (wie Ablage-Rand)", ExportMath.paperMargin == 48 && LayoutMetrics.standard.margin == 48)
        let odd = item(CGPoint(x: 100.25, y: 100.5), CGSize(width: 40, height: 20))
        check("nur Inhalt: nach außen auf ganze pt gerundet (32,42 137×117)",
              ExportMath.exportRect(items: [odd], area: .content, boardSize: board)
                .map { near($0, CGRect(x: 32, y: 42, width: 137, height: 117)) } == true)
        check("ganze Fläche = Board (0,0 1512×982)",
              ExportMath.exportRect(items: [a], area: .full, boardSize: board)
                .map { near($0, CGRect(x: 0, y: 0, width: 1512, height: 982)) } == true)
        check("leeres Board: kein Bereich (beide Varianten)",
              ExportMath.exportRect(items: [], area: .content, boardSize: board) == nil
                && ExportMath.exportRect(items: [], area: .full, boardSize: board) == nil)
        check("Layer-Position: Board (100,100) im Bereich (32,42 326×216) → (68,158) y-oben",
              ExportMath.layerPosition(center: CGPoint(x: 100, y: 100), in: CGRect(x: 32, y: 42, width: 326, height: 216))
                == CGPoint(x: 68, y: 158))
    }

    // MARK: 2 – Pixelmaß, DPI-Kappung, Dekodier-Zielgröße, Noise

    private static func pixels(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("export pixel: " + name, ok) }
        check("DPI-Auswahl 72/150/300/600, Standard 300, Obergrenze 16384 px",
              ExportMath.dpiChoices == [72, 150, 300, 600] && ExportMath.defaultDPI == 300 && ExportMath.maxPixelsPerSide == 16_384)
        let p300 = ExportMath.pixelPlan(size: CGSize(width: 100, height: 50), dpi: 300)
        var p300OK = false
        if let p = p300 {
            p300OK = p.pixelWidth == 417 && p.pixelHeight == 208 && !p.capped && abs(p.effectiveDPI - 300) < 1e-9
        }
        check("100×50 pt @300 dpi → 417×208 px (pt × dpi ÷ 72, gerundet), nicht gekappt", p300OK)
        check("Bitmap-Speicher 417 × 208 × 4 B", p300?.bitmapBytes == Int64(417 * 208 * 4))
        let p72 = ExportMath.pixelPlan(size: CGSize(width: 100, height: 50), dpi: 72)
        check("@72 dpi: 1 px = 1 pt", p72?.pixelWidth == 100 && p72?.pixelHeight == 50 && p72?.scale == 1)
        let big = ExportMath.pixelPlan(size: CGSize(width: 4000, height: 2000), dpi: 600)
        var bigOK = false
        if let p = big {
            let size = p.pixelWidth == 16_384 && p.pixelHeight == 8192
            bigOK = p.capped && size && abs(p.effectiveDPI - 294.912) < 1e-9 && p.requestedDPI == 600
        }
        check("4000×2000 pt @600 dpi → gekappt auf 16384×8192 px, effektiv 294,912 dpi", bigOK)
        let full5k = ExportMath.pixelPlan(size: CGSize(width: 2560, height: 1440), dpi: 600)
        var fullOK = false
        if let p = full5k {
            fullOK = p.capped && p.pixelWidth == 16_384 && p.pixelHeight == 9216 && abs(p.effectiveDPI - 460.8) < 1e-9
        }
        check("ganze Fläche 2560×1440 pt @600 → 16384×9216 px, effektiv 460,8 dpi", fullOK)
        check("Log-Kurzform nennt angefragt→effektiv und gekappt",
              full5k?.describe == "600→460.8 dpi (gekappt) 16384x9216px")
        check("ungültig: DPI 0 oder Größe 0 → nil",
              ExportMath.pixelPlan(size: CGSize(width: 100, height: 50), dpi: 0) == nil
                && ExportMath.pixelPlan(size: .zero, dpi: 300) == nil)

        let crop = BoardCrop(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        let visible = CGSize(width: 132, height: 88.2)   // F = 220×147 pt
        check("Dekodier-Ziel mit Crop @300 dpi: ganzes Bild F 220 pt × 300/72 → 917 px",
              ExportMath.decodeMaxPixel(itemSize: visible, crop: crop, scale: 300.0 / 72) == 917)
        check("Dekodier-Ziel mit Crop @144 dpi → 440 px", ExportMath.decodeMaxPixel(itemSize: visible, crop: crop, scale: 2) == 440)
        check("Dekodier-Ziel ohne Crop @300 dpi: 132 pt → 550 px",
              ExportMath.decodeMaxPixel(itemSize: visible, crop: nil, scale: 300.0 / 72) == 550)
        check("Dekodier-Ziel: Obergrenze 8192 px (starker Beschnitt, 600 dpi)",
              ExportMath.decodeMaxPixel(itemSize: CGSize(width: 100, height: 100), crop: BoardCrop(x: 0, y: 0, width: 0.02, height: 0.02),
                                        scale: 600.0 / 72) == ExportMath.maxDecodePixel && ExportMath.maxDecodePixel == 8192)

        check("Noise-Kachel 256 px: 300 dpi bei Bildschirm 2x → 533 px, 72 dpi → 128 px, 144 dpi → 256 px",
              ExportMath.noiseTilePixels(tilePixels: 256, exportScale: 300.0 / 72, screenScale: 2) == 533
                && ExportMath.noiseTilePixels(tilePixels: 256, exportScale: 1, screenScale: 2) == 128
                && ExportMath.noiseTilePixels(tilePixels: 256, exportScale: 2, screenScale: 2) == 256)
        if let tile = PaperArt.loadNoiseTile() {
            let scaled = Exporter.scaledNoiseTile(tile, exportScale: 300.0 / 72, screenScale: 2)
            let same = Exporter.scaledNoiseTile(tile, exportScale: 2, screenScale: 2)
            check("Noise-Kachel skaliert (\(tile.width) px → \(scaled?.width ?? -1) px @300 dpi; @144 dpi unverändert)",
                  scaled?.width == ExportMath.noiseTilePixels(tilePixels: tile.width, exportScale: 300.0 / 72, screenScale: 2)
                    && same?.width == tile.width)
        } else {
            check("Noise-Kachel nicht gefunden (ResourceLocator) – Export dann ohne Noise, Skalierung nicht geprüft", true)
        }
        check("pHYs: 144 dpi → 5669 px/m, 300 → 11811, 72 → 2835",
              ExportMath.pixelsPerMeter(dpi: 144) == 5669 && ExportMath.pixelsPerMeter(dpi: 300) == 11811
                && ExportMath.pixelsPerMeter(dpi: 72) == 2835)
    }

    // MARK: 3 – Namen

    private static func naming(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("export name: " + name, ok) }
        guard let utc = TimeZone(identifier: "UTC") else { check("Zeitzone UTC", false); return }
        let d = Date(timeIntervalSince1970: 1_791_380_709)   // 2026-10-07 13:45:09 UTC
        check("Zeitstempel yyyy-MM-dd HH.mm.ss", ExportNaming.timestamp(d, timeZone: utc) == "2026-10-07 13.45.09"
              && ExportNaming.timestamp(Date(timeIntervalSince1970: 0), timeZone: utc) == "1970-01-01 00.00.00")
        let png = ExportNaming.exportName(date: d, format: .png, timeZone: utc) { _ in false }
        check("PNG frei: „Dropboard 2026-10-07 13.45.09.png“", png == "Dropboard 2026-10-07 13.45.09.png")
        let taken: Set<String> = ["Dropboard 2026-10-07 13.45.09.png", "Dropboard 2026-10-07 13.45.09 2.png"]
        check("Kollision → Zähler „… 3.png“",
              ExportNaming.exportName(date: d, format: .png, timeZone: utc) { taken.contains($0) }
                == "Dropboard 2026-10-07 13.45.09 3.png")
        check("PDF-Endung", ExportNaming.exportName(date: d, format: .pdf, timeZone: utc) { _ in false }
              == "Dropboard 2026-10-07 13.45.09.pdf")
        check("Ordner ohne Endung, Kollision „… 2“",
              ExportNaming.exportName(date: d, format: .folder, timeZone: utc) { $0 == "Dropboard 2026-10-07 13.45.09" }
                == "Dropboard 2026-10-07 13.45.09 2")
        check("Format aus Endung: .PDF → pdf, .png → png, .jpg → nil",
              ExportFormat.fromExtension("PDF") == ExportFormat.pdf && ExportFormat.fromExtension("png") == ExportFormat.png
                && ExportFormat.fromExtension("jpg") == nil)
        check("sanitize: „/“ und „:“ → „-“, führender Punkt weg, leer → Bild",
              ExportNaming.sanitize("a/b:c.png") == "a-b-c.png" && ExportNaming.sanitize(".versteckt") == "versteckt"
                && ExportNaming.sanitize("  ") == "Bild")

        func src(_ name: String?, url: String? = nil) -> ItemSource {
            ItemSource(route: "fileURL", originalPath: nil, originalName: name, app: "com.apple.finder", originalURL: url)
        }
        let p = CGPoint(x: 10, y: 10), s = CGSize(width: 10, height: 10)
        let items = [
            item(p, s, fileName: "U1.png", source: src("Foto.png")),
            item(p, s, fileName: "U2.png", source: src("foto.PNG")),
            item(p, s, fileName: "U3.heic", source: src("IMG_1.HEIC")),
            item(p, s, fileName: "U4.png", source: src("bild.tiff")),
            item(p, s, fileName: "U5.jpg"),
            item(p, s, fileName: "U6.txt", source: src("index.txt")),
            item(p, s, fileName: "U7.png", source: src("a/b.png")),
            item(p, s, fileName: "U8.png", source: src("ohneendung", url: "https://example.invalid/bild.png")),
        ]
        let names = ExportNaming.originalFileNames(items)
        check("Originalnamen: Herkunft, Kollision ohne Groß/klein, Endung der gespeicherten Datei, reserviert, bereinigt",
              names == ["Foto.png", "foto 2.PNG", "IMG_1.HEIC", "bild.tiff.png", "U5.jpg", "index 2.txt", "a-b.png", "ohneendung.png"])
        let text = ExportNaming.indexText(items: items, fileNames: names, exportedAt: d, boardDirectory: "/tmp/board", timeZone: utc)
        check("index.txt: Reihenfolge, Name, Herkunft-URL, App, Zeitstempel",
              text.contains("1. Foto.png") && text.contains("8. ohneendung.png") && text.contains("url: https://example.invalid/bild.png")
                && text.contains("app: com.apple.finder") && text.contains("Exportiert: 2026-10-07 13.45.09")
                && text.contains("hinzugefügt: 1970-01-01T00:00:00Z"))
    }

    // MARK: 4 – Settings, Startargumente, ⌘E

    private static func settingsAndOptions(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("export settings: " + name, ok) }
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let fresh = Settings(defaults: defaults)
            check("Standard: PNG, 300 dpi, nur Inhalt, Schreibtisch",
                  fresh.exportFormat == ExportFormat.png && fresh.exportDPI == 300 && fresh.exportArea == ExportArea.content
                    && fresh.exportFolder == nil)
            check("Keys mit Präfix, Schritt-8-Keys unverändert (3)",
                  Settings.Key.export.allSatisfy { $0.hasPrefix(Settings.Key.prefix) } && Settings.Key.all.count == 3)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("dropboard-selftest-exportdir-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            fresh.exportFormat = .pdf
            fresh.exportDPI = 600
            fresh.exportArea = .full
            fresh.exportFolder = folder
            let reread = Settings(defaults: defaults)
            let rereadPath = reread.exportFolder?.standardizedFileURL.resolvingSymlinksInPath().path
            let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
            let values = reread.exportFormat == ExportFormat.pdf && reread.exportDPI == 600 && reread.exportArea == ExportArea.full
            check("Roundtrip: PDF, 600 dpi, ganze Fläche, eigener Ordner", values && rereadPath == folderPath)
            fresh.exportDPI = 123
            check("Setter mit ungültiger DPI speichert 300", defaults.integer(forKey: Settings.Key.exportDPI) == 300)
            defaults.set("gif", forKey: Settings.Key.exportFormat)
            defaults.set(144, forKey: Settings.Key.exportDPI)
            defaults.set("rand", forKey: Settings.Key.exportArea)
            let invalid = Settings(defaults: defaults)
            check("ungültige gespeicherte Werte → Standard", invalid.exportFormat == ExportFormat.png && invalid.exportDPI == 300
                  && invalid.exportArea == ExportArea.content)
            fresh.exportFolder = nil
            check("Ordner zurück auf Schreibtisch löscht Pfad und Bookmark",
                  defaults.object(forKey: Settings.Key.exportFolderPath) == nil
                    && defaults.object(forKey: Settings.Key.exportFolderBookmark) == nil && Settings(defaults: defaults).exportFolder == nil)
        } else {
            check("UserDefaults(suiteName: \(suiteName)) verfügbar", false)
        }
        check("Schreibtisch-Ordner endet auf Desktop", Settings.desktopDirectory.lastPathComponent == "Desktop")

        let o = try? LaunchOptions.parse(["Dropboard", "--export", "/tmp/x", "--format", "pdf", "--dpi", "144", "--area", "full",
                                          "--snapshot-demo", "--pdf-layers"])
        var parsedOK = false
        if let o = o {
            let values = o.exportPath == "/tmp/x" && o.exportFormat == ExportFormat.pdf && o.exportDPI == 144
            let flags = o.exportArea == ExportArea.full && o.snapshotDemo && o.pdfLayers && o.snapshotPath == nil
            parsedOK = values && flags
        }
        check("--export mit --format/--dpi/--area/--snapshot-demo/--pdf-layers", parsedOK)
        func fails(_ args: [String]) -> Bool { (try? LaunchOptions.parse(["Dropboard"] + args)) == nil }
        check("ungültig: --dpi 0, --format gif, --area rand, --dpi ohne --export, --snapshot + --export, --snapshot-demo allein",
              fails(["--export", "/tmp/x", "--dpi", "0"]) && fails(["--export", "/tmp/x", "--format", "gif"])
                && fails(["--export", "/tmp/x", "--area", "rand"]) && fails(["--dpi", "300"])
                && fails(["--snapshot", "/tmp/a.png", "--export", "/tmp/b"]) && fails(["--snapshot-demo"]))
        check("--snapshot mit --snapshot-demo bleibt gültig",
              (try? LaunchOptions.parse(["Dropboard", "--snapshot", "/tmp/a.png", "--snapshot-demo"]))?.snapshotDemo == true)

        // ⚠️ VERIFIZIEREN (Muster aus SelfTestCrop): MainActor.assumeIsolated aus dem synchronen Selftest.
        MainActor.assumeIsolated {
            let cmd: NSEvent.ModifierFlags = [.command]
            let cmdCaps: NSEvent.ModifierFlags = [.command, .capsLock]
            let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
            let hideHotKey: NSEvent.ModifierFlags = [.control, .option, .command]
            let none: NSEvent.ModifierFlags = []
            let accepts = ViewModeController.isCommandOnly(cmd) && ViewModeController.isCommandOnly(cmdCaps)
            let rejects = !ViewModeController.isCommandOnly(cmdShift) && !ViewModeController.isCommandOnly(hideHotKey)
                && !ViewModeController.isCommandOnly(none)
            check("⌘E: nur ⌘ (Feststelltaste egal), nicht ⌘⇧/⌃⌥⌘ (Ausblenden-Hotkey), keyCode 14",
                  ViewModeController.keyCodeE == 14 && accepts && rejects)
            check("Menütitel", StatusMenuController.title(of: ExportFormat.png) == "Als PNG"
                  && StatusMenuController.title(of: ExportFormat.folder) == "Originale als Ordner"
                  && StatusMenuController.title(of: ExportArea.full) == "Ganze Fläche")
        }
    }

    // MARK: 5 – Mini-Render (PNG 144 dpi, PDF, Ordner)

    /// RGBA-Pixel einer Bilddatei (sRGB). Zeile 0 = obere Bildkante.
    // ⚠️ VERIFIZIEREN: Speicher eines CGBitmapContext beginnt mit der OBEREN Bildzeile (Standard-Annahme; Farbprüfungen
    // unten hängen daran – FAIL bei allen drei Farb-Checks zugleich deutet auf gespiegelte Zeilen, nicht auf den Export).
    private static func readPixels(_ url: URL) -> (width: Int, height: Int, data: [UInt8])? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil), let cs = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, buf) : nil
    }

    private static func closeTo(_ c: (Int, Int, Int), _ hex: UInt32, _ tol: Int) -> Bool {
        abs(c.0 - Int((hex >> 16) & 0xFF)) <= tol && abs(c.1 - Int((hex >> 8) & 0xFF)) <= tol && abs(c.2 - Int(hex & 0xFF)) <= tol
    }

    private static func hexString(_ c: (Int, Int, Int)) -> String { String(format: "#%02X%02X%02X", c.0, c.1, c.2) }

    /// PDF-Seite 1 per CoreGraphics in eine sRGB-Bitmap (1 px = 1 pt) rastern und Farben an Board-Punkten lesen.
    // ⚠️ VERIFIZIEREN: CGContext.drawPDFPage(_:) zeichnet die MediaBox ab dem Ursprung (Seite beginnt bei 0,0).
    private static func pdfColors(_ url: URL, rect: CGRect, points: [CGPoint]) -> [(Int, Int, Int)]? {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1), let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.drawPDFPage(page)
            return true
        }
        guard ok else { return nil }
        return points.map { p in
            let x = min(w - 1, max(0, Int(p.x - rect.minX)))
            let y = min(h - 1, max(0, Int(p.y - rect.minY)))
            let i = (y * w + x) * 4
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
        }
    }

    /// Breite des harten Schattens in Pixeln entlang eines Strahls ab `start` (Pixel, Zeile 0 oben) in Richtung (dx, dy):
    /// Summe der Abdunklung je Pixel = (Papier − R) ÷ (Papier − Schatten-R), auf [0, 1] begrenzt; Werte < 0,08 (Noise)
    /// zählen nicht. Das Bild ist papierfarben, also zählt nur der Schatten – auch kantengeglättete Randpixel anteilig.
    private static func shadowPixels(_ px: (width: Int, height: Int, data: [UInt8]), start: (Int, Int), step: (Int, Int),
                                     count: Int, paperR: Double) -> Double {
        // Schatten: Graphit #3A2E22 mit Deckkraft 0,65 über Papier → R ≈ 0,65 × 0x3A + 0,35 × Papier.
        let shadowR = Double(PaperStyle.shadowOpacity) * Double((PaperStyle.graphiteHex >> 16) & 0xFF)
            + (1 - Double(PaperStyle.shadowOpacity)) * paperR
        var sum = 0.0
        for k in 0..<count {
            let x = start.0 + step.0 * k, y = start.1 + step.1 * k
            guard x >= 0, y >= 0, x < px.width, y < px.height else { break }
            let r = Double(px.data[(y * px.width + x) * 4])
            let d = min(1, max(0, (paperR - r) / (paperR - shadowR)))
            if d >= 0.08 { sum += d }
        }
        return sum
    }

    /// Befund a96bf0f: Schatten im Bitmap-Pfad war in Gerätepixeln statt pt. Prüft (1) LayerRender bei Scale 2 und
    /// (2) Export bei 72 und 300 dpi: Schattenbreite ≈ 2 pt × dpi ÷ 72 ± 1 px, rechts und unten.
    private static func shadowWidth(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("export shadow: " + name, ok) }
        check("Umrechnung: (2, −2) pt bei 4,1667 px/pt → (8,33, −8,33) px (Richtung bleibt)",
              LayerRender.deviceShadowOffset(CGSize(width: 2, height: -2), scaleX: 300.0 / 72, scaleY: 300.0 / 72)
                == CGSize(width: 2 * 300.0 / 72, height: -2 * 300.0 / 72))
        let paperR = Double((PaperStyle.paperHex >> 16) & 0xFF)

        // (1) LayerRender direkt: Root 40×40 pt Papier, Item 20×20 pt papierfarben mit Schatten, Scale 2 → 4 px.
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { check("sRGB", false); return }
        func renderSmall(useHelper: Bool) -> (width: Int, height: Int, data: [UInt8])? {
            let root = CALayer(), layer = CALayer()
            withoutImplicitAnimations {
                root.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
                root.backgroundColor = PaperStyle.cgColor(PaperStyle.paperHex)
                layer.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
                layer.position = CGPoint(x: 20, y: 20)
                layer.backgroundColor = PaperStyle.cgColor(PaperStyle.paperHex)
                layer.shadowColor = PaperStyle.cgColor(PaperStyle.graphiteHex)
                layer.shadowOpacity = PaperStyle.shadowOpacity
                layer.shadowRadius = 0
                layer.shadowOffset = PaperStyle.shadowOffset
                layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)
                root.addSublayer(layer)
            }
            var buf = [UInt8](repeating: 0, count: 80 * 80 * 4)
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 320,
                                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                if useHelper {
                    LayerRender.render(root, in: ctx, scaleX: 2, scaleY: 2)
                } else {
                    ctx.scaleBy(x: 2, y: 2)
                    root.render(in: ctx)
                }
                return true
            }
            let restored = layer.shadowOffset == PaperStyle.shadowOffset
            return ok && restored ? (80, 80, buf) : nil
        }
        if let fixed = renderSmall(useHelper: true), let plain = renderSmall(useHelper: false) {
            // Mitte (40, 40) px; Item reicht bis 60 px. Nach rechts bzw. unten (Zeile 0 oben) messen.
            let right = shadowPixels(fixed, start: (40, 40), step: (1, 0), count: 40, paperR: paperR)
            let down = shadowPixels(fixed, start: (40, 40), step: (0, 1), count: 40, paperR: paperR)
            let plainRight = shadowPixels(plain, start: (40, 40), step: (1, 0), count: 40, paperR: paperR)
            Log.line("[EXPORT]", String(format: "Selftest Schatten @2x: LayerRender rechts=%.2f unten=%.2f px, "
                + "render(in:) ohne Umrechnung rechts=%.2f px (Befund: Gerätepixel)", right, down, plainRight))
            check(String(format: "LayerRender @2x: Schatten rechts %.2f px, unten %.2f px ≈ 4 px (2 pt), Versatz danach zurückgesetzt",
                         right, down), abs(right - 4) <= 1 && abs(down - 4) <= 1)
        } else {
            check("LayerRender @2x rendern (und shadowOffset zurückgesetzt)", false)
        }

        // (2) Export bei 72 und 300 dpi, papierfarbenes Bild ohne Kipp.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dropboard-selftest-shadow-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let store = BoardStore(boardDirectory: root.appendingPathComponent("board", isDirectory: true))
        let it = item(CGPoint(x: 200, y: 150), CGSize(width: 220, height: 146), fileName: "P.png")
        let document = BoardDocument(items: [it])
        do {
            try store.prepareDirectories()
            guard let ctx = CGContext(data: nil, width: 660, height: 438, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            ctx.setFillColor(PaperStyle.cgColor(PaperStyle.paperHex))
            ctx.fill(CGRect(x: 0, y: 0, width: 660, height: 438))
            guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            try PaperArt.writePNG(image, to: store.imageURL(fileName: "P.png"))
        } catch {
            check("Test-Board anlegen (\(error))", false)
            return
        }
        for dpi in [72, 300] {
            let url = root.appendingPathComponent("schatten-\(dpi).png")
            let request = ExportRequest(format: .png, dpi: dpi, area: .content, boardSize: CGSize(width: 1000, height: 700),
                                        screenScale: 2)
            guard let result = try? Exporter.run(document: document, store: store, request: request, to: url),
                  let rect = result.rect, let px = readPixels(url) else {
                check("Export \(dpi) dpi", false)
                continue
            }
            let sx = CGFloat(px.width) / rect.width, sy = CGFloat(px.height) / rect.height
            let center = it.center.cgPoint
            let cx = Int(((center.x - rect.minX) * sx).rounded(.down))
            let cy = Int(((center.y - rect.minY) * sy).rounded(.down))
            let corner = px.data[(2 * px.width + 2) * 4]   // Papier mit Noise, oben links
            let paper = Double(corner)
            let reach = Int((CGFloat(it.size.width) / 2 + 8) * sx)
            let right = shadowPixels(px, start: (cx, cy), step: (1, 0), count: reach, paperR: paper)
            let down = shadowPixels(px, start: (cx, cy), step: (0, 1), count: reach, paperR: paper)
            let expectX = 2 * Double(sx), expectY = 2 * Double(sy)
            check(String(format: "%ld dpi: Schatten rechts %.2f px (erwartet %.2f), unten %.2f px (erwartet %.2f) ± 1 px",
                         dpi, right, expectX, down, expectY),
                  abs(right - expectX) <= 1 && abs(down - expectY) <= 1)
        }
    }

    private static func render(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("export render: " + name, ok) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dropboard-selftest-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let store = BoardStore(boardDirectory: root.appendingPathComponent("board", isDirectory: true))
        let out = root.appendingPathComponent("out", isDirectory: true)
        guard let plain = PaperArt.demoImages().first, let four = PaperArt.demoCropImage() else {
            check("Testbilder anlegen", false)
            return
        }
        // Board: A (Salbei 600×400 → 220×147 pt, Kipp 1,5°), B (vier Felder, Crop oben links, −1,2°), C (Datei fehlt).
        let crop = BoardCrop(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        let a = item(CGPoint(x: 200, y: 150), CGSize(width: 220, height: 147), rotation: 1.5, fileName: "A.png",
                     source: ItemSource(route: "fileURL", originalName: "salbei.png"))
        let b = item(CGPoint(x: 480, y: 170), CGSize(width: 132, height: 88.2), rotation: -1.2, fileName: "B.png",
                     source: ItemSource(route: "imageData", originalName: "vier felder.png", originalURL: "https://example.invalid/vier.png"),
                     crop: crop)
        let c = item(CGPoint(x: 650, y: 300), CGSize(width: 60, height: 60), fileName: "C-fehlt.png")
        let document = BoardDocument(items: [a, b, c])
        do {
            try store.prepareDirectories()
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            try PaperArt.writePNG(plain, to: store.imageURL(fileName: "A.png"))
            try PaperArt.writePNG(four, to: store.imageURL(fileName: "B.png"))
            try store.save(document)
        } catch {
            check("Test-Board anlegen (\(error))", false)
            return
        }
        let boardSize = CGSize(width: 1000, height: 700)
        let date = Date()
        guard let rect = Exporter.exportRect(document, area: .content, boardSize: boardSize),
              let plan = ExportMath.pixelPlan(size: rect.size, dpi: 144) else {
            check("Bereich/Pixelmaß berechnen", false)
            return
        }

        // PNG 144 dpi
        let pngURL = Exporter.targetURL(in: out, format: .png, date: date)
        var request = ExportRequest(format: .png, dpi: 144, area: .content, boardSize: boardSize, screenScale: 2, date: date)
        do {
            let r = try Exporter.run(document: document, store: store, request: request, to: pngURL)
            Log.line("[EXPORT]", "Selftest " + r.logLine)
            let named = pngURL.lastPathComponent.hasPrefix("Dropboard ") && pngURL.pathExtension == "png"
            let sameRect = r.rect.map { near($0, rect) } == true
            check("PNG geschrieben, Name „Dropboard <Datum Uhrzeit>.png“, Plan = \(plan.describe)",
                  fm.fileExists(atPath: pngURL.path) && named && r.plan == plan && sameRect)
            check("2 Bilder gezeichnet, 1 fehlend (Platzhalter)", r.items == 2 && r.missing == 1)
            if let src = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
                let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
                let dx = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
                let dy = (props[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
                check("PNG zurückgelesen: Pixelmaß \(w ?? -1)x\(h ?? -1) = \(plan.pixelWidth)x\(plan.pixelHeight)",
                      w == plan.pixelWidth && h == plan.pixelHeight)
                let dxText = dx.map { String(format: "%.2f", $0) } ?? "fehlt"
                let dyText = dy.map { String(format: "%.2f", $0) } ?? "fehlt"
                let dpiOK = dx.map { abs($0 - 144) < 0.5 } == true && dy.map { abs($0 - 144) < 0.5 } == true
                check("PNG zurückgelesen: DPI-Property \(dxText)×\(dyText) ≈ 144", dpiOK)
                // ⚠️ VERIFIZIEREN: ImageIO meldet das eingebettete Profil als kCGImagePropertyProfileName („sRGB IEC61966-2.1“).
                let profile = props[kCGImagePropertyProfileName] as? String
                check("PNG explizit sRGB getaggt (Profil: \(profile ?? "fehlt"))", profile?.contains("sRGB") == true)
            } else {
                check("PNG zurücklesen", false)
            }
            if let px = readPixels(pngURL) {
                let sx = CGFloat(px.width) / rect.width, sy = CGFloat(px.height) / rect.height
                func rgb(_ p: CGPoint) -> (Int, Int, Int) {
                    let x = min(px.width - 1, max(0, Int(((p.x - rect.minX) * sx).rounded(.down))))
                    let y = min(px.height - 1, max(0, Int(((p.y - rect.minY) * sy).rounded(.down))))
                    let i = (y * px.width + x) * 4
                    return (Int(px.data[i]), Int(px.data[i + 1]), Int(px.data[i + 2]))
                }
                func close(_ c: (Int, Int, Int), _ hex: UInt32, _ tol: Int) -> Bool {
                    abs(c.0 - Int((hex >> 16) & 0xFF)) <= tol && abs(c.1 - Int((hex >> 8) & 0xFF)) <= tol
                        && abs(c.2 - Int(hex & 0xFF)) <= tol
                }
                func hex(_ c: (Int, Int, Int)) -> String { String(format: "#%02X%02X%02X", c.0, c.1, c.2) }
                let paper = rgb(CGPoint(x: rect.minX + 4, y: rect.minY + 4))
                check("Papier in der Ecke ≈ #F4F0E8 (+ Noise): \(hex(paper))", close(paper, PaperStyle.paperHex, 12))
                let centerA = rgb(a.center.cgPoint)
                check("Bild A Mitte ≈ Salbei #8FA3A0: \(hex(centerA))", close(centerA, 0x8FA3A0, 8))
                let centerB = rgb(b.center.cgPoint)
                check("Bild B (Crop oben links) Mitte ≈ Terrakotta #C48B7A: \(hex(centerB)) "
                      + "(Stahlblau #7C8DA8 = contentsRect-Ursprung falsch)", close(centerB, 0xC48B7A, 8))
                let centerC = rgb(c.center.cgPoint)
                check("fehlende Datei C → Platzhalter #FBF9F4: \(hex(centerC))", close(centerC, PaperStyle.placeholderHex, 8))
                // 1 pt unter der Unterkante von A (Mitte), gedreht wie A: dort liegt der 2-pt-Schatten.
                let offset = CropMath.toBoard(CGPoint(x: 0, y: a.size.height / 2 + 1), rotation: a.rotation)
                let shadow = rgb(CGPoint(x: a.center.x + offset.x, y: a.center.y + offset.y))
                check("harter Schatten unter A dunkler als Papier (≈ #797065): \(hex(shadow))", shadow.0 < 0xB0 && shadow.0 > 0x40)
            } else {
                check("PNG-Pixel lesen", false)
            }
        } catch {
            check("PNG-Export (\(error))", false)
        }

        // PDF (Standard: Bitmap in Ziel-DPI) und Versuch „layers“
        for mode in [ExportPDFMode.bitmap, .layers] {
            request.format = .pdf
            request.pdfMode = mode
            let pdfURL = Exporter.targetURL(in: out, format: .pdf, date: date)
            do {
                let r = try Exporter.run(document: document, store: store, request: request, to: pdfURL)
                Log.line("[EXPORT]", "Selftest " + r.logLine)
                let page = CGPDFDocument(pdfURL as CFURL)?.page(at: 1)
                let box = page?.getBoxRect(.mediaBox) ?? .zero
                let pages = CGPDFDocument(pdfURL as CFURL)?.numberOfPages ?? 0
                let sizeOK = abs(Double(box.width - rect.width)) < 0.01 && abs(Double(box.height - rect.height)) < 0.01
                let role = mode == .layers ? "Versuch" : "Standard"
                let sizes = "Seitengröße \(Int(box.width))×\(Int(box.height)) pt = Bereich \(Int(rect.width))×\(Int(rect.height)) pt"
                check("PDF (\(mode.rawValue), \(role)): 1 Seite, \(sizes)", pages == 1 && sizeOK && r.bytes > 0)
                // Farbe: Seite per CoreGraphics in eine sRGB-Bitmap rastern und mit den Quellfarben vergleichen. Stimmt
                // das, liegt eine Entsättigung in einer anderen Rasterung (z. B. sips/Vorschau), nicht im PDF.
                if let colors = pdfColors(pdfURL, rect: rect, points: [a.center.cgPoint, b.center.cgPoint]), colors.count == 2 {
                    let okA = closeTo(colors[0], 0x8FA3A0, 8), okB = closeTo(colors[1], 0xC48B7A, 8)
                    check("PDF (\(mode.rawValue)) in sRGB gerastert: A \(hexString(colors[0])) ≈ #8FA3A0, B \(hexString(colors[1])) ≈ #C48B7A",
                          okA && okB)
                } else {
                    check("PDF (\(mode.rawValue)) rastern", false)
                }
            } catch {
                check("PDF-Export \(mode.rawValue) (\(error))", false)
            }
        }
        check("zwei PDFs am selben Zeitstempel: zweites heißt „… 2.pdf“",
              fm.fileExists(atPath: out.appendingPathComponent(
                  "Dropboard \(ExportNaming.timestamp(date)) 2.pdf").path))

        // Ordner mit Originalen
        request.format = .folder
        let folderURL = Exporter.targetURL(in: out, format: .folder, date: date)
        do {
            let r = try Exporter.run(document: document, store: store, request: request, to: folderURL)
            Log.line("[EXPORT]", "Selftest " + r.logLine)
            let files = Set((try? fm.contentsOfDirectory(atPath: folderURL.path)) ?? [])
            check("Ordner: Originale unter Herkunftsnamen + board.json + index.txt (fehlend 1): \(files.sorted())",
                  files == ["salbei.png", "vier felder.png", "board.json", "index.txt"] && r.items == 2 && r.missing == 1)
            let copied = try? BoardStore.makeDecoder().decode(BoardDocument.self,
                                                               from: Data(contentsOf: folderURL.appendingPathComponent("board.json")))
            check("Ordner: board.json lesbar, 3 Items, Crop erhalten", copied?.items.count == 3 && copied?.items[1].crop == crop)
            let index = (try? String(contentsOf: folderURL.appendingPathComponent("index.txt"), encoding: .utf8)) ?? ""
            check("Ordner: index.txt mit Reihenfolge und URL",
                  index.contains("1. salbei.png") && index.contains("2. vier felder.png") && index.contains("https://example.invalid/vier.png"))
            let same = (try? Data(contentsOf: folderURL.appendingPathComponent("salbei.png")))
                == (try? Data(contentsOf: store.imageURL(fileName: "A.png")))
            check("Ordner: Kopie bytegleich zum Original", same)
        } catch {
            check("Ordner-Export (\(error))", false)
        }

        // Leeres Board
        var failedEmpty = false
        do {
            _ = try Exporter.run(document: BoardDocument(), store: store, request: request, to: out.appendingPathComponent("leer"))
        } catch {
            failedEmpty = true
        }
        check("leeres Board → Fehler, nichts geschrieben",
              failedEmpty && !fm.fileExists(atPath: out.appendingPathComponent("leer").path))
    }
}
