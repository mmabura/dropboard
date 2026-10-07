import AppKit
import QuartzCore

/// Layer-hosting View (Report 03, Abschnitt 3): eigener Root-Layer wird gesetzt, DANACH wantsLayer = true.
/// Keine Subviews. Alle Inhalte sind Standalone-CALayer.
/// Layer-Reihenfolge von unten: Papier, Noise, Abdunklung, Bilder, Hilfezeile.
final class BoardView: NSView {
    private let scale: CGFloat
    private let images: [PlacedImage]
    private var nextImageIndex = 0

    private let rootLayer = CALayer()
    private let noiseLayer = CALayer()
    private let dimLayer = CALayer()
    private let imageContainer = CALayer()
    private var dimmed = false
    private var noiseOn = true

    init(frame: NSRect, scale: CGFloat, noiseTile: CGImage?, images: [PlacedImage]) {
        self.scale = scale
        self.images = images
        super.init(frame: frame)

        let bounds = CGRect(origin: .zero, size: frame.size)

        // Reihenfolge ist entscheidend: erst layer setzen, dann wantsLayer.
        rootLayer.frame = bounds   // ⚠️ VERIFIZIEREN: bei Layer-Hosting setzt AppKit den Root-Layer-Frame nicht selbst
        rootLayer.contentsScale = scale
        layer = rootLayer
        wantsLayer = true

        withoutImplicitAnimations {
            // Papier: flaches Off-White, keine Vignette, kein Verlauf.
            rootLayer.backgroundColor = PaperStyle.cgColor(PaperStyle.paperHex)

            // Noise: einmal auf Bildschirm-Pixelgroesse vorgekachelt.
            noiseLayer.frame = bounds
            noiseLayer.contentsScale = scale
            noiseLayer.opacity = PaperStyle.noiseOpacity
            if let tile = noiseTile,
               let tiled = ImageLibrary.tiledNoise(tile: tile,
                                                   pixelSize: CGSize(width: bounds.width * scale,
                                                                     height: bounds.height * scale)) {
                noiseLayer.contents = tiled
            } else {
                FileHandle.standardError.write(Data("Noise-Textur nicht verfuegbar, Papier bleibt flach.\n".utf8))
            }
            rootLayer.addSublayer(noiseLayer)

            // Abdunklung: Graphit ueber dem Papier (kein Schwarz).
            dimLayer.frame = bounds
            dimLayer.backgroundColor = PaperStyle.cgColor(PaperStyle.graphiteHex)
            dimLayer.opacity = PaperStyle.dimOpacity
            dimLayer.isHidden = true
            rootLayer.addSublayer(dimLayer)

            imageContainer.frame = bounds
            rootLayer.addSublayer(imageContainer)

            rootLayer.addSublayer(makeHelpLayer())
        }
    }

    required init?(coder: NSCoder) { fatalError("nicht verwendet") }

    // MARK: Hilfezeile

    private func makeHelpLayer() -> CATextLayer {
        let text = CATextLayer()
        text.string = NSAttributedString(string: PaperStyle.helpText, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: PaperStyle.helpFontSize, weight: .regular),
            .foregroundColor: PaperStyle.nsColor(PaperStyle.graphiteHex)
        ])  // ⚠️ VERIFIZIEREN: CATextLayer rendert NSAttributedString mit NSFont/NSColor-Attributen
        text.contentsScale = scale
        text.alignmentMode = .left
        text.frame = CGRect(x: PaperStyle.helpInset.x, y: PaperStyle.helpInset.y, width: 640, height: 18)
        return text
    }

    // MARK: Bilder ablegen

    /// Legt das naechste Bild an `point` (View-Koordinaten, y nach oben) ab: gesnappt, rotiert, hart eingeblendet.
    private func placeNextImage(at point: CGPoint) {
        guard !images.isEmpty else { return }
        let item = images[nextImageIndex % images.count]
        nextImageIndex += 1

        let grid = PaperStyle.snapGrid
        let center = CGPoint(x: (point.x / grid).rounded() * grid,
                             y: (point.y / grid).rounded() * grid)
        let degrees = Double.random(in: PaperStyle.rotationDegreesRange) * (Bool.random() ? 1 : -1)
        let radians = CGFloat(degrees * .pi / 180)

        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: item.size)
        layer.position = center
        layer.contents = item.cgImage
        layer.contentsScale = scale
        layer.transform = CATransform3DMakeRotation(radians, 0, 0, 1)
        layer.allowsEdgeAntialiasing = true

        // Harter Schatten: Radius 0, kleiner Versatz nach unten rechts, expliziter Pfad.
        layer.shadowColor = PaperStyle.cgColor(PaperStyle.graphiteHex)
        layer.shadowOpacity = PaperStyle.shadowOpacity
        layer.shadowRadius = PaperStyle.shadowRadius
        layer.shadowOffset = PaperStyle.shadowOffset  // ⚠️ VERIFIZIEREN (V13/V14): Richtung bei y-up; dreht der Offset mit der Layer-Rotation mit?
        layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)

        // Doppelt gesichert gegen implizite Animationen (Report 03, Abschnitt 3, Wege 1 und 2).
        let null = NSNull()
        layer.actions = ["position": null, "bounds": null, "transform": null, "opacity": null,
                         "contents": null, "hidden": null, "onOrderIn": null, "sublayers": null,
                         "shadowPath": null, "shadowOpacity": null, "shadowOffset": null,
                         "shadowRadius": null, "shadowColor": null]

        withoutImplicitAnimations {
            imageContainer.addSublayer(layer)
        }
    }

    // MARK: Eingabe

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        placeNextImage(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            NSApp.terminate(nil)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "d":
            dimmed.toggle()
            withoutImplicitAnimations { dimLayer.isHidden = !dimmed }
        case "n":
            noiseOn.toggle()
            withoutImplicitAnimations { noiseLayer.isHidden = !noiseOn }
        default:
            super.keyDown(with: event)
        }
    }
}
