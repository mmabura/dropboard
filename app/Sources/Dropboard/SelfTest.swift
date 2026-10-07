import Foundation
import DropboardCore

/// `Dropboard --selftest`: Assertions gegen die reine Logik, ohne XCTest und ohne Fenster. Exit 0 = alles PASS.
/// Teil 1: Stop-Motion-Planer (unverändert aus spikes/stopmotion/Sources/stopmotion-demo/SelfTest.swift).
/// Teil 2: Layout (Grid-Snap, Free-Slot-Finder, Konfliktfreiheit). Teil 3: Store (JSON-Roundtrip in temporärem Ordner).
/// Teil 4: Ansichtsmodus (SelfTestViewMode.swift).
final class SelfTestChecker {
    private(set) var total = 0
    private(set) var failures = 0

    func check(_ name: String, _ ok: Bool) {
        total += 1
        if ok {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }
}

enum SelfTest {
    static func run() -> Bool {
        let t = SelfTestChecker()
        stopMotion(t)
        LayoutSelfTest.run(t)
        StoreSelfTest.run(t)
        ViewModeSelfTest.run(t)
        print("\(t.total - t.failures)/\(t.total) PASS" + (t.failures == 0 ? "" : ", \(t.failures) FAIL"))
        fflush(stdout)
        return t.failures == 0
    }

    // MARK: Teil 1 – Stop-Motion (Spike-Tests, nur check/near als Shims)

    private static func stopMotion(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("stopmotion: " + name, ok()) }
        func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

        let jitterOn = PlanOptions(jitter: true, reduceMotion: false, backingScale: 2)
        let jitterOff = PlanOptions(jitter: false, reduceMotion: false, backingScale: 2)
        let reduced = PlanOptions(jitter: true, reduceMotion: true, backingScale: 2)
        let a = Pose(position: CGPoint(x: 400, y: 300), rotation: 1.5, scale: 1, opacity: 1)
        let b = Pose(position: CGPoint(x: 760, y: 300), rotation: -1, scale: 1, opacity: 1)

        /// Alle vier Sequenzen mit gegebenem Seed: (Name, Plan, erwarteter Endzustand).
        func plans(_ options: PlanOptions, seed: UInt64) -> [(String, StopMotionPlan, Pose)] {
            var rng = SplitMix64(seed: seed)
            let drop = StopMotionSequences.drop(target: a, options: options, using: &rng)
            let reveal = StopMotionSequences.reveal(target: a, options: options, using: &rng)
            let move = StopMotionSequences.move(from: a, to: b, options: options, using: &rng)
            let delete = StopMotionSequences.delete(from: a, options: options, using: &rng)
            var gone = a
            gone.scale = a.scale * StopMotionSequences.deleteScale
            gone.opacity = 0
            return [("drop", drop, a), ("reveal", reveal, a), ("move", move, b), ("delete", delete, gone)]
        }

        // Uhr
        check("clock: fps == 6", StopMotionClock.fps == 6)
        check("clock: frameDuration == 1/6", near(StopMotionClock.frameDuration, 1.0 / 6.0))

        // keyTimes
        for (name, plan, _) in plans(jitterOn, seed: 1) {
            check("\(name): keyTimes.count == frames.count + 1", plan.keyTimes.count == plan.frames.count + 1)
            check("\(name): keyTimes beginnt bei 0, endet bei 1", plan.keyTimes.first == 0 && plan.keyTimes.last == 1)
            check("\(name): keyTimes streng aufsteigend", zip(plan.keyTimes, plan.keyTimes.dropFirst()).allSatisfy { $0 < $1 })
            check("\(name): duration == frames * 1/6 s", near(plan.duration, Double(plan.frames.count) / 6.0))
        }

        // Frame-Anzahlen der fertigen Sequenzen
        let p = plans(jitterOn, seed: 1)
        check("drop: 2 Frames", p[0].1.frames.count == 2)
        check("reveal: 3 Frames", p[1].1.frames.count == 3)
        check("delete: 2 Frames", p[3].1.frames.count == 2)
        check("move: Frame-Anzahl nach Distanz (50->2, 240->2, 360->3, 480->4, 5000->4)",
              [50.0, 240, 360, 480, 5000].map { StopMotionSequences.moveFrameCount(distance: $0) } == [2, 2, 3, 4, 4])

        // Determinismus
        check("Determinismus: gleicher Seed -> identische Pläne", plans(jitterOn, seed: 42).map { $0.1 } == plans(jitterOn, seed: 42).map { $0.1 })
        check("anderer Seed -> anderer Jitter", plans(jitterOn, seed: 42).map { $0.1 } != plans(jitterOn, seed: 43).map { $0.1 })
        var u1 = SplitMix64(seed: 9), u2 = SplitMix64(seed: 9)
        check("SplitMix64: gleicher Seed -> gleiche Folge", (0..<100).allSatisfy { _ in u1.next() == u2.next() })
        var ur = SplitMix64(seed: 5)
        check("nextUnit() liegt in [0, 1)", (0..<10_000).allSatisfy { _ in let v = ur.nextUnit(); return v >= 0 && v < 1 })

        // Letzter Frame == Endzustand (mit Jitter an, mehrere Seeds)
        var endsOK = true
        for seed in UInt64(1)...20 {
            for (_, plan, end) in plans(jitterOn, seed: seed) where plan.frames.last != end { endsOK = false }
        }
        check("letzter Frame == Endzustand exakt, ohne Jitter (4 Sequenzen x 20 Seeds)", endsOK)

