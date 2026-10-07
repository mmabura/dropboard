import AppKit
import ImageIO
import DropboardCore

/// Fertig auf Anzeigegröße gerendertes Bild. Unveränderlich, darf deshalb zwischen Queues wandern.
final class DecodedImage: @unchecked Sendable {
    let cgImage: CGImage   // Pixelgröße ≈ size × Backing-Scale (Thumbnail, nie größer als die Quelle)
    let size: CGSize       // Anzeigegröße in pt, EXIF-orientiert

    init(cgImage: CGImage, size: CGSize) {
        self.cgImage = cgImage
        self.size = size
    }
}

/// Ergebnis eines Drop-Imports aus der Hintergrund-Queue (`ImageDecoder.importInBackground`).
struct ImportOutcome: Sendable {
    /// nil + error nil = Datei/Daten sind kein lesbares Bild
    let image: DecodedImage?
    /// Sichern (Kopieren/Schreiben/Verschieben) fehlgeschlagen
    let error: String?
    let prepareMs: String
    let decodeMs: String
}

/// Bild lesen und auf Board-Größe bringen. Nicht an einen Actor gebunden: läuft auf Hintergrund-Queues.
/// P4/C7/C8: ImageIO-Thumbnail-Weg statt Voll-Dekodieren + Herunterzeichnen:
///   kCGImageSourceCreateThumbnailFromImageAlways   – nie ein eingebettetes (evtl. winziges/ungedrehtes) Vorschaubild
///   kCGImageSourceThumbnailMaxPixelSize            – längste Kante = Anzeigegröße × Backing-Scale
///   kCGImageSourceCreateThumbnailWithTransform     – EXIF-Orientierung anwenden (C7)
enum ImageDecoder {
    enum Priority {
        /// Drop: serielle Queue, .userInitiated (B2: das gerade abgelegte Bild zuerst)
        case drop
        /// Laden beim Start: höchstens `startupConcurrency` gleichzeitig, .utility
        case startup
    }

    static let startupConcurrency = 3

    /// Drops: Sichern (Kopieren/Schreiben) UND Dekodieren, seriell in Drop-Reihenfolge.
    static let importQueue = DispatchQueue(label: "Dropboard.import", qos: .userInitiated)

