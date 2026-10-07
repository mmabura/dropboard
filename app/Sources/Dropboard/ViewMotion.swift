import AppKit
import QuartzCore
import DropboardCore

// Stop-Motion-Pfad für das Board-Blatt im Ansichtsmodus (Briefing „Motion“: „Aufblättern im Ansichtsmodus: 3 Frames“).
// Gehört zum Stop-Motion-Pfad, NICHT zu RealtimeMotion: keine CABasicAnimation, keine Easing-Kurve, sondern
// StopMotion.apply (CAKeyframeAnimation .discrete, 6 fps) auf einer Maske über dem Papier. Die Maske ist in der
// Eselsohr-Ecke verankert, so blättert das Papier in 3 harten Schritten aus der Ecke auf (bzw. zu).
// Eigene Masken-Hilfe, kein gemeinsamer Code mit RealtimeMotion (die beiden Pfade bleiben getrennt).

@MainActor
enum StopMotionSheet {
    static let maskName = "sm.sheetMask"

    /// Pose der Maske im Endzustand (voll aufgeblättert). Position = Anker = Eselsohr-Ecke in `content`-Koordinaten.
    static func fullPose(anchor: CGPoint) -> Pose {
        Pose(position: anchor, rotation: 0, scale: 1, opacity: 1)
    }

    /// Spielt `plan` als Maske auf `content` ab. Nicht animierter Plan (Reduce Motion): bei `removeMaskAfter`
    /// Maske weg, Papier sofort sichtbar; sonst bleibt nichts zu tun (der Aufrufer blendet sofort aus).
    /// `removeMaskAfter`: nach dem letzten Frame die Maske entfernen (Aufblättern; Maske = Offscreen-Pass, V10).
    static func play(_ plan: StopMotionPlan, on content: CALayer, anchor: CGPoint, removeMaskAfter: Bool) {
        guard plan.isAnimated else {
            if removeMaskAfter { clear(content) }
            return
        }
        let mask = makeMask(for: content, anchor: anchor)
        // ⚠️ VERIFIZIEREN: discrete-Keyframes auf einer Maske (bisher nur CABasicAnimation, RealtimeMotion); Jitter dreht
        // die Maske um ±0,3° um die Ecke – an der fernen Papierkante sind das einige pt (gewollt: Papier zittert).
        StopMotion.batch {
            content.mask = mask
            StopMotion.apply(plan, to: mask)   // Model-Wert = letzter Frame, dann discrete-Keyframes (Report 03)
        }
        guard removeMaskAfter else { return }
        afterDelay(plan.duration + 0.05) {
            guard content.mask === mask else { return }   // eine neuere Maske nicht entfernen
            withoutImplicitAnimations { content.mask = nil }
        }
    }

    static func clear(_ content: CALayer) {
        guard content.mask != nil else { return }
        withoutImplicitAnimations { content.mask = nil }
    }

    private static func makeMask(for content: CALayer, anchor: CGPoint) -> CALayer {
        let size = content.bounds.size
        let mask = CALayer()
        mask.name = maskName
        mask.backgroundColor = CGColor(gray: 0, alpha: 1)   // opak, nur die Fläche zählt
        let null = NSNull()
        mask.actions = ["position": null, "bounds": null, "transform": null, "opacity": null, "anchorPoint": null]
        withoutImplicitAnimations {
            mask.bounds = CGRect(origin: .zero, size: size)
            let ax = size.width > 0 ? min(max(anchor.x / size.width, 0), 1) : 1
            let ay = size.height > 0 ? min(max(anchor.y / size.height, 0), 1) : 1
            mask.anchorPoint = CGPoint(x: ax, y: ay)
            mask.position = anchor
        }
        return mask
    }
}
