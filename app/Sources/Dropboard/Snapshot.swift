import AppKit
import QuartzCore
import DropboardCore

/// `--snapshot <pfad.png>`: Board mit den gespeicherten Bildern offscreen rendern (Layer-Baum per
/// CALayer.render(in:) in einen Bitmap-Kontext in Backing-Scale), dazu das Eselsohr als `<pfad ohne .png>-ear.png`
/// und eine Übersicht aller 4 Ecken auf hellen/dunklen Hintergründen als `<pfad ohne .png>-ear-sheet.png`.
/// Kein Fenster, keine Systemberechtigung. Dekodiert synchron (es läuft kein Run-Loop).
/// `--snapshot-demo`: vorher 5 Platzhalterbilder in ein TEMPORÄRES Board schreiben (nie in den echten Ordner),
/// plus ein offener Platzhalter (Look bis zur Erfüllung eines Promise) und ein beschnittenes Bild (E11, vier Farbfelder,
/// Ausschnitt oben links). Mit Demo zusätzlich `<pfad ohne .png>-crop.png`: dasselbe Board mit diesem Bild im Beschnittmodus.
@MainActor
enum Snapshot {
    static func run(_ options: LaunchOptions) -> Bool {
        guard let path = options.snapshotPath else { return false }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let boardSize = screen?.frame.size ?? CGSize(width: 1512, height: 982)
        let scale = screen?.backingScaleFactor ?? 2
        let metrics = LayoutMetrics.standard
        let area: CGRect
        if let s = screen {
            area = ScreenGeometry.usableArea(s, metrics: metrics)
        } else {
            area = CGRect(origin: .zero, size: boardSize).insetBy(dx: CGFloat(metrics.margin), dy: CGFloat(metrics.margin))
        }

        var tempDir: URL?
        let store: BoardStore
        if options.snapshotDemo {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dropboard-snapshot-\(UUID().uuidString)", isDirectory: true)
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
                try populateDemo(store, area: area, metrics: metrics)
            }
            let document = try store.load()
            Log.line("[STORE]", "Snapshot lädt items=\(document.items.count) aus \(store.documentURL.path)")

            let scene = BoardScene(size: boardSize, scale: scale, noiseTile: PaperArt.loadNoiseTile())
            scene.setDimmed(options.snapshotDimmed)
            var occupied: [CGRect] = []
            for item in document.items {
                let url = store.imageURL(fileName: item.fileName)
                let pose = scene.pose(center: item.center.cgPoint, rotation: item.rotation)
                if let decoded = ImageDecoder.decode(url: url, size: item.size.cgSize, crop: item.crop, scale: scale) {
                    StopMotion.setModel(pose, on: scene.addImage(id: item.id, image: decoded.cgImage, size: decoded.size,
                                                                 crop: item.crop))
                } else {
                    Log.line("[STORE]", "Snapshot: Bild fehlt/unlesbar \(item.fileName) → Platzhalter")
                    StopMotion.setModel(pose, on: scene.addPlaceholder(id: item.id, size: item.size.cgSize))
                }
                occupied.append(item.frame)
            }
            if options.snapshotDemo,
               let center = BoardLayout.findFreeSlot(size: metrics.placeholderSize, occupied: occupied, area: area,
                                                     grid: metrics.grid, gap: metrics.gap) {
                let layer = scene.addPlaceholder(id: UUID(), size: metrics.placeholderSize)
                StopMotion.setModel(scene.pose(center: center, rotation: -1.5), on: layer)
            }

            let boardURL = URL(fileURLWithPath: path)
            try renderPNG(scene.root, size: boardSize, scale: scale, to: boardURL)
            Log.line("[WIN]", "Snapshot Board geschrieben \(boardURL.path) \(Int(boardSize.width))x\(Int(boardSize.height))pt @\(scale)x "
                + "items=\(scene.itemCount) abgedunkelt=\(scene.isDimmed) beschnitten=\(document.items.filter { $0.crop != nil }.count)")

            // E11: das (erste) beschnittene Bild im Beschnittmodus – gerade, ganzes Bild, außen abgedunkelt, Rahmen, Griffe.
            if options.snapshotDemo, let cropped = document.items.first(where: { $0.crop != nil }) {
                let editor = CropEditor(itemCenter: cropped.center.cgPoint, itemSize: cropped.size.cgSize,
                                        crop: cropped.crop, rotation: 0)
                StopMotion.batch {
                    scene.bringToFront(id: cropped.id)
                    scene.beginCropEditing(id: cropped.id, fullSize: editor.fullSize, crop: editor.crop)
                    if let layer = scene.itemLayer(id: cropped.id) {
                        StopMotion.setModel(scene.pose(center: editor.imageCenter, rotation: 0), on: layer)
                    }
                }
                let cropURL = cropSnapshotURL(for: boardURL)
                try renderPNG(scene.root, size: boardSize, scale: scale, to: cropURL)
                Log.line("[CROP]", "Snapshot Beschnittmodus geschrieben \(cropURL.path) crop=\(BoardCrop.describe(cropped.crop)) "
                    + "voll=\(Int(editor.fullSize.width))x\(Int(editor.fullSize.height))pt "
                    + "contentsRectOriginTop=\(CropStyle.contentsRectOriginTop)")
            }

            let earSize = CGSize(width: DropboardConfig.earSize, height: DropboardConfig.earSize)
            let corner = Settings().corner   // gespeicherte Ecke (Schritt 8), Standard oben rechts
            let earRoot = CALayer()
            let ear = CALayer()
            withoutImplicitAnimations {
                earRoot.frame = CGRect(origin: .zero, size: earSize)
                ear.frame = earRoot.frame
                ear.contentsScale = scale
                ear.contents = PaperArt.earImage(size: earSize, scale: scale, noiseTile: PaperArt.loadNoiseTile(),
                                                 corner: corner)
                ear.opacity = PaperStyle.earOpacity
                earRoot.addSublayer(ear)
            }
            let earURL = earSnapshotURL(for: boardURL)
            try renderPNG(earRoot, size: earSize, scale: scale, to: earURL)
            Log.line("[WIN]", "Snapshot Eselsohr geschrieben \(earURL.path) ecke=\(corner.rawValue)")
            let sheetURL = earSheetURL(for: boardURL)
            try renderEarSheet(earSize: earSize, scale: scale, noiseTile: PaperArt.loadNoiseTile(), to: sheetURL)
            Log.line("[WIN]", "Snapshot Eselsohr-Übersicht geschrieben \(sheetURL.path) (Zeilen: weiß, hellgrau, blau, "
                + "dunkel; Spalten: oben rechts, oben links, unten rechts, unten links)")
            return true
        } catch {
            Log.line("[WIN]", "Snapshot FEHLER: \(error)")
            return false
        }
    }

    /// `/x/board.png` → `/x/board-ear.png`
    static func earSnapshotURL(for url: URL) -> URL {
        let base = url.pathExtension.lowercased() == "png" ? url.deletingPathExtension() : url
        return base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-ear.png")
    }

    /// `/x/board.png` → `/x/board-crop.png`
    static func cropSnapshotURL(for url: URL) -> URL {
        let base = url.pathExtension.lowercased() == "png" ? url.deletingPathExtension() : url
        return base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-crop.png")
    }

    /// `/x/board.png` → `/x/board-ear-sheet.png`
    static func earSheetURL(for url: URL) -> URL {
        let base = url.pathExtension.lowercased() == "png" ? url.deletingPathExtension() : url
        return base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-ear-sheet.png")
    }

    /// Sichtprüfung Eselsohr (Fix C): alle 4 Ecken in 1:1 auf vier typischen Hintergründen (weiß, hellgrau,
    /// Desktop-Blau, dunkel), je Zelle 2 × Eselsohr-Größe, Eselsohr mittig mit `earOpacity` (wie im Panel).
    static func renderEarSheet(earSize: CGSize, scale: CGFloat, noiseTile: CGImage?, to url: URL) throws {
        let backgrounds: [UInt32] = [0xFFFFFF, 0xDCDCDC, 0x5E7388, 0x1C1C1E]
        let corners: [EarCorner] = [.topRight, .topLeft, .bottomRight, .bottomLeft]
        let cell = CGSize(width: earSize.width * 2 * scale, height: earSize.height * 2 * scale)   // Pixel
        let pw = Int(cell.width) * corners.count, ph = Int(cell.height) * backgrounds.count
        guard pw > 0, ph > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        let earPx = CGSize(width: earSize.width * scale, height: earSize.height * scale)
        for (row, hex) in backgrounds.enumerated() {
            let y = CGFloat(backgrounds.count - 1 - row) * cell.height   // Zeile 0 oben
            ctx.setFillColor(PaperStyle.cgColor(hex))
            ctx.fill(CGRect(x: 0, y: y, width: CGFloat(pw), height: cell.height))
            for (col, corner) in corners.enumerated() {
                guard let ear = PaperArt.earImage(size: earSize, scale: scale, noiseTile: noiseTile, corner: corner)
                else { continue }
                let x = CGFloat(col) * cell.width
                ctx.saveGState()
                ctx.setAlpha(CGFloat(PaperStyle.earOpacity))
                ctx.draw(ear, in: CGRect(x: x + (cell.width - earPx.width) / 2, y: y + (cell.height - earPx.height) / 2,
                                         width: earPx.width, height: earPx.height))
                ctx.restoreGState()
            }
        }
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PaperArt.writePNG(image, to: url)
    }

    // ⚠️ VERIFIZIEREN: CALayer.render(in:) kommt in keinem Spike vor. Laut Doku rendert es keine Masken und keine
    // 3D-Transforms; unsere Rotation ist eine reine z-Rotation (affin). Prüfen: Schatten und Rotation im PNG sichtbar.
    // CGContext.scaleBy(x:y:) (Punkte → Pixel): auf dem Mac mini belegt (Export E12, Pixelmaße exakt).
    static func renderPNG(_ layer: CALayer, size: CGSize, scale: CGFloat, to url: URL) throws {
        let pw = Int((size.width * scale).rounded()), ph = Int((size.height * scale).rounded())
        guard pw > 0, ph > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        // Schatten in pt wie am Bildschirm (Befund E12: render(in:) setzt shadowOffset in Gerätepixeln) → LayerRender.
        LayerRender.render(layer, in: ctx, scaleX: scale, scaleY: scale)
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PaperArt.writePNG(image, to: url)
    }

    /// 5 Demo-Bilder: 3 per Free-Slot-Finder (Quick-Drop), 2 per Cursor-Drop mit Snap. Fester Seed.
    /// Auch für `--export --snapshot-demo` (ExportCLI).
    static func populateDemo(_ store: BoardStore, area: CGRect, metrics: LayoutMetrics) throws {
        try store.prepareDirectories()
        var rng = SplitMix64(seed: 42)
        var document = BoardDocument()
        let cursors = [CGPoint(x: area.midX, y: area.midY + 120), CGPoint(x: area.maxX - 300, y: area.maxY - 200)]
        for (i, image) in PaperArt.demoImages().enumerated() {
            let id = UUID()
            let fileName = BoardStore.imageFileName(id: id, fileExtension: "png")
            try PaperArt.writePNG(image, to: store.imageURL(fileName: fileName))
            guard let size = BoardLayout.fittedSize(pixelWidth: image.width, pixelHeight: image.height,
                                                    longestEdge: metrics.longestEdge) else { continue }
            let center: CGPoint
            if i >= 3 {
                center = BoardLayout.dropCenter(cursor: cursors[i - 3], size: size, area: area, grid: metrics.grid)
            } else {
                center = BoardLayout.findFreeSlot(size: size, occupied: document.items.map { $0.frame }, area: area,
                                                  grid: metrics.grid, gap: metrics.gap) ?? CGPoint(x: area.midX, y: area.midY)
            }
            let rotation = BoardLayout.randomTilt(range: metrics.tiltRange, using: &rng)
            document.upsert(BoardItem(id: id, fileName: fileName, center: BoardPoint(center), rotation: rotation,
                                      size: BoardSize(size), addedAt: BoardClock.timestamp(),
                                      source: ItemSource(route: "demo")))
        }
        // E11: beschnittenes Demo-Bild. Volle Größe F = eingepasst (220 pt), sichtbar = Ausschnitt × F.
        if let image = PaperArt.demoCropImage(),
           let full = BoardLayout.fittedSize(pixelWidth: image.width, pixelHeight: image.height, longestEdge: metrics.longestEdge) {
            let id = UUID()
            let fileName = BoardStore.imageFileName(id: id, fileExtension: "png")
            try PaperArt.writePNG(image, to: store.imageURL(fileName: fileName))
            let crop = BoardCrop(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
            let size = CropMath.visibleSize(fullSize: full, crop: crop)
            let center = BoardLayout.findFreeSlot(size: size, occupied: document.items.map { $0.frame }, area: area,
                                                  grid: metrics.grid, gap: metrics.gap) ?? CGPoint(x: area.midX, y: area.midY)
            let rotation = BoardLayout.randomTilt(range: metrics.tiltRange, using: &rng)
            document.upsert(BoardItem(id: id, fileName: fileName, center: BoardPoint(center), rotation: rotation,
                                      size: BoardSize(size), addedAt: BoardClock.timestamp(),
                                      source: ItemSource(route: "demo"), crop: crop))
        }
        try store.save(document)
        Log.line("[STORE]", "Snapshot-Demo: \(document.items.count) Bilder in temporärem Board \(store.boardDirectory.path)")
    }
}

