import AppKit
import QuartzCore
import DropboardCore

/// `--snapshot <pfad.png>`: Board mit den gespeicherten Bildern offscreen rendern (Layer-Baum per
/// CALayer.render(in:) in einen Bitmap-Kontext in Backing-Scale), dazu das Eselsohr als `<pfad ohne .png>-ear.png`.
/// Kein Fenster, keine Systemberechtigung. Dekodiert synchron (es läuft kein Run-Loop).
/// `--snapshot-demo`: vorher 5 Platzhalterbilder in ein TEMPORÄRES Board schreiben (nie in den echten Ordner),
/// plus ein offener Platzhalter (Look bis zur Erfüllung eines Promise).
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
                if let decoded = ImageDecoder.decode(url: url, size: item.size.cgSize, scale: scale) {
                    StopMotion.setModel(pose, on: scene.addImage(id: item.id, image: decoded.cgImage, size: decoded.size))
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
                + "items=\(scene.itemCount) abgedunkelt=\(scene.isDimmed)")

            let earSize = CGSize(width: DropboardConfig.earSize, height: DropboardConfig.earSize)
            let earRoot = CALayer()
            let ear = CALayer()
            withoutImplicitAnimations {
                earRoot.frame = CGRect(origin: .zero, size: earSize)
                ear.frame = earRoot.frame
                ear.contentsScale = scale
                ear.contents = PaperArt.earImage(size: earSize, scale: scale, noiseTile: PaperArt.loadNoiseTile())
                ear.opacity = PaperStyle.earOpacity
                earRoot.addSublayer(ear)
            }
            let earURL = earSnapshotURL(for: boardURL)
            try renderPNG(earRoot, size: earSize, scale: scale, to: earURL)
            Log.line("[WIN]", "Snapshot Eselsohr geschrieben \(earURL.path)")
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

    // ⚠️ VERIFIZIEREN: CALayer.render(in:) kommt in keinem Spike vor. Laut Doku rendert es keine Masken und keine
    // 3D-Transforms; unsere Rotation ist eine reine z-Rotation (affin). Prüfen: Schatten und Rotation im PNG sichtbar.
    // ⚠️ VERIFIZIEREN: CGContext.scaleBy(x:y:) (Punkte → Pixel) ebenfalls nicht aus einem Spike.
    static func renderPNG(_ layer: CALayer, size: CGSize, scale: CGFloat, to url: URL) throws {
        let pw = Int((size.width * scale).rounded()), ph = Int((size.height * scale).rounded())
        guard pw > 0, ph > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PaperArt.writePNG(image, to: url)
    }

    /// 5 Demo-Bilder: 3 per Free-Slot-Finder (Quick-Drop), 2 per Cursor-Drop mit Snap. Fester Seed.
    private static func populateDemo(_ store: BoardStore, area: CGRect, metrics: LayoutMetrics) throws {
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
        try store.save(document)
        Log.line("[STORE]", "Snapshot-Demo: \(document.items.count) Bilder in temporärem Board \(store.boardDirectory.path)")
    }
}