    /// Start (P4/C8): begrenzte Parallelität statt eines GCD-Blocks pro Item.
    static let startupQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Dropboard.startupDecode"
        queue.maxConcurrentOperationCount = ImageDecoder.startupConcurrency
        queue.qualityOfService = .utility
        return queue
    }()

    /// `size == nil`: längste Kante = LayoutMetrics.standard.longestEdge. Sonst `size` (gespeichertes Item),
    /// außer das Seitenverhältnis passt nicht zur orientierten Pixelgröße (alter Eintrag ohne EXIF-Drehung, C7):
    /// dann die korrigierte Größe (BoardLayout.reconciledSize). Der Aufrufer vergleicht `DecodedImage.size`.
    static func decode(url: URL, size: CGSize?, scale: CGFloat) -> DecodedImage? {
        // ⚠️ VERIFIZIEREN: kCGImageSourceShouldCache=false verhindert, dass die Quelle die Voll-Bitmap cached.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return decode(source: source, size: size, scale: scale)
    }

    /// Wie `decode(url:)`, aber aus Daten im Speicher (Weg imageData, Vorschau vor dem Schreiben – B2).
    static func decode(data: Data, size: CGSize?, scale: CGFloat) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return decode(source: source, size: size, scale: scale)
    }

    static func decode(source: CGImageSource, size: CGSize?, scale: CGFloat) -> DecodedImage? {
        guard CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        // ⚠️ VERIFIZIEREN: PixelWidth/Height sind die gespeicherten (ungedrehten) Maße; kCGImagePropertyOrientation
        // steht für JPEG/HEIC/TIFF auf oberster Ebene der Eigenschaften (1…8, fehlt = 1).
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let oriented = BoardLayout.orientedPixelSize(width: rawWidth, height: rawHeight, orientation: orientation)

        let target: CGSize
        if let size = size, size.width > 0, size.height > 0 {
            target = BoardLayout.reconciledSize(stored: size, orientedPixelWidth: oriented.width,
                                                orientedPixelHeight: oriented.height)
        } else if let fitted = BoardLayout.fittedSize(pixelWidth: oriented.width, pixelHeight: oriented.height,
                                                      longestEdge: LayoutMetrics.standard.longestEdge) {
            target = fitted
        } else {
            return nil
        }
        let maxPixel = max(1, Int((max(target.width, target.height) * scale).rounded(.up)))
        // ⚠️ VERIFIZIEREN: kCGImageSourceShouldCacheImmediately dekodiert hier (Hintergrund) statt lazy beim
        // ersten Rendern auf dem Main Thread. Thumbnails werden nie über die Quellgröße hinaus vergrößert;
        // der Layer skaliert dann (contentsGravity .resize).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DecodedImage(cgImage: thumbnail, size: target)
    }

    /// Bilddaten (z. B. TIFF aus dem Browser) als PNG schreiben, Orientierung in die Pixel eingerechnet
    /// (Thumbnail ohne MaxPixelSize = volle Größe). Läuft nur auf der importQueue, nie auf dem Main Thread.
    static func writePNG(from data: Data, to url: URL) throws {
        // ⚠️ VERIFIZIEREN: ohne kCGImageSourceThumbnailMaxPixelSize liefert ImageIO das Bild in voller Größe.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw ImageWriteError(message: "Bilddaten nicht lesbar oder PNG-Ziel nicht anlegbar") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ImageWriteError(message: "PNG schreiben fehlgeschlagen")
        }
    }

    struct ImageWriteError: Error, CustomStringConvertible, LocalizedError {
        let message: String
        var description: String { message }
        var errorDescription: String? { message }
    }

    /// Dekodiert im Hintergrund und liefert das Ergebnis auf dem Main Actor. Zweiter Parameter: Dauer in ms.
    /// `.startup`: startupQueue (max. 3 parallel, .utility). `.drop`: importQueue (seriell, .userInitiated).
    // ⚠️ VERIFIZIEREN: OperationQueue.addOperation mit @Sendable-Block + Task { @MainActor } wie bisher bei GCD;
    // erwartet: im Swift-5-Modus keine Sendable-Warnung (alle Captures sind Sendable).
    static func decodeInBackground(url: URL, size: CGSize?, scale: CGFloat, priority: Priority = .drop,
                                   completion: @escaping @MainActor @Sendable (DecodedImage?, String) -> Void) {
        let work: @Sendable () -> Void = {
            let start = Log.now
            let decoded = ImageDecoder.decode(url: url, size: size, scale: scale)
            let elapsed = Log.ms(since: start)
            Task { @MainActor in
                completion(decoded, elapsed)
            }
        }
        switch priority {
        case .drop: importQueue.async(execute: work)
        case .startup: startupQueue.addOperation(work)
        }
    }

    /// Drop-Import auf der importQueue (P2/P3/C15), Reihenfolge:
    ///   1. `data != nil` (Weg imageData): sofort aus den Daten dekodieren und als Vorschau an den Main Actor (B2),
    ///      noch bevor die Datei geschrieben ist. Nicht lesbar → Ergebnis ohne Bild, `prepare` läuft nicht.
    ///   2. `prepare`: Datei nach `target` sichern (Kopie, Schreiben, Verschieben; bei Klon/Sync-Kopie leer).
    ///   3. `data == nil`: `target` dekodieren.
    ///   4. Ergebnis an den Main Actor.
    static func importInBackground(target: URL, data: Data?, scale: CGFloat,
                                   prepare: @escaping @Sendable () throws -> Void,
                                   preview: @escaping @MainActor @Sendable (DecodedImage) -> Void,
                                   completion: @escaping @MainActor @Sendable (ImportOutcome) -> Void) {
        importQueue.async {
            var decoded: DecodedImage?
            var decodeMs = "0.0"
            if let data = data {
                let t = Log.now
                decoded = ImageDecoder.decode(data: data, size: nil, scale: scale)
                decodeMs = Log.ms(since: t)
                guard let early = decoded else {
                    let outcome = ImportOutcome(image: nil, error: nil, prepareMs: "0.0", decodeMs: decodeMs)
                    Task { @MainActor in completion(outcome) }
                    return
                }
                Task { @MainActor in preview(early) }
            }
            let tp = Log.now
            do {
                try prepare()
            } catch {
                try? FileManager.default.removeItem(at: target)
                let outcome = ImportOutcome(image: nil, error: error.localizedDescription,
                                            prepareMs: Log.ms(since: tp), decodeMs: decodeMs)
                Task { @MainActor in completion(outcome) }
                return
            }
            let prepareMs = Log.ms(since: tp)
            if data == nil {
                let t = Log.now
                decoded = ImageDecoder.decode(url: target, size: nil, scale: scale)
                decodeMs = Log.ms(since: t)
            }
            let outcome = ImportOutcome(image: decoded, error: nil, prepareMs: prepareMs, decodeMs: decodeMs)
            Task { @MainActor in completion(outcome) }
        }
    }
}