/// Layer-Baum per `CALayer.render(in:)` in einen skalierten Kontext (pt → Pixel) zeichnen, mit Schatten in pt.
///
/// Befund (Mac mini, Export E12, Commit a96bf0f): Im Bitmap-Pfad war der harte Schatten bei 300 dpi nur ~2 px statt
/// 2 pt × 300/72 ≈ 8 px breit; im PDF-Kontext (Basisraum = pt) stimmte er. Ursache: render(in:) zeichnet den Schatten
/// per CoreGraphics, und dort gilt der Schattenversatz im Basis-/Geräteraum – die CTM-Skalierung (scaleBy) wirkt nicht
/// darauf (Apple-Doku zu CGContextSetShadowWithColor: offset „in base-space units“; hier aus dem Gedächtnis,
/// ⚠️ VERIFIZIEREN – das Messergebnis oben ist der Beleg). Gegenmittel: shadowOffset aller Layer mit Schatten für die
/// Dauer des Renderns × Skala setzen (Richtung bleibt: Basisraum der Bitmap ist y-oben wie die Layer), danach
/// zurücksetzen. Der Schattenpfad (shadowPath) selbst folgt der CTM und braucht nichts. Radius ist 0 (kein Blur).
/// Nicht an einen Actor gebunden (Export rendert auf einer Hintergrund-Queue).
enum LayerRender {
    /// Versatz in Gerätepixeln für einen Versatz in pt bei Skala sx/sy (px pro pt).
    static func deviceShadowOffset(_ offset: CGSize, scaleX: CGFloat, scaleY: CGFloat) -> CGSize {
        CGSize(width: offset.width * scaleX, height: offset.height * scaleY)
    }

    static func render(_ layer: CALayer, in ctx: CGContext, scaleX: CGFloat, scaleY: CGFloat) {
        var saved: [(CALayer, CGSize)] = []
        var stack: [CALayer] = [layer]
        while let l = stack.popLast() {
            if l.shadowOpacity > 0 && l.shadowOffset != .zero { saved.append((l, l.shadowOffset)) }
            stack.append(contentsOf: l.sublayers ?? [])
        }
        withoutImplicitAnimations {
            for (l, offset) in saved { l.shadowOffset = deviceShadowOffset(offset, scaleX: scaleX, scaleY: scaleY) }
        }
        ctx.saveGState()
        ctx.scaleBy(x: scaleX, y: scaleY)
        layer.render(in: ctx)
        ctx.restoreGState()
        withoutImplicitAnimations {
            for (l, offset) in saved { l.shadowOffset = offset }
        }
    }
}
