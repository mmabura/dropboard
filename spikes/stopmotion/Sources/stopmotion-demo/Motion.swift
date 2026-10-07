import AppKit
import QuartzCore
import StopMotionCore

// Zwei klar getrennte Animationspfade (Briefing, "Motion: zwei Animationspfade").
// Sie teilen sich keinen Code: RealtimeMotion = CABasicAnimation, StopMotion = discrete Keyframes.

/// Einmalige verzögerte Aktion (z. B. Aufräumen nach Animationsende). Kein wiederholender Timer.
@MainActor
func afterDelay(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    // ⚠️ VERIFIZIEREN: Task.sleep als One-Shot auf dem Main Actor; Genauigkeit ist hier egal (Aufräumen), nicht für Frame-Timing.
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        work()
    }
}

// MARK: - Realtime-Pfad (Werkzeug-Verhalten, während der Nutzer etwas trägt)

@MainActor
enum RealtimeMotion {
    static let duration: CFTimeInterval = 0.2

    /// Aufblättern vom oberen rechten Eck: Mask-Layer, der in 200 ms von ~0 auf 1 skaliert (easeOut, kein Spring).
    /// Mit Reduce Motion passiert nichts: Inhalt ist sofort sichtbar (E2). Rückgabe: wurde animiert?
    @discardableResult
    static func reveal(content: CALayer, boardSize: CGSize, reduceMotion: Bool) -> Bool {
        if reduceMotion { return false }

        let mask = CALayer()
        mask.name = "rt.mask"
        mask.backgroundColor = CGColor(gray: 0, alpha: 1)   // opak, nur die Fläche zählt
        mask.bounds = CGRect(origin: .zero, size: boardSize)
        mask.anchorPoint = CGPoint(x: 1, y: 1)               // oberes rechtes Eck (Layer nicht geflippt)
        mask.position = CGPoint(x: boardSize.width, y: boardSize.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.mask = mask
        CATransaction.commit()

        // Model-Wert der Maske ist Identität (Endzustand); die Animation läuft von ~0 dorthin.
        // ⚠️ VERIFIZIEREN: Matrix-Interpolation von "transform" (Scale ~0 -> Identität) um den Anker oben rechts sieht wie ein sauberes Aufziehen aus.
        // ⚠️ VERIFIZIEREN (V10): Mask erzeugt einen Offscreen-Pass; deshalb wird sie nach der Animation wieder entfernt.
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.001, 0.001, 1))
        anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mask.add(anim, forKey: "rt.reveal")

        afterDelay(duration + 0.05) {
            guard content.mask === mask else { return }   // eine neuere Maske nicht entfernen
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.mask = nil
            CATransaction.commit()
        }
        return true
    }
}

// MARK: - Stop-Motion-Pfad (Objekt-Verhalten nach dem Drop und im Ansichtsmodus)

@MainActor
enum StopMotion {
    static let keyPrefix = "sm."

    /// Mehrere `apply`-Aufrufe in einer äußeren Transaktion bündeln, damit alle Layer im selben Commit starten.
    /// ⚠️ VERIFIZIEREN (V3): gleicher Commit => gleicher Display-Frame für alle Layer.
    static func batch(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Model-Wert hart setzen, ohne implizite Animation.
    static func setModel(_ pose: Pose, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = pose.position
        layer.transform = transform(for: pose)
        layer.opacity = Float(pose.opacity)
        CATransaction.commit()
    }

    /// Muster aus Report 03: Model-Wert zuerst auf den Endzustand (disableActions), dann discrete-Animation
    /// mit expliziten Werten. KEIN fillMode .forwards, KEIN isRemovedOnCompletion = false: nach dem Ende
    /// entfernt sich die Animation selbst, übrig bleibt nur der Model-Wert (= letzter Frame).
    /// Plan mit einem Frame (Reduce Motion): nur Model-Wert, keine Animation.
    static func apply(_ plan: StopMotionPlan, to layer: CALayer) {
        guard let last = plan.frames.last else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer.position = last.position
        layer.transform = transform(for: last)
        layer.opacity = Float(last.opacity)

        if plan.isAnimated {
            // Position und Rotation/Scale laufen über "transform" mit NSValue(caTransform3D:) (Guide, Report 03),
            // nicht über Sub-KeyPaths (V4).
            // ⚠️ VERIFIZIEREN: NSValue(point:) als Keyframe-Wert für "position" (Report 03 belegt nur NSValue(caTransform3D:)); AppKit-Initializer, nicht aus dem Report.
            layer.add(keyframes("position", plan.frames.map { NSValue(point: $0.position) }, plan), forKey: keyPrefix + "position")
            layer.add(keyframes("transform", plan.frames.map { NSValue(caTransform3D: transform(for: $0)) }, plan), forKey: keyPrefix + "transform")
            layer.add(keyframes("opacity", plan.frames.map { NSNumber(value: Float($0.opacity)) }, plan), forKey: keyPrefix + "opacity")
        }

        CATransaction.commit()
    }

    private static func keyframes(_ keyPath: String, _ values: [Any], _ plan: StopMotionPlan) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.calculationMode = .discrete                           // Default wäre .linear
        animation.values = values
        animation.keyTimes = plan.keyTimes.map { NSNumber(value: $0) }  // values.count + 1 Einträge, 0 ... 1
        animation.duration = plan.duration                              // immer explizit (Default 0 wird sonst 0.25 s)
        return animation
    }

    /// Rotation in Grad plus uniformer Scale, um den Anchor Point (Mitte).
    static func transform(for pose: Pose) -> CATransform3D {
        let radians = CGFloat(pose.rotation * Double.pi / 180.0)
        let scale = CGFloat(pose.scale)
        return CATransform3DScale(CATransform3DMakeRotation(radians, 0, 0, 1), scale, scale, 1)
    }
}