        // Jitter-Betrag vor dem Runden
        var jr = SplitMix64(seed: 77)
        var magOK = true, rotOK = true
        for _ in 0..<10_000 {
            let s = StopMotionJitter.sample(using: &jr)
            let m = (s.dx * s.dx + s.dy * s.dy).squareRoot()
            if m < 0.5 - 1e-9 || m > 1.0 + 1e-9 { magOK = false }
            if abs(s.rotation) > 0.3 + 1e-9 { rotOK = false }
        }
        check("Jitter: Betrag in [0.5, 1.0] pt (vor Rundung, 10000 Samples)", magOK)
        check("Jitter: Rotation in +-0.3 Grad (10000 Samples)", rotOK)

        // Rundung auf Device-Pixel + Jitter an/aus
        for scale in [1.0, 2.0] {
            let on = PlanOptions(jitter: true, reduceMotion: false, backingScale: scale)
            let off = PlanOptions(jitter: false, reduceMotion: false, backingScale: scale)
            var r1 = SplitMix64(seed: 3), r2 = SplitMix64(seed: 3)
            let jittered = StopMotionSequences.reveal(target: a, options: on, using: &r1)
            let plain = StopMotionSequences.reveal(target: a, options: off, using: &r2)
            var snapOK = true, movedOK = true
            for i in 0..<(jittered.frames.count - 1) {
                let dx = Double(jittered.frames[i].position.x - plain.frames[i].position.x) * scale
                let dy = Double(jittered.frames[i].position.y - plain.frames[i].position.y) * scale
                if abs(dx - dx.rounded()) > 1e-6 || abs(dy - dy.rounded()) > 1e-6 { snapOK = false }
                if dx == 0 && dy == 0 { movedOK = false }
            }
            check("Jitter-Versatz ist ganzzahliges Vielfaches von 1 Device-Pixel (Backing-Scale \(scale))", snapOK)
            check("Jitter-Versatz ist nie 0 (Backing-Scale \(scale))", movedOK)
        }
        var rOff = SplitMix64(seed: 3)
        let plainReveal = StopMotionSequences.reveal(target: a, options: jitterOff, using: &rOff)
        check("Jitter aus: reveal-Scales 0.6 / 0.85 / 1.0",
              near(plainReveal.frames[0].scale, 0.6) && near(plainReveal.frames[1].scale, 0.85) && near(plainReveal.frames[2].scale, 1.0))
        check("Jitter aus: Rotation/Position unverändert", plainReveal.frames.allSatisfy { $0.position == a.position && near($0.rotation, a.rotation) })

        // drop
        var rDrop = SplitMix64(seed: 3)
        let plainDrop = StopMotionSequences.drop(target: a, options: jitterOff, using: &rDrop)
        check("drop: Frame 0 groß (1.08) und ohne Kipp", near(plainDrop.frames[0].scale, 1.08) && near(plainDrop.frames[0].rotation, 0))
        check("drop: Frame 1 = final mit Kipp", plainDrop.frames[1] == a && a.rotation != 0)

        // move
        var rMove = SplitMix64(seed: 3)
        let plainMove = StopMotionSequences.move(from: a, to: b, options: jitterOff, using: &rMove)
        check("move: gleichmäßig gestuft (360 pt -> 3 Frames je 120 pt)",
              plainMove.frames.count == 3 && (0..<3).allSatisfy { near(Double(plainMove.frames[$0].position.x), 400 + 120.0 * Double($0 + 1)) })
        check("move: erster Frame ist schon weg von A (Start sofort)", plainMove.frames[0].position != a.position)

        // delete
        var rDel = SplitMix64(seed: 3)
        let del = StopMotionSequences.delete(from: a, options: jitterOn, using: &rDel)
        check("delete: Frame 0 leicht kleiner und sichtbar, Frame 1 opacity 0",
              del.frames[0].scale < 1 && del.frames[0].opacity == 1 && del.frames[1].opacity == 0)

        // Reduce Motion
        for (name, plan, end) in plans(reduced, seed: 1) {
            check("reduceMotion \(name): genau 1 Frame == Endzustand, nicht animiert", plan.frames == [end] && !plan.isAnimated && plan.duration == 0)
            check("reduceMotion \(name): keyTimes [0, 1] (count == frames + 1)", plan.keyTimes == [0, 1])
        }
        var consumed = SplitMix64(seed: 7), fresh = SplitMix64(seed: 7)
        _ = StopMotionSequences.drop(target: a, options: reduced, using: &consumed)
        check("reduceMotion verbraucht keine Zufallswerte (kein Jitter)", consumed.next() == fresh.next())

        // Kein Frame nach dem Ende
        let timed = plans(jitterOn, seed: 1)[1].1   // reveal, 3 Frames, 0.5 s
        check("frame(at:) vor dem Start ist nil", timed.frame(at: -0.001) == nil)
        check("frame(at: 0) == erster Frame", timed.frame(at: 0) == timed.frames[0])
        check("frame(at: 1.01 * 1/6) == zweiter Frame", timed.frame(at: 1.01 / 6.0) == timed.frames[1])
        check("frame(at: duration - 1 ms) == letzter Frame", timed.frame(at: timed.duration - 0.001) == timed.frames.last)
        check("kein Frame ab dem Ende (duration, duration + 10 s)", timed.frame(at: timed.duration) == nil && timed.frame(at: timed.duration + 10) == nil)
        check("kein Frame bei nicht animiertem Plan", plans(reduced, seed: 1)[0].1.frame(at: 0) == nil)
    }
}
