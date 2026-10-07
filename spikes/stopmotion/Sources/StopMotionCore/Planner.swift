import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct PlanOptions: Equatable {
    public var jitter: Bool
    public var reduceMotion: Bool
    public var backingScale: Double

    public init(jitter: Bool = true, reduceMotion: Bool = false, backingScale: Double = 2.0) {
        self.jitter = jitter
        self.reduceMotion = reduceMotion
        self.backingScale = backingScale
    }
}

/// Eingabe des Planers.
/// `progress` (optional, Länge == frameCount) legt fest, wie weit jeder Frame von start nach end ist.
/// Ohne Angabe: i/(n-1), d. h. Frame 0 = start, letzter Frame = end.
/// Der letzte Frame ist immer exakt `end`, unabhängig von `progress`.
public struct SequenceSpec {
    public var start: Pose
    public var end: Pose
    public var frameCount: Int
    public var progress: [Double]?
    public var options: PlanOptions

    public init(start: Pose, end: Pose, frameCount: Int, progress: [Double]? = nil, options: PlanOptions = PlanOptions()) {
        self.start = start
        self.end = end
        self.frameCount = frameCount
        self.progress = progress
        self.options = options
    }
}

/// Ausgabe des Planers. Passend für `CAKeyframeAnimation` mit `.discrete`:
/// `keyTimes.count == frames.count + 1`, erstes Element 0, letztes 1 (Report 03, Abschnitt 1).
/// Bei nur einem Frame (Reduce Motion) gibt es nichts zu animieren (`isAnimated == false`, duration 0).
public struct StopMotionPlan: Equatable {
    public let frames: [Pose]
    public let keyTimes: [Double]
    public let duration: Double

    public init(frames: [Pose], keyTimes: [Double], duration: Double) {
        self.frames = frames
        self.keyTimes = keyTimes
        self.duration = duration
    }

    public var isAnimated: Bool { frames.count > 1 }

    /// Welcher Frame ist `time` Sekunden nach dem Start sichtbar? `nil` vor dem Start und ab dem
    /// Ende der Sequenz (dort zeigt der Layer wieder den Model-Wert, das ist der letzte Frame).
    public func frame(at time: Double) -> Pose? {
        guard isAnimated, time >= 0, time < duration else { return nil }
        let fraction = time / duration
        var index = 0
        for i in 0..<frames.count where keyTimes[i] <= fraction { index = i }
        return frames[index]
    }
}

public enum StopMotionPlanner {
    public static func plan<G: RandomNumberGenerator>(_ spec: SequenceSpec, using rng: inout G) -> StopMotionPlan {
        // Reduce Motion (E2) oder nur ein Frame: genau der Endzustand, kein Jitter, kein Zufall verbraucht.
        if spec.options.reduceMotion || spec.frameCount <= 1 {
            return StopMotionPlan(frames: [spec.end], keyTimes: [0, 1], duration: 0)
        }

        let n = spec.frameCount
        let progress: [Double]
        if let given = spec.progress, given.count == n {
            progress = given
        } else {
            progress = (0..<n).map { Double($0) / Double(n - 1) }
        }

        var frames: [Pose] = []
        frames.reserveCapacity(n)
        for i in 0..<n {
            if i == n - 1 {
                frames.append(spec.end)   // Endzustand exakt, ohne Jitter
                continue
            }
            var frame = lerp(spec.start, spec.end, progress[i])
            if spec.options.jitter {
                let j = StopMotionJitter.snapped(StopMotionJitter.sample(using: &rng),
                                                 backingScale: spec.options.backingScale)
                frame.position = CGPoint(x: frame.position.x + CGFloat(j.dx), y: frame.position.y + CGFloat(j.dy))
                frame.rotation += j.rotation
            }
            frames.append(frame)
        }

        let keyTimes = (0...n).map { Double($0) / Double(n) }   // n + 1 Einträge, 0 ... 1
        return StopMotionPlan(frames: frames, keyTimes: keyTimes, duration: Double(n) * StopMotionClock.frameDuration)
    }

    private static func lerp(_ a: Pose, _ b: Pose, _ t: Double) -> Pose {
        Pose(position: CGPoint(x: a.position.x + (b.position.x - a.position.x) * CGFloat(t),
                               y: a.position.y + (b.position.y - a.position.y) * CGFloat(t)),
             rotation: a.rotation + (b.rotation - a.rotation) * t,
             scale: a.scale + (b.scale - a.scale) * t,
             opacity: a.opacity + (b.opacity - a.opacity) * t)
    }
}
