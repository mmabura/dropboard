import AppKit
import QuartzCore
import DropboardCore

/// Layer-Baum des Boards, unabhängig von Fenster und View (wird gehostet oder offscreen gerendert).
/// Reihenfolge von unten (wie Spike board-paper): Papier (sheet), Noise, Abdunklung, Bilder.
///   root  – transparent, Hosted-Layer der View
///   clip  – Container fürs Realtime-Aufblättern/Zuklappen (masksToBounds + animierte bounds, P5; RealtimeMotion)
///   sheet – Papier; Ziel der Stop-Motion-Maske im Ansichtsmodus (StopMotionSheet)
/// Bilder und Platzhalter sind Standalone-CALayer mit hartem Schatten.
/// Koordinaten: Layer y nach oben; Board-Koordinaten (DropboardCore) y nach unten → `layerPoint`.
@MainActor
final class BoardScene {
    let root = CALayer()
    let sheet = CALayer()
    /// Clip-Container zwischen root und sheet (RealtimeMotion.clipName). Im Ruhezustand ohne Clipping.
    let clip = CALayer()
    private let noiseLayer = CALayer()
    private let dimLayer = CALayer()
    private let itemContainer = CALayer()
    private let noiseTile: CGImage?
    private(set) var size: CGSize = .zero
    private(set) var scale: CGFloat = 0
    private var itemLayers: [UUID: CALayer] = [:]
    /// C19: wird nach einem Wechsel des Backing-Scale aufgerufen (alt, neu). Noise wird hier neu gekachelt; der
    /// Aufrufer (BoardController) dekodiert damit die Bilder in der neuen Pixelgröße neu. Additiv, Standard nil.
    var onBackingScaleChange: ((_ old: CGFloat, _ new: CGFloat) -> Void)?

    init(size: CGSize, scale: CGFloat, noiseTile: CGImage?) {
        self.noiseTile = noiseTile
        withoutImplicitAnimations {
            root.name = "board.root"
            clip.name = RealtimeMotion.clipName
            clip.masksToBounds = false
            clip.anchorPoint = .zero
            sheet.name = "board.sheet"
            sheet.backgroundColor = PaperStyle.cgColor(PaperStyle.paperHex)  // flach, keine Vignette, kein Verlauf
            noiseLayer.name = "board.noise"
            noiseLayer.opacity = PaperStyle.noiseOpacity
            dimLayer.name = "board.dim"
            dimLayer.backgroundColor = PaperStyle.cgColor(PaperStyle.graphiteHex)   // Graphit, kein Schwarz
            dimLayer.opacity = PaperStyle.dimOpacity
            dimLayer.isHidden = true
            itemContainer.name = "board.items"
            sheet.addSublayer(noiseLayer)
            sheet.addSublayer(dimLayer)
            sheet.addSublayer(itemContainer)
            clip.addSublayer(sheet)
            root.addSublayer(clip)
        }
        resize(size: size, scale: scale)
        if noiseTile == nil {
            Log.line("[WIN]", "Noise-Textur nicht verfügbar, Papier bleibt flach")
        }
    }

