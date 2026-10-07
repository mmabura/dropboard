import AppKit
import ImageIO

/// Vorgerenderte Bitmaps: Noise-Kachel, gekachelte Noise, Eselsohr, Demo-Platzhalterbilder.
/// Alles wird einmal erzeugt und als `contents` statischer Layer gesetzt (kein Zeichnen zur Laufzeit).
enum PaperArt {
    /// PNG-Kachel aus dem Bundle (aus Spike board-paper).
    static func loadNoiseTile() -> CGImage? {
        guard let url = ResourceLocator.url(forResource: "noise", withExtension: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Kachelt die PNG einmal auf Pixelgröße, 1:1 in Device-Pixeln (aus Spike board-paper).
    static func tiledNoise(tile: CGImage, pixelSize: CGSize) -> CGImage? {
        let w = Int(pixelSize.width.rounded(.up)), h = Int(pixelSize.height.rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height), byTiling: true)
        return ctx.makeImage()
    }

    /// Eselsohr als umgeknicktes Papiereck: sichtbar ist die Lasche (Dreieck mit rechtem Winkel unten links,
    /// Falz von oben links nach unten rechts), das Dreieck oben rechts ist „weg“ (transparent).
    /// Die Lasche zeigt die Papier-Rückseite (etwas dunkler und kühler als das Board), mit derselben Noise, Falzband,
    /// Falzlinie und hellem Haarstrich; kein Schatten.
    // ⚠️ VERIFIZIEREN: CGMutablePath, clip(), strokePath() und setAlpha() kommen in keinem Spike vor
    // (Standard-CoreGraphics). Prüfen per `--snapshot`: Datei `<pfad>-ear.png`.
    // ⚠️ VERIFIZIEREN: Falzband und heller Haarstrich (Clip + Strokes, Offset um 1 pt) sind rein rechnerisch ausgelegt,
    // Wirkung auf dem Mac im Snapshot prüfen (ob die Lasche als Rückseite einer Papierecke liest).
    static func earImage(size: CGSize, scale: CGFloat, noiseTile: CGImage?) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let W = CGFloat(w), H = CGFloat(h)

        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: 0, y: H))
        flap.addLine(to: CGPoint(x: W, y: 0))
        flap.addLine(to: CGPoint(x: 0, y: 0))
        flap.closeSubpath()

        // Papierfläche mit Noise
        ctx.saveGState()
        ctx.addPath(flap)
        ctx.clip()
        ctx.setFillColor(PaperStyle.cgColor(PaperStyle.earBackHex))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        if let tile = noiseTile {
            ctx.setAlpha(CGFloat(PaperStyle.noiseOpacity))
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height), byTiling: true)
            ctx.setAlpha(1)
        }
        ctx.restoreGState()

        // Haarlinie an den beiden Papierkanten (1 Device-Pixel, auf Pixelmitte)
        let edges = CGMutablePath()
        edges.move(to: CGPoint(x: 0.5, y: H))
        edges.addLine(to: CGPoint(x: 0.5, y: 0.5))
        edges.addLine(to: CGPoint(x: W, y: 0.5))
        ctx.addPath(edges)
        ctx.setStrokeColor(PaperStyle.cgColor(PaperStyle.graphiteHex, alpha: PaperStyle.earEdgeAlpha))
        ctx.setLineWidth(1)
        ctx.strokePath()

        // Falz: Diagonale von oben links nach unten rechts
        let fold = CGMutablePath()
        fold.move(to: CGPoint(x: 0, y: H))
        fold.addLine(to: CGPoint(x: W, y: 0))

        // 1) schmales Band (3 pt) auf der Lasche entlang des Falzes, nur innerhalb der Lasche (Clip), flach, kein Verlauf
        ctx.saveGState()
        ctx.addPath(flap)
        ctx.clip()
        ctx.addPath(fold)
        ctx.setStrokeColor(PaperStyle.cgColor(PaperStyle.graphiteHex, alpha: PaperStyle.earFoldBandAlpha))
        ctx.setLineWidth(6 * scale)   // halbe Breite (3 pt) liegt innerhalb des Clips
        ctx.strokePath()

        // 2) heller Haarstrich (1 pt) direkt neben der Falzlinie auf der Laschenseite (Normale (-1,-1)/√2, Abstand 1 pt)
        let off = scale * 0.7071
        let highlight = CGMutablePath()
        highlight.move(to: CGPoint(x: -off, y: H - off))
        highlight.addLine(to: CGPoint(x: W - off, y: -off))
        ctx.addPath(highlight)
        ctx.setStrokeColor(PaperStyle.cgColor(0xFFFFFF, alpha: PaperStyle.earFoldHighlightAlpha))
        ctx.setLineWidth(max(1, scale))
        ctx.strokePath()
        ctx.restoreGState()

        // 3) Falzlinie (1 pt)
        ctx.addPath(fold)
        ctx.setStrokeColor(PaperStyle.cgColor(PaperStyle.graphiteHex, alpha: PaperStyle.earFoldAlpha))
        ctx.setLineWidth(max(1, scale))
        ctx.strokePath()

        return ctx.makeImage()
    }

    /// Einfarbige Demo-Bilder in gedämpften Farben und verschiedenen Seitenverhältnissen (aus Spike board-paper).
    static func demoImages() -> [CGImage] {
        let specs: [(UInt32, CGFloat, CGFloat)] = [
            (0x8FA3A0, 3, 2),   // Salbei-Graublau
            (0xC48B7A, 2, 3),   // gedämpftes Terrakotta
            (0xB8A86B, 1, 1),   // Senf, gedämpft
            (0x7C8DA8, 4, 3),   // Stahlblau, gedämpft
            (0x9A7F9E, 16, 9)   // Staubflieder
        ]
        return specs.compactMap { spec -> CGImage? in
            let (hex, w, h) = spec
            let px = 600
            let pw = Int(CGFloat(px) * (w >= h ? 1 : w / h))
            let ph = Int(CGFloat(px) * (h >= w ? 1 : h / w))
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.setFillColor(PaperStyle.cgColor(hex))
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
            return ctx.makeImage()
        }
    }

    /// CGImage → PNG-Datei.
    // ⚠️ VERIFIZIEREN: NSBitmapImageRep(cgImage:) kommt in keinem Spike vor (der Spike nutzt NSBitmapImageRep(data:)).
    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}
