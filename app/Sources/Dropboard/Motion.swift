import AppKit
import QuartzCore
import DropboardCore

// Zwei klar getrennte Animationspfade (Briefing, „Motion: zwei Animationspfade“). Sie teilen sich keinen Code.
//   RealtimeMotion – Werkzeug-Verhalten, während der Nutzer etwas trägt: CABasicAnimation, ~200 ms, kein Bounce.
//   StopMotion     – Objekt-Verhalten nach dem Drop und im Ansichtsmodus (dort auch StopMotionSheet): CAKeyframeAnimation .discrete,
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
    /// Name des Clip-Containers zwischen Board-Root und Papier (BoardScene legt ihn an).
    static let clipName = "rt.clip"
    static let revealKey = "rt.reveal"
    static let collapseKey = "rt.collapse"

    /// Zählt Aufblättern/Zuklappen hoch, damit verzögertes Aufräumen eine neuere Animation nicht anfasst.
    private static var generation = 0

    // P5: Aufblättern/Zuklappen OHNE Vollbild-Maske. Das Papier hängt in einem Container (`clipName`) mit
    // masksToBounds = true; animiert wird nur dessen `bounds` (Rechteck), Ankerpunkt und Position bleiben auf der
    // Eselsohr-Ecke. Mit anchorPoint a (relativ) und position = Anker A gilt für jedes bounds-Rechteck
    // (origin o, size s): frame.origin = A − a·s. Wird bounds linear zwischen (A, 0×0) und (0, 0, W×H) interpoliert,
    // ist o(t) = A·(1−t) und a·s(t) = A·t (weil A = a·(W, H)) → frame.origin == bounds.origin in jedem Frame: das
    // Koordinatensystem des Containers deckt sich mit dem Root, das Papier bleibt stehen, nur der sichtbare Ausschnitt
    // wächst diagonal aus der Ecke – exakt dieselbe Fläche wie die alte Scale-Maske (Rechteck um den Anker skaliert).
    // Ein achsenparalleles Clip-Rechteck ohne cornerRadius braucht keinen Offscreen-Pass (Scissor), eine Maske schon
    // (Review P5: ≈ 33 MB Offscreen-Target bei 4K @2x). Eine kleinere Maske wäre weiterhin ein Offscreen-Pass über
    // die maskierte Fläche – deshalb Container statt „Maske nur so groß wie nötig“.
    // ⚠️ VERIFIZIEREN: masksToBounds ohne cornerRadius rendert ohne Offscreen-Pass (Instruments „Color Offscreen-Rendered“
    // bzw. Quartz Debug während des Aufklappens prüfen).
    // ⚠️ VERIFIZIEREN: CABasicAnimation auf "bounds" interpoliert origin und size komponentenweise mit derselben
    // Timing-Kurve (sonst würde das Papier während der 200 ms wandern). Prüfen: Bilder stehen beim Aufklappen still.

    /// Aufblättern: sichtbarer Ausschnitt wächst in 200 ms von der Eselsohr-Ecke `anchor` (in `content`-Koordinaten,
    /// y nach oben) auf das ganze Blatt. easeOut, kein Spring. Mit Reduce Motion: sofort sichtbar (E2).
    /// Rückgabe: wurde animiert?
    @discardableResult
    static func reveal(_ content: CALayer, from anchor: CGPoint, reduceMotion: Bool) -> Bool {
        if reduceMotion {
            clear(content)
            return false
        }
        guard let clip = clipContainer(of: content) else {
            return revealWithMask(content, from: anchor)   // Fallback ohne Container (alter Weg, Offscreen-Pass)
        }
        generation += 1
        let gen = generation
        let full = fullRect(content)
        let a = clampedAnchor(anchor, in: full.size)
        withoutImplicitAnimations {
            if content.mask != nil { content.mask = nil }   // Reste einer Maske (Ansichtsmodus) nicht stehen lassen
            clip.removeAnimation(forKey: collapseKey)
            clip.removeAnimation(forKey: revealKey)
            clip.anchorPoint = a.relative
            clip.position = a.point
            clip.bounds = full                               // Model-Wert = Endzustand (Report 03)
            clip.masksToBounds = true
        }
        let anim = boundsAnimation(from: collapsedRect(a.point), to: full, duration: duration)
        // P6: Start der Animation (nach dem Commit) loggen, für die Latenzmessung Hover → erster Frame.
        anim.delegate = RevealStartLogger(startedAt: Log.now)
        clip.add(anim, forKey: revealKey)
        afterDelay(duration + 0.05) {
            guard generation == gen else { return }          // ein neueres Zuklappen/Aufblättern nicht anfassen
            withoutImplicitAnimations { clip.masksToBounds = false }   // Ruhezustand: kein Clipping
        }
        return true
    }

    /// Zuklappen: umgekehrt, zur Eselsohr-Ecke hin. Model-Wert = zugeklappt (unsichtbar), damit nach dem
    /// Ende nichts aufblitzt. `completion` läuft nach dem Zuklappen (bzw. sofort bei Reduce Motion); der Aufrufer
    /// blendet dann das Fenster aus und ruft `clear`.
    /// C13: Läuft das Aufblättern noch, startet das Zuklappen vom aktuell sichtbaren (Presentation-)Wert statt vom
    /// vollen Blatt; die Dauer schrumpft anteilig (gleiche Geschwindigkeit, ≥ 50 ms), damit nichts springt.
    @discardableResult
    static func collapse(_ content: CALayer, to anchor: CGPoint, reduceMotion: Bool,
                         completion: @escaping @MainActor () -> Void) -> Bool {
        if reduceMotion {
            completion()
            return false
        }
        guard let clip = clipContainer(of: content) else {
            return collapseWithMask(content, to: anchor, completion: completion)
        }
        generation += 1
        let full = fullRect(content)
        let a = clampedAnchor(anchor, in: full.size)
        let collapsed = collapsedRect(a.point)
        let running = clip.animation(forKey: revealKey) != nil || clip.animation(forKey: collapseKey) != nil
        let from = collapseStart(running: running, presented: clip.presentation()?.bounds, model: clip.bounds,
                                 clipping: clip.masksToBounds, full: full)
        let d = collapseDuration(from: from, full: full)
        if running {
            Log.line("[MOTION]", "collapse ab sichtbarem Wert \(Int(from.width))x\(Int(from.height)) "
                + "von \(Int(full.width))x\(Int(full.height)) dauer=\(Int((d * 1000).rounded()))ms (C13)")
        }
        withoutImplicitAnimations {
            clip.removeAnimation(forKey: revealKey)
            clip.anchorPoint = a.relative
            clip.position = a.point
            clip.bounds = collapsed                          // Model-Wert = zugeklappt
            clip.masksToBounds = true
        }
        clip.add(boundsAnimation(from: from, to: collapsed, duration: d), forKey: collapseKey)
        afterDelay(d) { completion() }
        return true
    }

    /// Sichtbarer Ausschnitt beim Start des Zuklappens (rein, Selftest): Presentation-Wert einer laufenden Animation,
    /// sonst das Model (bei aktivem Clipping) bzw. das ganze Blatt.
    // ⚠️ VERIFIZIEREN: presentation() liefert während der Animation den sichtbaren bounds-Wert (vor dem ersten Commit
    // nil → Fallback ganzes Blatt). Hardware: Board aufklappen und sofort Esc → Log-Zeile „collapse ab sichtbarem Wert“.
    static func collapseStart(running: Bool, presented: CGRect?, model: CGRect, clipping: Bool, full: CGRect) -> CGRect {
        if running, let shown = presented { return shown }
        return clipping ? model : full
    }

    /// Dauer des Zuklappens anteilig zum sichtbaren Ausschnitt (gleiche Geschwindigkeit), mindestens 50 ms.
    static func collapseDuration(from: CGRect, full: CGRect) -> CFTimeInterval {
        let progress = full.width > 0 ? min(1, max(0, from.width / full.width)) : 1
        return progress >= 1 ? duration : max(0.05, duration * Double(progress))
    }

    /// Clip/Maske sofort zurücksetzen (nach orderOut bzw. bei Reduce Motion): ganzes Blatt sichtbar, kein Clipping.
    static func clear(_ content: CALayer) {
        generation += 1
        if let clip = clipContainer(of: content) {
            let full = fullRect(content)
            withoutImplicitAnimations {
                clip.removeAnimation(forKey: revealKey)
                clip.removeAnimation(forKey: collapseKey)
                clip.masksToBounds = false
                clip.anchorPoint = .zero
                clip.position = .zero
                clip.bounds = full
            }
        }
        if content.mask != nil {   // wie bisher: jede Maske weg (auch eine Fallback-Maske)
            withoutImplicitAnimations { content.mask = nil }
        }
    }

    // MARK: Geometrie

    static func clipContainer(of content: CALayer) -> CALayer? {
        guard let parent = content.superlayer, parent.name == clipName else { return nil }
        return parent
    }

    /// Ganzes Blatt in Container-Koordinaten (= Root-Koordinaten).
    static func fullRect(_ content: CALayer) -> CGRect {
        CGRect(origin: .zero, size: content.bounds.size)
    }

    /// Zugeklappt: leeres Rechteck genau im Anker (frame.origin == bounds.origin == Anker).
    static func collapsedRect(_ anchor: CGPoint) -> CGRect {
        CGRect(origin: anchor, size: .zero)
    }

    /// Anker auf das Blatt begrenzt; relativ (anchorPoint) und absolut (position).
    static func clampedAnchor(_ anchor: CGPoint, in size: CGSize) -> (relative: CGPoint, point: CGPoint) {
        let ax = size.width > 0 ? min(max(anchor.x / size.width, 0), 1) : 1
        let ay = size.height > 0 ? min(max(anchor.y / size.height, 0), 1) : 1
        return (CGPoint(x: ax, y: ay), CGPoint(x: ax * size.width, y: ay * size.height))
    }

    /// Sichtbarer Ausschnitt (in Root-Koordinaten) bei Container-bounds `b` und Anker `a` – für den Selftest:
    /// frame des Containers. Muss mit `b` übereinstimmen, damit das Papier stillsteht.
    static func visibleFrame(bounds b: CGRect, anchor a: (relative: CGPoint, point: CGPoint)) -> CGRect {
        CGRect(x: a.point.x - a.relative.x * b.width, y: a.point.y - a.relative.y * b.height,
               width: b.width, height: b.height)
    }

    private static func boundsAnimation(from: CGRect, to: CGRect, duration d: CFTimeInterval) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "bounds")
        anim.fromValue = NSValue(rect: from)   // ⚠️ VERIFIZIEREN: NSValue(rect:) als Wert für "bounds" (macOS)
        anim.toValue = NSValue(rect: to)
        anim.duration = d
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return anim
    }

    // MARK: Fallback ohne Clip-Container (alter Weg: Vollbild-Maske = Offscreen-Pass)

    private static func revealWithMask(_ content: CALayer, from anchor: CGPoint) -> Bool {
        let mask = makeMask(for: content, anchor: anchor)
        withoutImplicitAnimations {
            mask.transform = CATransform3DIdentity
            content.mask = mask
        }
        mask.add(scaleAnimation(from: CATransform3DMakeScale(0.001, 0.001, 1), to: CATransform3DIdentity),
                 forKey: revealKey)
        afterDelay(duration + 0.05) {
            guard content.mask === mask else { return }
            withoutImplicitAnimations { content.mask = nil }
        }
        return true
    }

    private static func collapseWithMask(_ content: CALayer, to anchor: CGPoint,
                                         completion: @escaping @MainActor () -> Void) -> Bool {
        let collapsed = CATransform3DMakeScale(0.001, 0.001, 1)
        // C13 auch hier: vom sichtbaren Wert einer noch laufenden Maske starten.
        let running = content.mask?.name == maskName ? content.mask?.presentation()?.transform : nil
        let mask = makeMask(for: content, anchor: anchor)
        withoutImplicitAnimations {
            mask.transform = collapsed
            content.mask = mask
        }
        mask.add(scaleAnimation(from: running ?? CATransform3DIdentity, to: collapsed), forKey: collapseKey)
        afterDelay(duration) { completion() }
        return true
    }

    private static func makeMask(for content: CALayer, anchor: CGPoint) -> CALayer {
        let size = content.bounds.size
        let a = clampedAnchor(anchor, in: size)
        let mask = CALayer()
        mask.name = maskName
        mask.backgroundColor = CGColor(gray: 0, alpha: 1)   // opak, nur die Fläche zählt
        mask.bounds = CGRect(origin: .zero, size: size)
        mask.anchorPoint = a.relative
        mask.position = a.point
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

/// P6: loggt `[MOTION] reveal gestartet +X ms` (X = Zeit vom Hinzufügen der Animation bis zum Start im Commit).
/// Nicht an einen Actor gebunden: nutzt nur das thread-sichere Log.
// ⚠️ VERIFIZIEREN: CAAnimationDelegate.animationDidStart kommt in keinem Spike vor; die Animation hält ihren Delegate
// stark (laut Doku), deshalb keine eigene Referenz nötig. Aufruf auf dem Main Thread nach dem Commit erwartet.
final class RevealStartLogger: NSObject, CAAnimationDelegate {
    private let startedAt: TimeInterval

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        super.init()
    }

    func animationDidStart(_ anim: CAAnimation) {
        Log.line("[MOTION]", "reveal gestartet +\(Log.ms(since: startedAt))ms")
    }
}