    /// Größe/Backing-Scale setzen; die Noise wird nur bei Änderung neu gekachelt (einmal, statisch).
    /// C5: Item-Layer neu setzen. Ihre Layer-Position ist `layerPoint(center)` = (x, Höhe − y) mit der ALTEN Höhe;
    /// die Board-Koordinate (Modell, y nach unten) bleibt gleich, also wird jede Position um (neueHöhe − alteHöhe)
    /// verschoben – das ist exakt `layerPoint(center)` mit der neuen Höhe. Laufende Stop-Motion-Keyframes (absolute
    /// Werte in alten Koordinaten) werden beendet, der Layer zeigt den (verschobenen) Endzustand.
    /// C19: Bei geändertem Backing-Scale wird die Noise in der neuen Pixelgröße gekachelt (hier) und
    /// `onBackingScaleChange` gemeldet (Bilder neu dekodieren); das Eselsohr zeichnet BoardPresenter.updateEarArt neu.
    func resize(size newSize: CGSize, scale newScale: CGFloat) {
        let oldSize = size, oldScale = scale
        let changed = newSize != oldSize || newScale != oldScale
        size = newSize
        scale = newScale
        let bounds = CGRect(origin: .zero, size: newSize)
        let dy = oldSize == .zero ? 0 : newSize.height - oldSize.height
        withoutImplicitAnimations {
            // ⚠️ VERIFIZIEREN (aus Spike board-paper): bei Layer-Hosting setzt AppKit den Root-Frame nicht selbst.
            root.frame = bounds
            // Clip-Container: Ruhezustand (anchorPoint 0, position 0, bounds = Blatt) → Koordinaten wie root.
            clip.removeAllAnimations()
            clip.masksToBounds = false
            clip.anchorPoint = .zero
            clip.position = .zero
            clip.bounds = bounds
            sheet.frame = bounds
            noiseLayer.frame = bounds
            dimLayer.frame = bounds
            itemContainer.frame = bounds
            for layer in [root, clip, sheet, noiseLayer, dimLayer, itemContainer] { layer.contentsScale = newScale }
            for layer in itemLayers.values {
                layer.contentsScale = newScale
                if dy != 0 {
                    for key in layer.animationKeys() ?? [] where key.hasPrefix(StopMotion.keyPrefix) {
                        layer.removeAnimation(forKey: key)
                    }
                    layer.position = CGPoint(x: layer.position.x, y: layer.position.y + dy)
                }
            }
            if changed, let tile = noiseTile {
                noiseLayer.contents = PaperArt.tiledNoise(tile: tile, pixelSize: CGSize(width: newSize.width * newScale,
                                                                                       height: newSize.height * newScale))
            }
        }
        if oldScale != 0 && newScale != oldScale {
            Log.line("[WIN]", "Backing-Scale \(oldScale) → \(newScale): Noise neu gekachelt, Bilder neu dekodieren "
                + "(\(onBackingScaleChange == nil ? "kein Empfänger" : "gemeldet"))")
            onBackingScaleChange?(oldScale, newScale)
        }
    }

    /// Item-Layer aus dem Modell neu setzen (Board-Koordinaten, y nach unten). Additiv für Aufrufer, die das Dokument
    /// kennen (z. B. nach `resize`); `resize` selbst verschiebt schon um die Höhendifferenz.
    func relayoutItems(_ poses: [UUID: (center: CGPoint, rotation: Double)]) {
        StopMotion.batch {
            for (id, p) in poses {
                guard let layer = itemLayers[id] else { continue }
                for key in layer.animationKeys() ?? [] where key.hasPrefix(StopMotion.keyPrefix) {
                    layer.removeAnimation(forKey: key)
                }
                StopMotion.setModel(pose(center: p.center, rotation: p.rotation), on: layer)
            }
        }
    }

    /// Pixelgröße der aktuell gekachelten Noise (Selftest C19).
    var noisePixelSize: CGSize? {
        guard let contents = noiseLayer.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        let image = contents as! CGImage   // Typ oben geprüft
        return CGSize(width: image.width, height: image.height)
    }

    // MARK: Abdunklung (während eines Drags)

    var isDimmed: Bool { !dimLayer.isHidden }

    func setDimmed(_ dimmed: Bool) {
        guard dimmed != isDimmed else { return }
        withoutImplicitAnimations { dimLayer.isHidden = !dimmed }
    }

    // MARK: Koordinaten

    /// Board-Koordinaten (oben links, y nach unten) → Layer-Koordinaten (unten links, y nach oben).
    func layerPoint(_ boardPoint: CGPoint) -> CGPoint {
        CGPoint(x: boardPoint.x, y: size.height - boardPoint.y)
    }

    /// Endzustand eines Items als Pose für StopMotion (Rotation in Grad).
    func pose(center: CGPoint, rotation: Double) -> Pose {
        Pose(position: layerPoint(center), rotation: rotation)
    }

    // MARK: Items

    var itemCount: Int { itemLayers.count }

    func itemLayer(id: UUID) -> CALayer? { itemLayers[id] }

    /// Leeres Papier-Rechteck mit hartem Schatten, bis das Bild da ist. Pose setzt der Aufrufer
    /// (StopMotion.setModel oder StopMotion.apply) in derselben Transaktion.
    @discardableResult
    func addPlaceholder(id: UUID, size itemSize: CGSize) -> CALayer {
        let layer = makeItemLayer(id: id, size: itemSize)
        layer.backgroundColor = PaperStyle.cgColor(PaperStyle.placeholderHex)
        insert(layer, id: id)
        return layer
    }

