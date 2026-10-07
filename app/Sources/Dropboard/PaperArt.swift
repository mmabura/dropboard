import AppKit
import ImageIO
import DropboardCore

/// Vorgerenderte Bitmaps: Noise-Kachel, gekachelte Noise, Eselsohr, Demo-Platzhalterbilder.
/// Alles wird einmal erzeugt (bzw. bei Größen-/Backing-Scale-Wechsel neu) und als `contents` statischer Layer gesetzt
/// (kein Zeichnen zur Laufzeit).
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

    /// Geometrie des Eselsohrs in Pixeln, immer für `.topRight` (Bitmap-Kontext, y nach oben). Rein, für den Selftest.
    ///   front – Vorderseite: Quadrat ohne die weggeknickte Ecke oben rechts (Fünfeck)
    ///   flap  – Lasche: Spiegelbild der weggeknickten Ecke an der Falzlinie, liegt auf der Vorderseite;
    ///           der rechte Winkel zeigt zur Mitte des Stücks (bzw. des Bildschirms)
    ///   fold  – Falzlinie von der Oberkante zur rechten Kante
    struct EarShape {
        let front: [CGPoint]
        let flap: [CGPoint]
        let fold: (CGPoint, CGPoint)
        /// Außenkanten der Vorderseite ohne Falz (offener Pfad, im Uhrzeigersinn ab Falz-Oberkante)
        let outerEdges: [CGPoint]
        /// Die beiden freien Kanten der Lasche (offener Pfad)
        let flapFreeEdges: [CGPoint]
    }

    static func earGeometry(pixelWidth W: CGFloat, pixelHeight H: CGFloat,
                            foldFraction: CGFloat = PaperStyle.earFoldFraction) -> EarShape {
        let fw = (W * foldFraction).rounded(), fh = (H * foldFraction).rounded()
        let foldTop = CGPoint(x: W - fw, y: H), foldRight = CGPoint(x: W, y: H - fh)
        let flapCorner = CGPoint(x: W - fw, y: H - fh)   // Spiegelbild von (W, H) an der Falzlinie
        return EarShape(
            front: [CGPoint(x: 0, y: 0), CGPoint(x: W, y: 0), foldRight, foldTop, CGPoint(x: 0, y: H)],
            flap: [foldTop, foldRight, flapCorner],
            fold: (foldTop, foldRight),
            outerEdges: [foldTop, CGPoint(x: 0, y: H), CGPoint(x: 0, y: 0), CGPoint(x: W, y: 0), foldRight],
            flapFreeEdges: [foldTop, flapCorner, foldRight])
    }

    /// Eselsohr (Fix C): ein kleines Stück Papier, dessen äußere Ecke diagonal umgeknickt ist.
    /// Vorderseite = Board-Papier (paperHex + dieselbe Noise-Kachel, 1:1 in Device-Pixeln), Lasche = Rückseite
    /// (earBackHex, minimal dunkler/kühler) mit derselben Noise; der weggeknickte Eckbereich ist transparent.
    /// Linien je 1 Device-Pixel: Haarlinie innen an den Außenkanten (Lesbarkeit auf hellem Hintergrund), Haarlinie an den
    /// freien Laschenkanten, Falzlinie. Kein Schatten, kein Verlauf.
    /// Gezeichnet wird für `.topRight`; für die anderen Ecken wird der Kontext gespiegelt (links: x, unten: y), damit die
    /// weggeknickte Ecke zur Bildschirmecke und der rechte Winkel der Lasche zur Bildschirmmitte zeigt.
    /// Rastervorschau derselben Geometrie vorab in Python geprüft (helle/graue/blaue/dunkle Hintergründe).
    // ⚠️ VERIFIZIEREN: CGMutablePath, clip(), strokePath() und setAlpha() kommen in keinem Spike vor
    // (Standard-CoreGraphics). Prüfen per `--snapshot`: Datei `<pfad>-ear.png` (Ecke oben rechts transparent, Lasche
    // als Dreieck mit rechtem Winkel unten links auf der Vorderseite, Falz von Oberkante zur rechten Kante).
    // ⚠️ VERIFIZIEREN: Spiegeln per translateBy/scaleBy(-1) vor dem Zeichnen (auch die gekachelte Noise wird
    // gespiegelt – unkritisch). Prüfen: `--snapshot` mit gesetzter Ecke (`defaults write … dropboard.corner bottomLeft`).
    static func earImage(size: CGSize, scale: CGFloat, noiseTile: CGImage?, corner: EarCorner = .topRight) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let W = CGFloat(w), H = CGFloat(h)
        let g = earGeometry(pixelWidth: W, pixelHeight: H)

        // Bitmap-Kontext: y nach oben. Links → horizontal spiegeln, unten → vertikal spiegeln.
        ctx.translateBy(x: corner.isRight ? 0 : W, y: corner.isTop ? 0 : H)
        ctx.scaleBy(x: corner.isRight ? 1 : -1, y: corner.isTop ? 1 : -1)

        func path(_ pts: [CGPoint], closed: Bool) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts)   // ⚠️ VERIFIZIEREN: CGMutablePath.addLines(between:) (Swift-Overlay), nicht aus einem Spike
            if closed { p.closeSubpath() }
            return p
        }
        let full = CGRect(x: 0, y: 0, width: W, height: H)

        /// Fläche füllen, Noise darüber, dann `edges` als Haarlinie (Strichbreite 2 px, per Clip bleibt 1 px innen).
        func paperSurface(_ shape: CGPath, fillHex: UInt32, edges: CGPath, edgeAlpha: CGFloat) {
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.setFillColor(PaperStyle.cgColor(fillHex))
            ctx.fill(full)
            if let tile = noiseTile {
                ctx.setAlpha(CGFloat(PaperStyle.noiseOpacity))
                ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height), byTiling: true)
                ctx.setAlpha(1)
            }
            ctx.addPath(edges)
            ctx.setStrokeColor(PaperStyle.cgColor(PaperStyle.graphiteHex, alpha: edgeAlpha))
            ctx.setLineWidth(2)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 1) Vorderseite (gleiches Papier wie das Board)
        paperSurface(path(g.front, closed: true), fillHex: PaperStyle.paperHex,
                     edges: path(g.outerEdges, closed: false), edgeAlpha: PaperStyle.earEdgeAlpha)
        // 2) Lasche = Rückseite, liegt auf der Vorderseite
        paperSurface(path(g.flap, closed: true), fillHex: PaperStyle.earBackHex,
                     edges: path(g.flapFreeEdges, closed: false), edgeAlpha: PaperStyle.earFlapEdgeAlpha)
        // 3) Falzlinie (1 Device-Pixel)
        ctx.addPath(path([g.fold.0, g.fold.1], closed: false))
        ctx.setStrokeColor(PaperStyle.cgColor(PaperStyle.graphiteHex, alpha: PaperStyle.earFoldAlpha))
        ctx.setLineWidth(1)
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

    /// Beschnitt-Demo (E11, `--snapshot-demo`): 600×400 px in vier Feldern, oben links Terrakotta, oben rechts Senf,
    /// unten links Stahlblau, unten rechts Flieder (gedämpft). So zeigt der Snapshot, welcher Teil beschnitten wurde und
    /// ob contentsRect richtig herum liegt.
    static func demoCropImage() -> CGImage? {
        let pw = 600, ph = 400
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(pw) / 2, h = CGFloat(ph) / 2
        // Zeichen-Kontext: y nach oben → obere Bildhälfte = y ab h.
        let fields: [(UInt32, CGRect)] = [
            (0xC48B7A, CGRect(x: 0, y: h, width: w, height: h)),   // oben links
            (0xB8A86B, CGRect(x: w, y: h, width: w, height: h)),   // oben rechts
            (0x7C8DA8, CGRect(x: 0, y: 0, width: w, height: h)),   // unten links
            (0x9A7F9E, CGRect(x: w, y: 0, width: w, height: h)),   // unten rechts
        ]
        for (hex, rect) in fields {
            ctx.setFillColor(PaperStyle.cgColor(hex))
            ctx.fill(rect)
        }
        return ctx.makeImage()
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
