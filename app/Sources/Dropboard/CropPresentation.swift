import AppKit
import QuartzCore
import DropboardCore

/// Look des Beschnittmodus (E11): warmes Graphit statt Schwarz, Papier-Griffe, keine Systemblau-Akzente.
enum CropStyle {
    /// Ursprung von `CALayer.contentsRect` bei CGImage-Contents in einem NICHT geflippten Layer (macOS).
    /// Annahme: Einheitskoordinaten folgen der Layer-Geometrie (macOS: unten links, y nach oben) – wie anchorPoint.
    /// ⚠️ VERIFIZIEREN: Selftest `crop: contentsRect …` rendert einen Layer per CALayer.render(in:) in eine Bitmap und
    /// meldet den tatsächlichen Ursprung. Steht dort FAIL, diese Konstante umstellen. Sichtprüfung: Snapshot
    /// `--snapshot-demo` (das beschnittene Demo-Bild zeigt den oberen linken Teil, siehe README „Beschnitt“).
    static let contentsRectOriginTop = false

    /// Abdunklung des Bildes außerhalb des Rahmens: warmes Umbra (v1: PaperStyle.graphiteHex 0x3A2E22 bei 0,55 – wirkte
    /// über blauen/lila Bildteilen kühl-schiefergrau). Jetzt brauner und etwas schwächer, passend zum abgedunkelten Papier.
    /// Über Stahlblau 0x7C8DA8 ergibt das ≈ #766B69 (R > B, warm) statt v1 ≈ #585A5E (B > R, kühl).
    static let outsideHex: UInt32 = 0x704A2A
    static let outsideOpacity: Float = 0.5
    /// Rahmen: 1 pt Graphit.
    static let frameWidth: CGFloat = 1
    static let frameAlpha: CGFloat = 1
    /// Griffe: kleine Quadrate in Papierfarbe mit Graphit-Kante.
    static let handleSize: CGFloat = 8
    static let handleBorderWidth: CGFloat = 1
    /// Treffer-Toleranz um einen Griff (pt). Kleiner als die halbe Mindestgröße (24 pt) → Ecken und Kanten trennbar.
    static let handleHitTolerance: Double = 10
}

/// Overlay über dem Bild im Beschnittmodus: 4 Abdunkel-Streifen um den Rahmen, der Rahmen, 8 Griffe.
/// Liegt als Sublayer IM Item-Layer (Item-lokale Koordinaten, y nach oben wie jeder Layer hier), dreht und bewegt sich
/// also mit dem Bild (auch in den Stop-Motion-Frames beim Öffnen). Der Schatten des Items bleibt unberührt
/// (expliziter shadowPath).
@MainActor
final class CropOverlay {
    static let name = "crop.overlay"

    let container = CALayer()
    private let dims: [CALayer]          // oben, unten, links, rechts
    private let border = CALayer()
    private var handles: [CropHandle: CALayer] = [:]

    init(scale: CGFloat) {
        let null = NSNull()
        let actions: [String: CAAction] = ["position": null, "bounds": null, "frame": null, "hidden": null,
                                           "opacity": null, "sublayers": null, "onOrderIn": null, "onOrderOut": null,
                                           "backgroundColor": null, "borderWidth": null, "borderColor": null]
        func make(_ name: String) -> CALayer {
            let l = CALayer()
            l.name = name
            l.actions = actions
            l.contentsScale = scale
            return l
        }
        dims = (0..<4).map { _ in make("crop.dim") }
        container.name = CropOverlay.name
        container.actions = actions
        container.contentsScale = scale
        withoutImplicitAnimations {
            for d in dims {
                d.backgroundColor = PaperStyle.cgColor(CropStyle.outsideHex)
                d.opacity = CropStyle.outsideOpacity
                container.addSublayer(d)
            }
            border.name = "crop.frame"
            border.actions = actions
            border.contentsScale = scale
            // ⚠️ VERIFIZIEREN: wie die Auswahl (setSelected) – borderWidth/borderColor liegen innen am Rand des Layers.
            border.borderWidth = CropStyle.frameWidth
            border.borderColor = PaperStyle.cgColor(PaperStyle.graphiteHex, alpha: CropStyle.frameAlpha)
            container.addSublayer(border)
            for h in CropHandle.allCases {
                let l = make("crop.handle.\(h.rawValue)")
                l.backgroundColor = PaperStyle.cgColor(PaperStyle.paperHex)
                l.borderWidth = CropStyle.handleBorderWidth
                l.borderColor = PaperStyle.cgColor(PaperStyle.graphiteHex)
                l.bounds = CGRect(x: 0, y: 0, width: CropStyle.handleSize, height: CropStyle.handleSize)
                container.addSublayer(l)
                handles[h] = l
            }
        }
    }

    /// Rahmen eines Crops in Item-lokalen Layer-Koordinaten (y nach oben, Ursprung unten links des ganzen Bildes).
    static func frameRect(fullSize f: CGSize, crop c: BoardCrop) -> CGRect {
        CGRect(x: CGFloat(c.x) * f.width, y: CGFloat(1 - c.y - c.height) * f.height,
               width: CGFloat(c.width) * f.width, height: CGFloat(c.height) * f.height)
    }

    /// Alles direkt setzen (keine Animation): wird bei jedem Maus-Ereignis aufgerufen.
    func layout(fullSize f: CGSize, crop: BoardCrop) {
        let r = CropOverlay.frameRect(fullSize: f, crop: crop)
        withoutImplicitAnimations {
            container.frame = CGRect(origin: .zero, size: f)
            dims[0].frame = CGRect(x: 0, y: r.maxY, width: f.width, height: max(0, f.height - r.maxY))   // oben
            dims[1].frame = CGRect(x: 0, y: 0, width: f.width, height: max(0, r.minY))                    // unten
            dims[2].frame = CGRect(x: 0, y: r.minY, width: max(0, r.minX), height: r.height)              // links
            dims[3].frame = CGRect(x: r.maxX, y: r.minY, width: max(0, f.width - r.maxX), height: r.height) // rechts
            border.frame = r
            for (h, layer) in handles {
                let p = h.relativePosition   // u: 0 links … 1 rechts, v: 0 oben … 1 unten
                layer.position = CGPoint(x: r.minX + CGFloat(p.u) * r.width, y: r.maxY - CGFloat(p.v) * r.height)
            }
        }
    }

    /// Fürs Selftest: Rahmen und Griffmitten in lokalen Layer-Koordinaten.
    var frameLayerRect: CGRect { border.frame }
    func handleCenter(_ h: CropHandle) -> CGPoint? { handles[h]?.position }
    var dimFrames: [CGRect] { dims.map { $0.frame } }
}