    @discardableResult
    func addImage(id: UUID, image: CGImage, size itemSize: CGSize) -> CALayer {
        let layer = makeItemLayer(id: id, size: itemSize)
        layer.contents = image
        insert(layer, id: id)
        return layer
    }

    /// Platzhalter → Bild: hart eingesetzt, Mittelpunkt bleibt (Position/Transform werden nicht berührt,
    /// eine laufende Stop-Motion-Sequenz läuft weiter).
    func setImage(_ image: CGImage, size itemSize: CGSize, for id: UUID) {
        guard let layer = itemLayers[id] else { return }
        withoutImplicitAnimations {
            layer.backgroundColor = nil
            layer.contents = image
            layer.bounds = CGRect(origin: .zero, size: itemSize)
            layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)
        }
    }

    func removeItem(id: UUID) {
        guard let layer = itemLayers.removeValue(forKey: id) else { return }
        withoutImplicitAnimations { layer.removeFromSuperlayer() }
    }

    // MARK: Ansichtsmodus (Schritt 7)

    /// Auswahl-Hervorhebung ohne Systemblau: dünner Graphit-Rahmen auf dem Bild (ViewModeStyle).
    func setSelected(_ selected: Bool, id: UUID) {
        guard let layer = itemLayers[id] else { return }
        // ⚠️ VERIFIZIEREN: CALayer.borderWidth/borderColor kommen in keinem Spike vor; Rahmen liegt über dem Bild, dreht mit.
        withoutImplicitAnimations {
            layer.borderWidth = selected ? ViewModeStyle.selectionBorderWidth : 0
            layer.borderColor = selected
                ? PaperStyle.cgColor(PaperStyle.graphiteHex, alpha: ViewModeStyle.selectionBorderAlpha) : nil
        }
    }

    /// Gezogenes Bild nach oben legen und laufende Stop-Motion-Sequenzen beenden, damit es der Maus
    /// direkt folgt (Model-Wert = sichtbarer Wert, keine Keyframes, kein Jitter).
    func beginDirectManipulation(id: UUID) {
        guard let layer = itemLayers[id] else { return }
        withoutImplicitAnimations {
            layer.removeAllAnimations()   // ⚠️ VERIFIZIEREN (nicht aus einem Spike): beendet laufende sm.-Keyframes sofort
            layer.removeFromSuperlayer()
            itemContainer.addSublayer(layer)
        }
    }

    private func insert(_ layer: CALayer, id: UUID) {
        itemLayers[id]?.removeFromSuperlayer()
        itemLayers[id] = layer
        withoutImplicitAnimations { itemContainer.addSublayer(layer) }
    }

    /// Bild-Layer wie Spike board-paper: harter Schatten (Radius 0, expliziter Pfad), Kantenglättung bei Rotation.
    private func makeItemLayer(id: UUID, size itemSize: CGSize) -> CALayer {
        let layer = CALayer()
        layer.name = "item.\(id.uuidString)"
        layer.bounds = CGRect(origin: .zero, size: itemSize)
        layer.contentsScale = scale
        layer.allowsEdgeAntialiasing = true   // ⚠️ VERIFIZIEREN (V14, aus Spike)
        layer.shadowColor = PaperStyle.cgColor(PaperStyle.graphiteHex)
        layer.shadowOpacity = PaperStyle.shadowOpacity
        layer.shadowRadius = PaperStyle.shadowRadius
        layer.shadowOffset = PaperStyle.shadowOffset   // ⚠️ VERIFIZIEREN (V13/V14, aus Spike): Richtung bei y-up
        layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)
        // Doppelt gesichert gegen implizite Animationen (Report 03, Abschnitt 3, Wege 1 und 2).
        let null = NSNull()
        layer.actions = ["position": null, "bounds": null, "transform": null, "opacity": null,
                         "contents": null, "hidden": null, "onOrderIn": null, "onOrderOut": null, "sublayers": null,
                         "backgroundColor": null, "shadowPath": null, "shadowOpacity": null,
                         "shadowOffset": null, "shadowRadius": null, "shadowColor": null,
                         "borderWidth": null, "borderColor": null]
        return layer
    }
}
