import AppKit
import ImageIO
import DropboardCore

/// Fertig auf Anzeigegröße gerendertes Bild. Unveränderlich, darf deshalb zwischen Queues wandern.
final class DecodedImage: @unchecked Sendable {
    let cgImage: CGImage   // Pixelgröße = size × Backing-Scale
    let size: CGSize       // Anzeigegröße in pt

    init(cgImage: CGImage, size: CGSize) {
        self.cgImage = cgImage
        self.size = size
    }
}

/// Bild lesen und auf Board-Größe rendern (Muster aus Spike board-paper, ImageLibrary.fit).
/// Nicht an einen Actor gebunden: läuft auf einer Hintergrund-Queue.
enum ImageDecoder {
    /// `size == nil`: längste Kante = LayoutMetrics.standard.longestEdge. Sonst genau `size` (gespeichertes Item).
    /// ⚠️ Bekannte Lücke: EXIF-Orientierung wird nicht ausgewertet (wie im Spike).
    static func decode(url: URL, size: CGSize?, scale: CGFloat) -> DecodedImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let target: CGSize
        if let size = size, size.width > 0, size.height > 0 {
            target = size
        } else if let fitted = BoardLayout.fittedSize(pixelWidth: image.width, pixelHeight: image.height,
                                                      longestEdge: LayoutMetrics.standard.longestEdge) {
            target = fitted
        } else {
            return nil
        }
        let pw = max(1, Int((target.width * scale).rounded()))
        let ph = max(1, Int((target.height * scale).rounded()))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        guard let out = ctx.makeImage() else { return nil }
        return DecodedImage(cgImage: out, size: target)
    }

    /// Dekodiert auf einer Hintergrund-Queue und liefert das Ergebnis auf dem Main Actor
    /// (Muster wie afterDelay im Spike stopmotion: Task { @MainActor in … }). Zweiter Parameter: Dauer in ms.
    // ⚠️ VERIFIZIEREN: DispatchQueue.global().async mit @MainActor-@Sendable-Completion kommt so in keinem Spike vor
    // (dort nur asyncAfter bzw. Task); erwartet: im Swift-5-Modus keine Sendable-Warnung (alle Captures sind Sendable).
    static func decodeInBackground(url: URL, size: CGSize?, scale: CGFloat,
                                   completion: @escaping @MainActor @Sendable (DecodedImage?, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Log.now
            let decoded = ImageDecoder.decode(url: url, size: size, scale: scale)
            let elapsed = Log.ms(since: start)
            Task { @MainActor in
                completion(decoded, elapsed)
            }
        }
    }
}
