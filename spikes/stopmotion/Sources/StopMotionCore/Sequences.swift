import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Fertige Sequenzen aus dem Briefing. Alle Zahlenwerte stehen hier gebündelt.
public enum StopMotionSequences {
    public static let dropScale = 1.08          // Frame 1 des Drops: groß, ohne Kipp
    public static let revealStartScale = 0.6    // Aufblättern: 0.6 -> 0.85 -> 1.0
    public static let revealProgress: [Double] = [0, 0.625, 1]
    public static let moveStepDistance = 120.0  // pt pro Frame
    public static let moveMinFrames = 2
    public static let moveMaxFrames = 4
    public static let deleteScale = 0.92        // Löschen: leicht kleiner, dann weg

    /// Drop: 2 Frames. Frame 0 = groß und ohne Kipp (mit Jitter), Frame 1 = `target` (mit Kipp).
    public static func drop<G: RandomNumberGenerator>(target: Pose, options: PlanOptions, using rng: inout G) -> StopMotionPlan {
        var start = target
        start.rotation = 0
        start.scale = target.scale * dropScale
        return StopMotionPlanner.plan(SequenceSpec(start: start, end: target, frameCount: 2, options: options), using: &rng)
    }

    /// Aufblättern im Ansichtsmodus: 3 Frames, scale 0.6 -> 0.85 -> 1.0 (relativ zu `target.scale`).
    public static func reveal<G: RandomNumberGenerator>(target: Pose, options: PlanOptions, using rng: inout G) -> StopMotionPlan {
        var start = target
        start.scale = target.scale * revealStartScale
        return StopMotionPlanner.plan(SequenceSpec(start: start, end: target, frameCount: 3,
                                                   progress: revealProgress, options: options), using: &rng)
    }

    /// Anzahl Frames für eine Bewegung: max(2, Distanz/120 pt), begrenzt auf 4.
    public static func moveFrameCount(distance: Double) -> Int {
        min(moveMaxFrames, max(moveMinFrames, Int(distance / moveStepDistance)))
    }

    /// Umsortieren: n gleichmäßige Schritte von `from` nach `to`. Der erste Frame ist schon
    /// ein Schritt weg von A (Start sofort, E1), der letzte Frame ist exakt B.
    public static func move<G: RandomNumberGenerator>(from: Pose, to: Pose, options: PlanOptions, using rng: inout G) -> StopMotionPlan {
        let dx = Double(to.position.x - from.position.x)
        let dy = Double(to.position.y - from.position.y)
        let n = moveFrameCount(distance: (dx * dx + dy * dy).squareRoot())
        let progress = (1...n).map { Double($0) / Double(n) }
        return StopMotionPlanner.plan(SequenceSpec(start: from, end: to, frameCount: n,
                                                   progress: progress, options: options), using: &rng)
    }

    /// Löschen: 2 Frames. Frame 0 = leicht kleiner (mit Jitter), Frame 1 = weg (opacity 0).
    public static func delete<G: RandomNumberGenerator>(from: Pose, options: PlanOptions, using rng: inout G) -> StopMotionPlan {
        var shrunk = from
        shrunk.scale = from.scale * deleteScale
        var gone = shrunk
        gone.opacity = 0
        return StopMotionPlanner.plan(SequenceSpec(start: shrunk, end: gone, frameCount: 2, options: options), using: &rng)
    }
}
