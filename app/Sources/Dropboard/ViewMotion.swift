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
        // B7: Der Rotations-Jitter (±0,3°) würde die bildschirmgroße Maske um die Ecke drehen; an der fernen Papierkante
        // wären das bei 1920×1080 pt ≈ 11 pt. Deshalb anteilig so begrenzt, dass sich der fernste Punkt um höchstens
        // 1 Device-Pixel bewegt (Positions-Jitter bleibt 1 Device-Pixel).
        let limited = limitRotation(plan, sheetSize: content.bounds.size, anchor: anchor,
                                    backingScale: Double(max(1, content.contentsScale)))
        // ⚠️ VERIFIZIEREN: discrete-Keyframes auf einer Maske (bisher nur CABasicAnimation, RealtimeMotion).
        StopMotion.batch {
            content.mask = mask
            StopMotion.apply(limited, to: mask)   // Model-Wert = letzter Frame, dann discrete-Keyframes (Report 03)
        }
        guard removeMaskAfter else { return }
        afterDelay(plan.duration + 0.05) {
            guard content.mask === mask else { return }   // eine neuere Maske nicht entfernen
            withoutImplicitAnimations { content.mask = nil }
        }
    }

    /// Größter Abstand vom Drehpunkt (Anker) zu einer Ecke des Blatts, in pt.
    static func farthestDistance(sheetSize: CGSize, anchor: CGPoint) -> Double {
        let xs = [0.0, Double(sheetSize.width)], ys = [0.0, Double(sheetSize.height)]
        var best = 0.0
        for x in xs {
            for y in ys {
                let dx = x - Double(anchor.x), dy = y - Double(anchor.y)
                best = max(best, (dx * dx + dy * dy).squareRoot())
            }
        }
        return best
    }

    /// Größte erlaubte Blatt-Rotation (Grad), bei der sich der fernste Punkt um höchstens 1 Device-Pixel bewegt.
    static func maxSheetRotation(sheetSize: CGSize, anchor: CGPoint, backingScale: Double) -> Double {
        let r = farthestDistance(sheetSize: sheetSize, anchor: anchor)
        guard r > 0 else { return StopMotionJitter.maxRotation }
        let onePixel = 1.0 / max(1.0, backingScale)                 // pt
        let degrees = 2 * asin(min(1, onePixel / (2 * r))) * 180 / Double.pi   // Sehne = 1 px
        return min(StopMotionJitter.maxRotation, degrees)
    }

    /// Plan mit anteilig verkleinerter Rotation: ±maxRotation → ±maxSheetRotation (Vorzeichen und Verhältnis bleiben).
    static func limitRotation(_ plan: StopMotionPlan, sheetSize: CGSize, anchor: CGPoint, backingScale: Double) -> StopMotionPlan {
        let limit = maxSheetRotation(sheetSize: sheetSize, anchor: anchor, backingScale: backingScale)
        let factor = StopMotionJitter.maxRotation > 0 ? limit / StopMotionJitter.maxRotation : 0
        let frames = plan.frames.map { pose -> Pose in
            var p = pose
            p.rotation = min(limit, max(-limit, pose.rotation * factor))
            return p
        }
        return StopMotionPlan(frames: frames, keyTimes: plan.keyTimes, duration: plan.duration)
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
