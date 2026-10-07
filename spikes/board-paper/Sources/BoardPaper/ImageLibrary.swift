import AppKit
import ImageIO

/// Ein fertig auf Anzeigegroesse skaliertes Bild.
struct PlacedImage {
    let cgImage: CGImage   // Pixelgroesse = size * Backing-Scale
    let size: CGSize       // Groesse in pt, laengste Kante = PaperStyle.imageLongestEdge
}

enum ImageLibrary {
    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "bmp"]

    /// Laedt Bilder aus einem Ordner (nach Dateiname sortiert). Leer, wenn nichts lesbar ist.
    static func load(folder: String, scale: CGFloat) -> [PlacedImage] {
        let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.sorted()
            .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .compactMap { name -> PlacedImage? in
                let fileURL = url.appendingPathComponent(name)
                guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                return fit(img, scale: scale)
            }
    }

    /// 6 einfarbige Platzhalter in gedaempften Farben und verschiedenen Seitenverhaeltnissen.
    static func placeholders(scale: CGFloat) -> [PlacedImage] {
        let specs: [(UInt32, CGFloat, CGFloat)] = [
            (0x8FA3A0, 3, 2),   // Salbei-Graublau
            (0xC48B7A, 2, 3),   // gedaempftes Terrakotta
            (0xB8A86B, 1, 1),   // Senf, gedaempft
            (0x7C8DA8, 4, 3),   // Stahlblau, gedaempft
            (0x9A7F9E, 16, 9),  // Staubflieder
            (0x7FA07A, 3, 4)    // Moosgruen, gedaempft
        ]
        return specs.compactMap { spec -> PlacedImage? in
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
            guard let img = ctx.makeImage() else { return nil }
            return fit(img, scale: scale)
        }
    }

    /// Skaliert so, dass die laengste Kante PaperStyle.imageLongestEdge pt misst (Seitenverhaeltnis erhalten),
    /// und rendert direkt in Pixelgroesse (size * scale), damit der Layer 1:1 anzeigt.
    static func fit(_ image: CGImage, scale: CGFloat) -> PlacedImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return nil }
        let k = PaperStyle.imageLongestEdge / max(w, h)
        let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let pw = max(1, Int((size.width * scale).rounded()))
        let ph = max(1, Int((size.height * scale).rounded()))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        guard let out = ctx.makeImage() else { return nil }
        return PlacedImage(cgImage: out, size: size)
    }

    /// Laedt die PNG-Kachel aus dem Bundle.
    static func loadNoiseTile() -> CGImage? {
        guard let url = Bundle.module.url(forResource: "noise", withExtension: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Kachelt die PNG einmal auf Pixelgroesse (Report 03, Abschnitt 7, Option 1).
    /// Kachel wird 1:1 in Device-Pixeln gezeichnet (Kontext ist pixelgross, keine CTM-Skalierung).
    static func tiledNoise(tile: CGImage, pixelSize: CGSize) -> CGImage? {
        let w = Int(pixelSize.width.rounded(.up)), h = Int(pixelSize.height.rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),  // ⚠️ VERIFIZIEREN: 8-bit Gray ohne Alpha als Bitmap-Kontext
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height), byTiling: true)
        return ctx.makeImage()
    }
}
