import Foundation
import DropboardCore

/// Teil 4: Ansichtsmodus (Schritt 7) – Treffer-Test, Umsortieren und Löschen im Modell, JSON-Roundtrip danach,
/// Papierkorb (trash/), Stop-Motion-Sequenzen für Aufblättern/Zuklappen des Blatts.
enum ViewModeSelfTest {
    static func run(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("view: " + name, ok()) }
        func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }
        let m = LayoutMetrics.standard
        let g = CGFloat(m.grid)

        func item(_ x: Double, _ y: Double, w: Double = 220, h: Double = 147, rot: Double = 0, file: String = "x.png") -> BoardItem {
            BoardItem(id: UUID(), fileName: file, center: BoardPoint(x: x, y: y), rotation: rot,
                      size: BoardSize(width: w, height: h), addedAt: BoardClock.timestamp(Date(timeIntervalSince1970: 1_791_000_000)))
        }

        // Treffer-Test
        let a = item(200, 200)
        let b = item(300, 220)          // überlappt a, liegt darüber (später in der Liste)
        let c = item(800, 600, rot: 1.5)
        let items = [a, b, c]
        check("hitTest: leeres Papier → nil", BoardEditing.hitTest(items, at: CGPoint(x: 600, y: 100)) == nil)
        check("hitTest: nur a getroffen", BoardEditing.hitTest(items, at: CGPoint(x: 100, y: 200)) == a.id)
        check("hitTest: Überlappung → oberstes Item (b)", BoardEditing.hitTest(items, at: CGPoint(x: 250, y: 210)) == b.id)
        check("hitTest: leere Liste → nil", BoardEditing.hitTest([], at: CGPoint(x: 200, y: 200)) == nil)
        let tall = item(500, 500, w: 200, h: 20, rot: 90)   // 90° gegen den Uhrzeigersinn: steht senkrecht
        check("hitTest: 90° gedreht – 90 pt über der Mitte getroffen", BoardEditing.contains(tall, point: CGPoint(x: 500, y: 410)))
        check("hitTest: 90° gedreht – 90 pt rechts der Mitte nicht getroffen", !BoardEditing.contains(tall, point: CGPoint(x: 590, y: 500)))
        check("hitTest: Kante zählt (halbe Breite)", BoardEditing.contains(a, point: CGPoint(x: 310, y: 200)))

        // Umsortieren im Modell
        var doc = BoardDocument(items: items)
        let target = BoardEditing.snappedCenter(dragged: CGPoint(x: 611, y: 397), size: a.size.cgSize,
                                                area: CGRect(x: 48, y: 72, width: 1400, height: 800), grid: m.grid)
        check("snappedCenter liegt auf dem Grid",
              target.x.truncatingRemainder(dividingBy: g) == 0 && target.y.truncatingRemainder(dividingBy: g) == 0)
        check("snappedCenter = nächster Grid-Punkt (600,408)", target == CGPoint(x: 600, y: 408))
        let clamped = BoardEditing.snappedCenter(dragged: CGPoint(x: -500, y: 5000), size: a.size.cgSize,
                                                 area: CGRect(x: 48, y: 72, width: 1400, height: 800), grid: m.grid)
        check("snappedCenter: außerhalb losgelassen → Rahmen in der Ablagefläche",
              CGRect(x: 48, y: 72, width: 1400, height: 800).contains(BoardLayout.frame(center: clamped, size: a.size.cgSize)))
        let moved = BoardEditing.move(&doc, id: a.id, to: target, rotation: -1.25)
        check("move: liefert das geänderte Item", moved?.center == BoardPoint(target) && moved?.rotation == -1.25)
        check("move: Anzahl unverändert", doc.items.count == 3)
        check("move: Item liegt danach oben (Ende der Liste)", doc.items.last?.id == a.id)
        check("move: andere Items unverändert", doc.item(id: b.id) == b && doc.item(id: c.id) == c)
        check("move: übrige Reihenfolge bleibt (b vor c)", doc.items.map { $0.id } == [b.id, c.id, a.id])
        check("move: Datei, Größe, Zeitstempel bleiben",
              doc.item(id: a.id)?.fileName == a.fileName && doc.item(id: a.id)?.size == a.size && doc.item(id: a.id)?.addedAt == a.addedAt)
        let before = doc
        check("move: unbekannte id → nil, Dokument unverändert",
              BoardEditing.move(&doc, id: UUID(), to: .zero, rotation: 0) == nil && doc == before)

        // Löschen im Modell
        let removed = BoardEditing.delete(&doc, id: b.id)
        check("delete: liefert das entfernte Item", removed == b)
        check("delete: Item ist weg, Rest in Reihenfolge", doc.items.map { $0.id } == [c.id, a.id])
        check("delete: unbekannte id → nil", BoardEditing.delete(&doc, id: b.id) == nil && doc.items.count == 2)

        // Neue Zufallsrotation nach dem Umsortieren: wie beim Ablegen ±1–2°
        var rng = SplitMix64(seed: 2026)
        let tilts = (0..<1000).map { _ in BoardLayout.randomTilt(range: m.tiltRange, using: &rng) }
        check("neue Rotation beim Umsortieren in ±[1, 2]°", tilts.allSatisfy { abs($0) >= 1 - 1e-9 && abs($0) <= 2 + 1e-9 })

        // JSON-Roundtrip nach Umsortieren + Löschen, Papierkorb
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dropboard-selftest-view-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let store = BoardStore(boardDirectory: dir)
        do {
            try store.prepareDirectories()
            try store.save(doc)
            let loaded = try store.load()
            check("JSON-Roundtrip nach Umsortieren/Löschen: geladen == gespeichert", loaded == doc)
            check("JSON-Roundtrip: Stapelreihenfolge bleibt erhalten", loaded.items.map { $0.id } == [c.id, a.id])
            check("trash/ entsteht nicht durch prepareDirectories", !fm.fileExists(atPath: store.trashDirectory.path))

            let name = "\(UUID().uuidString).png"
            try Data("bild".utf8).write(to: store.imageURL(fileName: name))
            let trashed = try store.moveImageToTrash(fileName: name)
            check("Papierkorb: Datei liegt in trash/", trashed.deletingLastPathComponent().lastPathComponent == "trash"
                  && fm.fileExists(atPath: trashed.path) && trashed.lastPathComponent == name)
            check("Papierkorb: Datei ist nicht mehr in images/", !fm.fileExists(atPath: store.imageURL(fileName: name).path))
            check("Papierkorb: Inhalt unverändert", (try? Data(contentsOf: trashed)) == Data("bild".utf8))

            try Data("zwei".utf8).write(to: store.imageURL(fileName: name))
            let second = try store.moveImageToTrash(fileName: name)
            check("Papierkorb: gleicher Name → Suffix -1, nichts überschrieben",
                  second.lastPathComponent == name.replacingOccurrences(of: ".png", with: "-1.png")
                    && (try? Data(contentsOf: trashed)) == Data("bild".utf8))

            var threw = false
            do { _ = try store.moveImageToTrash(fileName: "fehlt.png") } catch { threw = true }
            check("Papierkorb: fehlende Datei wirft", threw)

            let outside = dir.appendingPathComponent("aussen.png")
            try Data("x".utf8).write(to: outside)
            var threwEscape = false
            do { _ = try store.moveImageToTrash(fileName: "../aussen.png") } catch { threwEscape = true }
            check("Papierkorb: ../ bricht nicht aus images/ aus", threwEscape && fm.fileExists(atPath: outside.path))

            let after = try store.load()
            check("Papierkorb berührt board.json nicht", after == doc)
        } catch {
            check("unerwarteter Fehler: \(error)", false)
        }
        check("uniqueTrashURL ohne Endung → name-1",
              BoardStore.uniqueTrashURL(in: URL(fileURLWithPath: "/t"), fileName: "abc") { $0.lastPathComponent == "abc" }
                .lastPathComponent == "abc-1")

        // Stop-Motion: Aufblättern/Zuklappen des Blatts (3 Frames)
        let full = Pose(position: CGPoint(x: 1880, y: 1050), rotation: 0, scale: 1, opacity: 1)
        let jitterOff = PlanOptions(jitter: false, reduceMotion: false, backingScale: 2)
        let jitterOn = PlanOptions(jitter: true, reduceMotion: false, backingScale: 2)
        let reduced = PlanOptions(jitter: true, reduceMotion: true, backingScale: 2)
        var r1 = SplitMix64(seed: 5), r2 = SplitMix64(seed: 5)
        check("open == StopMotionSequences.reveal (gleicher Seed)",
              ViewModeSequences.open(target: full, options: jitterOn, using: &r1)
                == StopMotionSequences.reveal(target: full, options: jitterOn, using: &r2))
        var r3 = SplitMix64(seed: 5)
        let open = ViewModeSequences.open(target: full, options: jitterOn, using: &r3)
        check("open: 3 Frames, 0.5 s, letzter Frame = voll", open.frames.count == 3 && near(open.duration, 0.5) && open.frames.last == full)

        var r4 = SplitMix64(seed: 5)
        let plainClose = ViewModeSequences.close(target: full, options: jitterOff, using: &r4)
        check("close: 3 Frames", plainClose.frames.count == ViewModeSequences.frameCount && plainClose.frames.count == 3)
        check("close: reveal rückwärts – Scales 0.85 / 0.6 / 0.6",
              near(plainClose.frames[0].scale, 0.85) && near(plainClose.frames[1].scale, 0.6) && near(plainClose.frames[2].scale, 0.6))
        check("close: Frames 0 und 1 sichtbar, Frame 2 weg (opacity 0)",
              plainClose.frames[0].opacity == 1 && plainClose.frames[1].opacity == 1 && plainClose.frames[2].opacity == 0)
        check("close: keyTimes 0, 1/3, 2/3, 1 (count == frames + 1)",
              plainClose.keyTimes.count == 4 && plainClose.keyTimes.first == 0 && plainClose.keyTimes.last == 1
                && zip(plainClose.keyTimes, plainClose.keyTimes.dropFirst()).allSatisfy { $0 < $1 })
        check("close: duration == 3 × 1/6 s, animiert", near(plainClose.duration, 0.5) && plainClose.isAnimated)
        check("close: erster Frame ist schon kleiner als voll (Start sofort, E1)", plainClose.frames[0].scale < full.scale)

        var r5 = SplitMix64(seed: 5)
        let jitterClose = ViewModeSequences.close(target: full, options: jitterOn, using: &r5)
        check("close mit Jitter: Frames 0/1 zittern (Position ≠ Anker)",
              jitterClose.frames[0].position != full.position && jitterClose.frames[1].position != full.position)
        check("close mit Jitter: letzter Frame exakt, ohne Jitter", jitterClose.frames[2].position == full.position
              && jitterClose.frames[2].rotation == full.rotation)
        var r6 = SplitMix64(seed: 5), r7 = SplitMix64(seed: 5)
        check("close: deterministisch bei gleichem Seed",
              ViewModeSequences.close(target: full, options: jitterOn, using: &r6)
                == ViewModeSequences.close(target: full, options: jitterOn, using: &r7))

        var consumed = SplitMix64(seed: 9), fresh = SplitMix64(seed: 9)
        let reducedClose = ViewModeSequences.close(target: full, options: reduced, using: &consumed)
        check("close Reduce Motion: 1 Frame (weg), nicht animiert, duration 0",
              reducedClose.frames.count == 1 && reducedClose.frames[0].opacity == 0 && !reducedClose.isAnimated && reducedClose.duration == 0)
        check("close Reduce Motion: keyTimes [0, 1], kein Zufall verbraucht",
              reducedClose.keyTimes == [0, 1] && consumed.next() == fresh.next())
        var r8 = SplitMix64(seed: 9)
        let reducedOpen = ViewModeSequences.open(target: full, options: reduced, using: &r8)
        check("open Reduce Motion: 1 Frame = voll, nicht animiert", reducedOpen.frames == [full] && !reducedOpen.isAnimated)
    }
}
