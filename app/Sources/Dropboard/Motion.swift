import AppKit
import QuartzCore
import DropboardCore

// Zwei klar getrennte Animationspfade (Briefing, „Motion: zwei Animationspfade“). Sie teilen sich keinen Code.
//   RealtimeMotion – Werkzeug-Verhalten, während der Nutzer etwas trägt: CABasicAnimation, ~200 ms, kein Bounce.
//   StopMotion     – Objekt-Verhalten nach dem Drop (und später im Ansichtsmodus): CAKeyframeAnimation .discrete,
//                    6 fps, Frames aus StopMotionCore (StopMotionPlanner/StopMotionSequences).
// Kein Timer, kein DisplayLink: nach dem Commit läuft alles im Render-Server.
// Übernommen aus spikes/stopmotion/Sources/stopmotion-demo/Motion.swift; RealtimeMotion um Anker und Zuklappen erweitert.

/// Einmalige verzögerte Aktion (Aufräumen nach Animationsende). Kein wiederholender Timer. Aus dem Spike.
@MainActor
func afterDelay(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    // ⚠️ VERIFIZIEREN (aus Spike): Task.sleep als One-Shot auf dem Main Actor; Genauigkeit hier unkritisch.
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        work()
    }
}

/// „Bewegung reduzieren“ (E2): Systemeinstellung (beim Start gelesen, per Notification aktualisiert)
/// oder per Startargument `--reduce-motion` erzwungen. Aus dem Spike.
@MainActor
final class MotionPreferences: NSObject {
    private(set) var system: Bool
    let forced: Bool

    var effective: Bool { system || forced }

    init(forced: Bool) {
        self.forced = forced
        system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        super.init()
        // Die Notification kommt nur über NSWorkspace.shared.notificationCenter (Report 03).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    @objc private func displayOptionsChanged(_ note: Notification) {
        system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Log.line("[MOTION]", "Bewegung reduzieren geändert: system=\(system) forced=\(forced) effective=\(effective)")
    }
}

// MARK: - Realtime-Pfad

@MainActor
enum RealtimeMotion {
    static let duration: CFTimeInterval = 0.2
    static let maskName = "rt.mask"

    /// Aufblättern: Mask-Layer skaliert in 200 ms von ~0 auf 1, Anker = `anchor` (Eselsohr-Ecke, in
    /// `content`-Koordinaten, y nach oben). easeOut, kein Spring. Mit Reduce Motion: sofort sichtbar (E2).
    /// Rückgabe: wurde animiert?
    @discardableResult
    static func reveal(_ content: CALayer, from anchor: CGPoint, reduceMotion: Bool) -> Bool {
        if reduceMotion {
            clear(content)
            return false
        }
        let mask = makeMask(for: content, anchor: anchor)
        withoutImplicitAnimations {
            mask.transform = CATransform3DIdentity     // Model-Wert = Endzustand (Report 03)
            content.mask = mask
        }
        // ⚠️ VERIFIZIEREN (aus Spike): Matrix-Interpolation Scale ~0 → Identität um den Anker sieht wie Aufziehen aus.
        // ⚠️ VERIFIZIEREN (V10, aus Spike): Maske = Offscreen-Pass; deshalb wird sie nach der Animation entfernt.
        mask.add(scaleAnimation(from: CATransform3DMakeScale(0.001, 0.001, 1), to: CATransform3DIdentity),
                 forKey: "rt.reveal")
        afterDelay(duration + 0.05) {
            guard content.mask === mask else { return }   // eine neuere Maske nicht entfernen
            withoutImplicitAnimations { content.mask = nil }
        }
        return true
    }

    /// Zuklappen: umgekehrt, zur Eselsohr-Ecke hin. Model-Wert = zugeklappt (unsichtbar), damit nach dem
    /// Ende nichts aufblitzt. `completion` läuft nach ~200 ms (bzw. sofort bei Reduce Motion); der Aufrufer
    /// blendet dann das Fenster aus und ruft `clear`.
    @discardableResult
    static func collapse(_ content: CALayer, to anchor: CGPoint, reduceMotion: Bool,
                         completion: @escaping @MainActor () -> Void) -> Bool {
        if reduceMotion {
            completion()
            return false
        }
        let collapsed = CATransform3DMakeScale(0.001, 0.001, 1)
        let mask = makeMask(for: content, anchor: anchor)
        withoutImplicitAnimations {
            mask.transform = collapsed
            content.mask = mask
        }
        mask.add(scaleAnimation(from: CATransform3DIdentity, to: collapsed), forKey: "rt.collapse")
        afterDelay(duration) { completion() }
        return true
    }

    /// Maske sofort entfernen (nach orderOut bzw. bei Reduce Motion).
    static func clear(_ content: CALayer) {
        guard content.mask != nil else { return }
        withoutImplicitAnimations { content.mask = nil }
    }

    private static func makeMask(for content: CALayer, anchor: CGPoint) -> CALayer {
        let size = content.bounds.size
        let mask = CALayer()
        mask.name = maskName
        mask.backgroundColor = CGColor(gray: 0, alpha: 1)   // opak, nur die Fläche zählt
        mask.bounds = CGRect(origin: .zero, size: size)
        let ax = size.width > 0 ? min(max(anchor.x / size.width, 0), 1) : 1
        let ay = size.height > 0 ? min(max(anchor.y / size.height, 0), 1) : 1
        mask.anchorPoint = CGPoint(x: ax, y: ay)
        mask.position = CGPoint(x: ax * size.width, y: ay * size.height)
        return mask
    }

    private static func scaleAnimation(from: CATransform3D, to: CATransform3D) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: from)
        anim.toValue = NSValue(caTransform3D: to)
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return anim
    }
}

// MARK: - Stop-Motion-Pfad (unverändert aus dem Spike)

@MainActor
enum StopMotion {
    static let keyPrefix = "sm."

    /// Mehrere Aufrufe in einer äußeren Transaktion bündeln, damit alles im selben Commit startet.
    /// ⚠️ VERIFIZIEREN (V3, aus Spike): gleicher Commit => gleicher Display-Frame für alle Layer.
    static func batch(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Model-Wert hart setzen, ohne implizite Animation (Quick-Drop, Laden).
    static func setModel(_ pose: Pose, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = pose.position
        layer.transform = transform(for: pose)
        layer.opacity = Float(pose.opacity)
        CATransaction.commit()
    }

    /// Muster aus Report 03: Model-Wert zuerst auf den Endzustand, dann discrete-Animation mit expliziten Werten.
    /// KEIN fillMode .forwards, KEIN isRemovedOnCompletion = false. Plan mit einem Frame (Reduce Motion): nur Model-Wert.
    static func apply(_ plan: StopMotionPlan, to layer: CALayer) {
        guard let last = plan.frames.last else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer.position = last.position
        layer.transform = transform(for: last)
        layer.opacity = Float(last.opacity)

        if plan.isAnimated {
            // ⚠️ VERIFIZIEREN (aus Spike): NSValue(point:) als Keyframe-Wert für "position".
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
        animation.duration = plan.duration                              // immer explizit
        return animation
    }

    /// Rotation in Grad plus uniformer Scale, um den Anchor Point (Mitte).
    static func transform(for pose: Pose) -> CATransform3D {
        let radians = CGFloat(pose.rotation * Double.pi / 180.0)
        let scale = CGFloat(pose.scale)
        return CATransform3DScale(CATransform3DMakeRotation(radians, 0, 0, 1), scale, scale, 1)
    }
}
