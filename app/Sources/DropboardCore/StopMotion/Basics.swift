// Unverändert übernommen aus spikes/stopmotion/Sources/StopMotionCore/Basics.swift (auf dem Mac mini kompiliert, Selftest 55/55).
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Das 6-fps-Raster. Entscheidung E1: Jede Sequenz startet sofort beim Auslösen,
/// danach gilt dieser feste Takt. Es gibt kein globales Raster und keinen laufenden Timer.
public enum StopMotionClock {
    public static let fps = 6
    public static let frameDuration: Double = 1.0 / 6.0
}

/// Kleiner, seedbarer PRNG (SplitMix64). Ersetzt SystemRandomNumberGenerator,
/// damit der Planer deterministisch und testbar ist.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public extension RandomNumberGenerator {
    /// Gleichverteilt in [0, 1). Eigene Ableitung statt Double.random(in:using:),
    /// damit das Ergebnis nicht von der Stdlib-Version abhängt.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Gleichverteilt in [lo, hi).
    mutating func nextDouble(in lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * nextUnit()
    }
}

/// Zustand eines Objekts in einem Frame. Rotation in Grad.
public struct Pose: Equatable {
    public var position: CGPoint
    public var rotation: Double
    public var scale: Double
    public var opacity: Double

    public init(position: CGPoint, rotation: Double = 0, scale: Double = 1, opacity: Double = 1) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.opacity = opacity
    }
}

/// Ein Jitter-Beitrag für einen Zwischenframe.
public struct JitterSample: Equatable {
    public var dx: Double
    public var dy: Double
    public var rotation: Double
}

public enum StopMotionJitter {
    public static let minOffset = 0.5      // pt
    public static let maxOffset = 1.0      // pt
    public static let maxRotation = 0.3    // Grad, ±

    /// Zufallsrichtung, Betrag in [minOffset, maxOffset], Rotation in ±maxRotation. Vor dem Runden.
    /// Zieht immer genau drei Zufallswerte.
    public static func sample<G: RandomNumberGenerator>(using rng: inout G) -> JitterSample {
        let angle = rng.nextUnit() * 2.0 * Double.pi
        let magnitude = rng.nextDouble(in: minOffset, maxOffset)
        let rotation = rng.nextDouble(in: -maxRotation, maxRotation)
        return JitterSample(dx: cos(angle) * magnitude, dy: sin(angle) * magnitude, rotation: rotation)
    }

    /// Rundet den Versatz auf ganze Device-Pixel (1/backingScale pt). Wären beide Achsen danach 0
    /// (z. B. 0,35 pt bei 1x), bekommt die größere Achse ein volles Pixel, damit der Frame sichtbar zittert.
    public static func snapped(_ s: JitterSample, backingScale: Double) -> JitterSample {
        let k = max(1.0, backingScale)
        var dx = (s.dx * k).rounded() / k
        var dy = (s.dy * k).rounded() / k
        if dx == 0 && dy == 0 {
            if abs(s.dx) >= abs(s.dy) { dx = (s.dx < 0 ? -1.0 : 1.0) / k } else { dy = (s.dy < 0 ? -1.0 : 1.0) / k }
        }
        return JitterSample(dx: dx, dy: dy, rotation: s.rotation)
    }
}
