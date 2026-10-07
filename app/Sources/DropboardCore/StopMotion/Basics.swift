// Übernommen aus spikes/stopmotion/Sources/StopMotionCore/Basics.swift (auf dem Mac mini kompiliert, Selftest 55/55).
// Phase 4 (Fix C): Pose.shadow (B6), Jitter in Device-Pixeln statt pt (B7).
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
/// `shadow`: Anteil des harten Schattens (0 = kein Schatten, 1 = voller Schatten laut PaperStyle). Nur der Drop
/// nutzt Werte ≠ 1 (Frame 0 ohne Schatten, Briefing „final mit Schatten und Kipp“, B6).
public struct Pose: Equatable {
    public var position: CGPoint
    public var rotation: Double
    public var scale: Double
    public var opacity: Double
    public var shadow: Double

    public init(position: CGPoint, rotation: Double = 0, scale: Double = 1, opacity: Double = 1, shadow: Double = 1) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.opacity = opacity
        self.shadow = shadow
    }
}

/// Ein Jitter-Beitrag für einen Zwischenframe.
public struct JitterSample: Equatable {
    public var dx: Double
    public var dy: Double
    public var rotation: Double
}

public enum StopMotionJitter {
    /// Briefing „0,5–1 px Positions-Jitter“: Device-Pixel, NICHT pt (B7). Bei 2x sind das 0,25–0,5 pt.
    public static let minOffset = 0.5      // Device-Pixel
    public static let maxOffset = 1.0      // Device-Pixel
    public static let maxRotation = 0.3    // Grad, ±

    /// Zufallsrichtung, Betrag in [minOffset, maxOffset] Device-Pixel, Rotation in ±maxRotation. Vor dem Runden.
    /// Zieht immer genau drei Zufallswerte.
    public static func sample<G: RandomNumberGenerator>(using rng: inout G) -> JitterSample {
        let angle = rng.nextUnit() * 2.0 * Double.pi
        let magnitude = rng.nextDouble(in: minOffset, maxOffset)
        let rotation = rng.nextDouble(in: -maxRotation, maxRotation)
        return JitterSample(dx: cos(angle) * magnitude, dy: sin(angle) * magnitude, rotation: rotation)
    }

    /// Rundet den Versatz (Eingabe in Device-Pixeln) auf ganze Device-Pixel und gibt ihn in pt zurück
    /// (1 px = 1/backingScale pt). Ergebnis: genau 1 Device-Pixel auf genau einer Achse – nie 0 (sonst wirkt der
    /// Frame wie Lag), nie diagonal (√2 px läge über der Obergrenze 1 px). Die größere Achse gewinnt.
    public static func snapped(_ s: JitterSample, backingScale: Double) -> JitterSample {
        let k = max(1.0, backingScale)
        var px = s.dx.rounded()
        var py = s.dy.rounded()
        if px != 0 && py != 0 {
            if abs(s.dx) >= abs(s.dy) { py = 0 } else { px = 0 }
        }
        if px == 0 && py == 0 {
            if abs(s.dx) >= abs(s.dy) { px = s.dx < 0 ? -1.0 : 1.0 } else { py = s.dy < 0 ? -1.0 : 1.0 }
        }
        return JitterSample(dx: px / k, dy: py / k, rotation: s.rotation)
    }
}