// MARK: - Stop-Motion-Pfad (aus dem Spike; Fix C: Schatten-Spur für den Drop, B6)

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

        // B6: Schatten nur mitführen, wenn der Plan ihn verändert (Drop: Frame 0 ohne Schatten). Masken und alle anderen
        // Sequenzen (shadow == 1 überall) bleiben unberührt – eine Maske darf keinen Schatten bekommen.
        let withShadow = tracksShadow(plan)
        if withShadow {
            layer.shadowOpacity = shadowOpacity(for: last)
        }

        if plan.isAnimated {
            // ⚠️ VERIFIZIEREN (aus Spike): NSValue(point:) als Keyframe-Wert für "position".
            layer.add(keyframes("position", plan.frames.map { NSValue(point: $0.position) }, plan), forKey: keyPrefix + "position")
            layer.add(keyframes("transform", plan.frames.map { NSValue(caTransform3D: transform(for: $0)) }, plan), forKey: keyPrefix + "transform")
            layer.add(keyframes("opacity", plan.frames.map { NSNumber(value: Float($0.opacity)) }, plan), forKey: keyPrefix + "opacity")
            if withShadow {
                // ⚠️ VERIFIZIEREN: discrete-Keyframes auf "shadowOpacity" (bisher nur position/transform/opacity belegt).
                layer.add(keyframes("shadowOpacity", plan.frames.map { NSNumber(value: shadowOpacity(for: $0)) }, plan),
                          forKey: keyPrefix + "shadowOpacity")
            }
        }

        CATransaction.commit()
    }

    /// Verändert der Plan den Schatten (irgendein Frame mit shadow ≠ 1)?
    static func tracksShadow(_ plan: StopMotionPlan) -> Bool {
        plan.frames.contains { $0.shadow != 1 }
    }

    /// Schatten-Deckkraft eines Frames: Anteil × PaperStyle.shadowOpacity.
    static func shadowOpacity(for pose: Pose) -> Float {
        PaperStyle.shadowOpacity * Float(min(1, max(0, pose.shadow)))
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
