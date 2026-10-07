import AppKit
import ImageIO
import QuartzCore
import DropboardCore

/// Beschnitt (E11): Core-Logik (Klemmen, Griffe inkl. ⇧, Verschieben, „sichtbarer Teil bleibt an Ort“ inkl. Rotation,
/// Zurücksetzen, Treffer-Test, Sequenzen, Modell), Codable alt/neu, Dekodier-Zielgröße (rein und über ImageIO),
/// contentsRect-Ursprung per Bitmap und die Szene (Geometrie, Overlay). Eingetragen in SelfTest.run.
enum CropSelfTest {
    static func run(_ t: SelfTestChecker) {
        basics(t)
        handles(t)
        panAndPlacement(t)
        editor(t)
        sequencesAndModel(t)
        codable(t)
        decoding(t)
        // Szene und Layer-Rendering sind @MainActor; der Selftest läuft synchron auf dem Main Thread (wie FixC).
        // ⚠️ VERIFIZIEREN (Muster aus SelfTestFixC/main.swift): MainActor.assumeIsolated aus nicht isoliertem Kontext.
        MainActor.assumeIsolated {
            contentsRectBitmap(t)
            scene(t)
        }
    }

    // MARK: Hilfen

    private static func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }
    private static func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-9) -> Bool { abs(a - b) <= eps }
    private static func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 1e-6) -> Bool {
        abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps
    }
    private static func near(_ a: CGSize, _ b: CGSize, _ eps: CGFloat = 1e-6) -> Bool {
        abs(a.width - b.width) <= eps && abs(a.height - b.height) <= eps
    }
    private static func near(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-6) -> Bool {
        near(a.origin, b.origin, eps) && near(a.size, b.size, eps)
    }
    private static func near(_ a: BoardCrop?, _ b: BoardCrop?, _ eps: Double = 1e-9) -> Bool {
        guard let a = a, let b = b else { return a == nil && b == nil }
        return near(a.x, b.x, eps) && near(a.y, b.y, eps) && near(a.width, b.width, eps) && near(a.height, b.height, eps)
    }
    private static func inside(_ c: BoardCrop) -> Bool {
        c.x >= -1e-12 && c.y >= -1e-12 && c.maxX <= 1 + 1e-12 && c.maxY <= 1 + 1e-12 && c.width > 0 && c.height > 0
    }

    // MARK: 1 – Normieren, Mindestgröße, Klemmen

    private static func basics(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("crop: " + name, ok) }
        check("ganzes Bild ist isFull", BoardCrop.full.isFull)
        check("effective: nil und ganzes Bild → nil", CropMath.effective(nil) == nil && CropMath.effective(.full) == nil)
        check("effective: Breite 0 / NaN → nil (unbrauchbar = ganzes Bild)",
              CropMath.effective(BoardCrop(x: 0, y: 0, width: 0, height: 0.5)) == nil
                && CropMath.effective(BoardCrop(x: .nan, y: 0, width: 0.5, height: 0.5)) == nil)
        check("effective: in [0, 1] verschoben",
              near(CropMath.effective(BoardCrop(x: -0.1, y: 0.8, width: 0.5, height: 0.5)),
                   BoardCrop(x: 0, y: 0.5, width: 0.5, height: 0.5)))

        let m = CropMath.minSize(fullSize: CGSize(width: 220, height: 147))
        check("Mindestgröße 24 pt bei 220×147 pt (0.109 / 0.163)", near(m.width, 24.0 / 220) && near(m.height, 24.0 / 147))
        let big = CropMath.minSize(fullSize: CGSize(width: 4000, height: 3000))
        check("Mindestgröße 2 % bei großem Bild", near(big.width, 0.02) && near(big.height, 0.02))
        let tiny = CropMath.minSize(fullSize: CGSize(width: 10, height: 10))
        check("Mindestgröße höchstens das ganze Bild (10 pt)", tiny.width == 1 && tiny.height == 1)

        let f = CGSize(width: 1000, height: 1000)
        check("clamp: zu weit rechts/unten → ins Bild geschoben",
              near(CropMath.clamp(BoardCrop(x: 0.9, y: 0.9, width: 0.5, height: 0.5), fullSize: f),
                   BoardCrop(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
        check("clamp: zu klein → Mindestgröße (24 pt = 0.024)",
              near(CropMath.clamp(BoardCrop(x: 0.3, y: 0.3, width: 0.001, height: 0.001), fullSize: f),
                   BoardCrop(x: 0.3, y: 0.3, width: 0.024, height: 0.024)))
        check("clamp: unbrauchbar → ganzes Bild",
              CropMath.clamp(BoardCrop(x: .infinity, y: 0, width: 1, height: 1), fullSize: f) == .full)

        check("contentsRect: Ursprung oben = Crop unverändert",
              near(CropMath.contentsRect(BoardCrop(x: 0.1, y: 0.2, width: 0.3, height: 0.4), originTop: true),
                   CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), 1e-12))
        check("contentsRect: Ursprung unten → y = 1 − y − h",
              near(CropMath.contentsRect(BoardCrop(x: 0.1, y: 0.2, width: 0.3, height: 0.4), originTop: false),
                   CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.4), 1e-12))
        check("contentsRect: ohne Crop = Einheitsrechteck",
              CropMath.contentsRect(nil, originTop: false) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: 2 – Griffe (ohne/mit ⇧)

    private static func handles(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("crop handle: " + name, ok) }
        let f = CGSize(width: 200, height: 100)   // Mindestgröße 0.12 × 0.24
        func drag(_ h: CropHandle, _ start: BoardCrop, _ dx: CGFloat, _ dy: CGFloat, shift: Bool = false) -> BoardCrop {
            CropMath.dragHandle(h, start: start, delta: CGPoint(x: dx, y: dy), fullSize: f, keepAspect: shift)
        }
        let mid = BoardCrop(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        check("rechte Kante −50 pt → Breite 0.75", near(drag(.right, .full, -50, 0), BoardCrop(x: 0, y: 0, width: 0.75, height: 1)))
        check("linke Kante weit nach rechts → stoppt bei Mindestgröße",
              near(drag(.left, .full, 300, 0), BoardCrop(x: 0.88, y: 0, width: 0.12, height: 1)))
        check("linke Kante über den Bildrand → stoppt bei 0",
              near(drag(.left, mid, -50, 0), BoardCrop(x: 0, y: 0.2, width: 0.6, height: 0.4)))
        check("Ecke oben links bewegt zwei Kanten", near(drag(.topLeft, .full, 20, 10), BoardCrop(x: 0.1, y: 0.1, width: 0.9, height: 0.9)))
        check("untere Kante −30 pt → Höhe 0.7", near(drag(.bottom, .full, 0, -30), BoardCrop(x: 0, y: 0, width: 1, height: 0.7)))
        check("obere Kante ändert x/Breite nicht", { let c = drag(.top, mid, 40, 10); return c.x == mid.x && c.width == mid.width }())
        check("Kante ignoriert die Querrichtung (rechts, dy)", near(drag(.right, mid, 0, 30), mid))

        check("⇧ Ecke unten rechts: Faktor 1.5, Verhältnis bleibt",
              near(drag(.bottomRight, mid, 40, 0, shift: true), BoardCrop(x: 0.2, y: 0.2, width: 0.6, height: 0.6)))
        check("⇧ Ecke unten rechts: am Bildrand begrenzt, Verhältnis bleibt",
              near(drag(.bottomRight, mid, 200, 0, shift: true), BoardCrop(x: 0.2, y: 0.2, width: 0.8, height: 0.8)))
        check("⇧ Ecke oben links: Gegenecke fest, am Rand begrenzt",
              near(drag(.topLeft, mid, -100, 0, shift: true), BoardCrop(x: 0, y: 0, width: 0.6, height: 0.6)))
        check("⇧ rechte Kante: Höhe wächst symmetrisch um die Mitte",
              near(drag(.right, BoardCrop(x: 0.2, y: 0.3, width: 0.4, height: 0.4), 20, 0, shift: true),
                   BoardCrop(x: 0.2, y: 0.25, width: 0.5, height: 0.5)))
        check("⇧ verkleinern: stoppt bei Mindestgröße, Verhältnis bleibt",
              near(drag(.bottomRight, mid, -80, -40, shift: true), BoardCrop(x: 0.2, y: 0.2, width: 0.24, height: 0.24)))

        // Zufall: ⇧ hält das Verhältnis exakt, alles bleibt im Bild und über der Mindestgröße.
        var rng = SplitMix64(seed: 1107)
        var ratioOK = true, insideOK = true, minOK = true, plainOK = true
        let fr = CGSize(width: 220, height: 147)
        let minS = CropMath.minSize(fullSize: fr)
        for _ in 0..<500 {
            let w = rng.nextDouble(in: 0.2, 0.9), h = rng.nextDouble(in: 0.2, 0.9)
            let start = CropMath.clamp(BoardCrop(x: rng.nextDouble(in: 0, 1 - w), y: rng.nextDouble(in: 0, 1 - h),
                                                 width: w, height: h), fullSize: fr)
            let handle = CropHandle.allCases[Int(rng.nextUnit() * Double(CropHandle.allCases.count)) % CropHandle.allCases.count]
            let delta = CGPoint(x: rng.nextDouble(in: -300, 300), y: rng.nextDouble(in: -300, 300))
            let a = CropMath.dragHandle(handle, start: start, delta: delta, fullSize: fr, keepAspect: true)
            if abs(a.width / a.height - start.width / start.height) > 1e-9 * (start.width / start.height) { ratioOK = false }
            if !inside(a) { insideOK = false }
            if a.width < minS.width - 1e-9 || a.height < minS.height - 1e-9 { minOK = false }
            let b = CropMath.dragHandle(handle, start: start, delta: delta, fullSize: fr, keepAspect: false)
            if !inside(b) || b.width < minS.width - 1e-9 || b.height < minS.height - 1e-9 { plainOK = false }
        }
        check("⇧ Verhältnis exakt (500 Zufallsfälle, alle 8 Griffe)", ratioOK)
        check("⇧ Ergebnis liegt im Bild", insideOK)
        check("⇧ Ergebnis ≥ Mindestgröße", minOK)
        check("ohne ⇧: im Bild und ≥ Mindestgröße (500 Zufallsfälle)", plainOK)
    }

    // MARK: 3 – Verschieben, „sichtbarer Teil bleibt an Ort und Größe“

    private static func panAndPlacement(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("crop place: " + name, ok) }
        let f = CGSize(width: 200, height: 100)
        let mid = BoardCrop(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        check("pan: Bild folgt der Maus, Crop wandert entgegen",
              near(CropMath.pan(start: mid, delta: CGPoint(x: 20, y: 10), fullSize: f), BoardCrop(x: 0.1, y: 0.1, width: 0.4, height: 0.4)))
        check("pan: begrenzt am rechten Bildrand", near(CropMath.pan(start: mid, delta: CGPoint(x: -1000, y: 0), fullSize: f).x, 0.6))
        check("pan: begrenzt am linken Bildrand", near(CropMath.pan(start: mid, delta: CGPoint(x: 1000, y: 0), fullSize: f).x, 0))
        check("pan: Größe bleibt", { let c = CropMath.pan(start: mid, delta: CGPoint(x: 33, y: -7), fullSize: f)
            return c.width == mid.width && c.height == mid.height }())

        let c0 = CGPoint(x: 500, y: 500), s0 = CGSize(width: 100, height: 50)
        let rightHalf = BoardCrop(x: 0.5, y: 0, width: 0.5, height: 1)
        let p0 = CropMath.placement(center: c0, size: s0, rotation: 0, old: nil, new: rightHalf)
        check("Rotation 0: rechte Hälfte → Mitte +25 pt, Größe 50×50", near(p0.center, CGPoint(x: 525, y: 500)) && near(p0.size, CGSize(width: 50, height: 50)))
        let p90 = CropMath.placement(center: c0, size: s0, rotation: 90, old: nil, new: rightHalf)
        check("Rotation 90° (gegen den Uhrzeigersinn): rechte Hälfte liegt oben → Mitte (500, 475)",
              near(p90.center, CGPoint(x: 500, y: 475)) && near(p90.size, CGSize(width: 50, height: 50)))
        let p180 = CropMath.placement(center: c0, size: s0, rotation: 180, old: nil, new: rightHalf)
        check("Rotation 180°: rechte Hälfte liegt links → Mitte (475, 500)", near(p180.center, CGPoint(x: 475, y: 500)))
        check("Drehung lokal → Board → lokal ist die Identität",
              near(CropMath.toLocal(CropMath.toBoard(CGPoint(x: 13, y: -7), rotation: 37), rotation: 37), CGPoint(x: 13, y: -7), 1e-9))

        // Kernaussage E11 mit Zufall: jeder Bildpunkt im neuen Ausschnitt liegt vorher und nachher an derselben
        // Board-Stelle (gleiche Rotation), die volle Größe F bleibt.
        var rng = SplitMix64(seed: 2026)
        var stayOK = true, fullOK = true
        for i in 0..<300 {
            let rotation = rng.nextDouble(in: -30, 30)
            let center = CGPoint(x: rng.nextDouble(in: 200, 1200), y: rng.nextDouble(in: 200, 800))
            let size = CGSize(width: rng.nextDouble(in: 60, 220), height: rng.nextDouble(in: 60, 220))
            func randomCrop() -> BoardCrop {
                let w = rng.nextDouble(in: 0.15, 1), h = rng.nextDouble(in: 0.15, 1)
                return BoardCrop(x: rng.nextDouble(in: 0, 1 - w), y: rng.nextDouble(in: 0, 1 - h), width: w, height: h)
            }
            let old: BoardCrop? = i % 3 == 0 ? nil : randomCrop()
            let new = randomCrop()
            let fullBefore = CropMath.fullSize(itemSize: size, crop: old)
            let clampedNew = CropMath.clamp(new, fullSize: fullBefore)
            let p = CropMath.placement(center: center, size: size, rotation: rotation, old: old, new: new)
            for (u, v) in [(clampedNew.midX, clampedNew.midY), (clampedNew.minX, clampedNew.minY), (clampedNew.maxX, clampedNew.maxY)] {
                let before = CropMath.boardPoint(imageU: u, imageV: v, center: center, size: size, rotation: rotation, crop: old)
                let after = CropMath.boardPoint(imageU: u, imageV: v, center: p.center, size: p.size, rotation: rotation, crop: clampedNew)
                if !near(before, after, 1e-6) { stayOK = false }
            }
            if !near(CropMath.fullSize(itemSize: p.size, crop: clampedNew), fullBefore, 1e-6) { fullOK = false }
        }
        check("sichtbarer Teil bleibt an Ort und Größe (300 Zufallsfälle, Rotation ±30°, je 3 Bildpunkte)", stayOK)
        check("volle Größe F bleibt beim Beschneiden gleich (kein Neu-Dekodieren nötig)", fullOK)
    }

    // MARK: 4 – Editor: Treffer, Verschieben mit festem Rahmen, Zurücksetzen

    private static func editor(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("crop editor: " + name, ok) }
        let crop = BoardCrop(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        // Item 80×40 pt mit diesem Crop → F = 200×100; Mitte des sichtbaren Teils bei (500, 400).
        let e = CropEditor(itemCenter: CGPoint(x: 500, y: 400), itemSize: CGSize(width: 80, height: 40), crop: crop, rotation: 0)
        check("F = Item-Größe ÷ Crop (200×100)", near(e.fullSize, CGSize(width: 200, height: 100)))
        check("Bildmitte so, dass der Ausschnitt am Ort bleibt (520, 410)", near(e.imageCenter, CGPoint(x: 520, y: 410)))
        check("Rahmen = bisheriges Item (Mitte, Größe)",
              near(e.frameCenter, CGPoint(x: 500, y: 400)) && near(e.frameSize, CGSize(width: 80, height: 40)))
        check("Griff oben links bei (460, 380)", near(e.handlePoint(.topLeft), CGPoint(x: 460, y: 380)))
        check("Treffer: Ecke oben links", e.hit(CGPoint(x: 461, y: 381), tolerance: 10) == .handle(.topLeft))
        check("Treffer: rechte Kante", e.hit(CGPoint(x: 540, y: 403), tolerance: 10) == .handle(.right))
        check("Treffer: im Rahmen → verschieben", e.hit(CGPoint(x: 500, y: 400), tolerance: 10) == .frame)
        check("Treffer: abgedunkeltes Bild außerhalb des Rahmens", e.hit(CGPoint(x: 445, y: 400), tolerance: 10) == .image)
        check("Treffer: neben dem Bild → übernehmen", e.hit(CGPoint(x: 700, y: 400), tolerance: 10) == .outside)
        let r30 = CropEditor(itemCenter: CGPoint(x: 500, y: 400), itemSize: CGSize(width: 80, height: 40), crop: crop, rotation: 30)
        check("Treffer gedreht (30°): Griffpunkt oben trifft .top", r30.hit(r30.handlePoint(.top), tolerance: 10) == .handle(.top))
        check("gedreht: Rahmenmitte bleibt beim Öffnen am Ort", near(r30.frameCenter, CGPoint(x: 500, y: 400)))

        var panned = e
        panned.pan(from: e, mouseDelta: CGPoint(x: 20, y: 10))
        check("pan: Rahmen bleibt, Bild folgt der Maus",
              near(panned.frameCenter, e.frameCenter) && near(panned.imageCenter, CGPoint(x: 540, y: 420))
                && near(panned.crop, BoardCrop(x: 0.1, y: 0.1, width: 0.4, height: 0.4)))
        var clampedPan = e
        clampedPan.pan(from: e, mouseDelta: CGPoint(x: 500, y: 0))
        check("pan begrenzt: Rahmen bleibt trotzdem fest, Bild nur bis zum Rand",
              near(clampedPan.frameCenter, e.frameCenter) && near(clampedPan.crop.x, 0) && near(clampedPan.imageCenter.x, 560))
        var rotPan = r30
        rotPan.pan(from: r30, mouseDelta: CGPoint(x: 7, y: -3))
        check("pan gedreht: Rahmen bleibt fest", near(rotPan.frameCenter, r30.frameCenter))
        var again = e
        again.pan(from: e, mouseDelta: CGPoint(x: 20, y: 10))
        again.pan(from: e, mouseDelta: CGPoint(x: 20, y: 10))
        check("aus Startzustand + Gesamtweg: zweimal gleiches Ereignis = gleiches Ergebnis (kein Driften)", again == panned)

        var handled = e
        handled.dragHandle(.right, from: e, mouseDelta: CGPoint(x: 20, y: 0), keepAspect: false)
        check("Griff: Bild bleibt liegen, Rahmen wächst nach rechts",
              near(handled.imageCenter, e.imageCenter) && near(handled.frameSize, CGSize(width: 100, height: 40))
                && near(handled.frameCenter, CGPoint(x: 510, y: 400)))

        var reset = e
        reset.reset()
        check("R: ganzes Bild, Bild bleibt liegen, Rahmen = ganzes Bild",
              reset.crop == .full && near(reset.imageCenter, e.imageCenter) && near(reset.frameCenter, e.imageCenter)
                && near(reset.frameSize, CGSize(width: 200, height: 100)))
        check("R: Ergebnis ohne Crop (nil wird nicht geschrieben)", reset.result.crop == nil)
        check("Ergebnis unverändert geöffnet = altes Item",
              near(e.result.crop, crop) && near(e.result.center, CGPoint(x: 500, y: 400)) && near(e.result.size, CGSize(width: 80, height: 40)))
    }

    // MARK: 5 – Sequenzen und Modell

    private static func sequencesAndModel(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("crop model: " + name, ok) }
        let from = Pose(position: CGPoint(x: 100, y: 100), rotation: 1.6)
        let to = Pose(position: CGPoint(x: 104, y: 98), rotation: 0)
        var rng = SplitMix64(seed: 5)
        let turn = CropSequences.turn(from: from, to: to, options: PlanOptions(jitter: true, backingScale: 2), using: &rng)
        check("Öffnen: 2 Frames à 1/6 s, letzter = gerade exakt",
              turn.frames.count == 2 && turn.frames.last == to && near(turn.duration, 2.0 / 6.0) && turn.keyTimes == [0, 0.5, 1])
        check("Öffnen: Frame 0 halb gedreht (±Jitter 0,3°)", abs(turn.frames[0].rotation - 0.8) <= StopMotionJitter.maxRotation + 1e-9)
        var r2 = SplitMix64(seed: 5)
        let reduced = CropSequences.turn(from: from, to: to, options: PlanOptions(jitter: true, reduceMotion: true), using: &r2)
        check("Reduce Motion: 1 Frame = Ziel, nicht animiert", reduced.frames == [to] && !reduced.isAnimated)
        let target = Pose(position: CGPoint(x: 300, y: 200), rotation: -1.4)
        var r3 = SplitMix64(seed: 6)
        let settle = CropSequences.settle(from: Pose(position: CGPoint(x: 300, y: 200), rotation: 0), to: target,
                                          options: PlanOptions(jitter: true, backingScale: 2), using: &r3)
        check("Übernehmen: 2 Frames, Frame 0 gerade (±Jitter), letzter = final mit Kipp",
              settle.frames.count == 2 && abs(settle.frames[0].rotation) <= StopMotionJitter.maxRotation + 1e-9 && settle.frames[1] == target)
        check("Crop-Sequenzen führen keine Schatten-Spur", !settle.frames.contains { $0.shadow != 1 } && !turn.frames.contains { $0.shadow != 1 })

        func item(_ x: Double) -> BoardItem {
            BoardItem(id: UUID(), fileName: "x.png", center: BoardPoint(x: x, y: 100), rotation: 1,
                      size: BoardSize(width: 220, height: 147), addedAt: BoardClock.timestamp(Date(timeIntervalSince1970: 1_791_000_000)))
        }
        let a = item(100), b = item(400), c = item(700)
        var doc = BoardDocument(items: [a, b, c])
        let crop = BoardCrop(x: 0.25, y: 0, width: 0.5, height: 1)
        let applied = CropEditing.apply(&doc, id: a.id, crop: crop, center: CGPoint(x: 110, y: 100),
                                        size: CGSize(width: 110, height: 147), rotation: -1.5)
        check("apply: Crop, Größe, Mitte, Rotation gesetzt",
              applied?.crop == crop && applied?.size == BoardSize(width: 110, height: 147)
                && applied?.center == BoardPoint(x: 110, y: 100) && applied?.rotation == -1.5)
        check("apply: Item oben, übrige Reihenfolge bleibt", doc.items.map { $0.id } == [b.id, c.id, a.id])
        check("apply: Datei und Zeitstempel bleiben", doc.item(id: a.id)?.fileName == a.fileName && doc.item(id: a.id)?.addedAt == a.addedAt)
        CropEditing.apply(&doc, id: a.id, crop: .full, center: CGPoint(x: 110, y: 100), size: CGSize(width: 220, height: 147), rotation: 1)
        check("apply: ganzes Bild → crop nil", doc.item(id: a.id)?.crop == nil)
        let before = doc
        check("apply: unbekannte id → nil, Dokument unverändert",
              CropEditing.apply(&doc, id: UUID(), crop: crop, center: .zero, size: .zero, rotation: 0) == nil && doc == before)
    }

    // MARK: 6 – Codable alt/neu

    private static func codable(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("crop codable: " + name, ok) }
        let oldJSON = """
        {
          "items" : [
            {
              "addedAt" : "2026-10-01T12:00:00Z",
              "center" : { "x" : 120, "y" : 120 },
              "fileName" : "6F9619FF-8B86-D011-B42D-00C04FC964FF.png",
              "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
              "rotation" : -1.5,
              "size" : { "height" : 147, "width" : 220 },
              "source" : { "app" : "com.apple.Safari", "route" : "imageData" }
            }
          ],
          "version" : 1
        }
        """
        let old = try? BoardStore.makeDecoder().decode(BoardDocument.self, from: Data(oldJSON.utf8))
        check("alte board.json ohne crop lädt, crop = nil", old?.items.count == 1 && old?.items[0].crop == nil)
        let newJSON = oldJSON.replacingOccurrences(of: "\"rotation\" : -1.5,",
                                                   with: "\"rotation\" : -1.5, \"crop\" : { \"x\" : 0.25, \"y\" : 0, \"width\" : 0.5, \"height\" : 0.75 },")
        let new = try? BoardStore.makeDecoder().decode(BoardDocument.self, from: Data(newJSON.utf8))
        check("neue board.json mit crop lädt", new?.items[0].crop == BoardCrop(x: 0.25, y: 0, width: 0.5, height: 0.75))

        let withCrop = BoardItem(id: UUID(), fileName: "c.png", center: BoardPoint(x: 1, y: 2), rotation: 0.5,
                                 size: BoardSize(width: 110, height: 147), addedAt: BoardClock.timestamp(),
                                 source: ItemSource(route: "fileURL"), crop: BoardCrop(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let doc = BoardDocument(items: [withCrop])
        let data = try? BoardStore.makeEncoder().encode(doc)
        let back = data.flatMap { try? BoardStore.makeDecoder().decode(BoardDocument.self, from: $0) }
        check("Roundtrip mit crop verlustfrei", back == doc)
        check("crop steht als Schlüssel \"crop\" in der Datei", data.map { String(decoding: $0, as: UTF8.self).contains("\"crop\"") } == true)
        let plain = try? BoardStore.makeEncoder().encode(BoardDocument(items: [BoardItem(
            id: UUID(), fileName: "p.png", center: BoardPoint(x: 0, y: 0), rotation: 0, size: BoardSize(width: 1, height: 1),
            addedAt: BoardClock.timestamp())]))
        check("crop nil wird nicht geschrieben (Datei bleibt für alte Versionen gleich)",
              plain.map { !String(decoding: $0, as: UTF8.self).contains("crop") } == true)
    }

    // MARK: 7 – Dekodier-Zielgröße

    private static func decoding(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("crop decode: " + name, ok) }
        check("ohne Crop: wie bisher (220×147 pt @2x → 440 px)",
              CropMath.decodeMaxPixel(displaySize: CGSize(width: 220, height: 147), crop: nil, scale: 2) == 440)
        check("halbe Breite: ganzes Bild in voller Größe (110×147 → 440 px)",
              CropMath.decodeMaxPixel(displaySize: CGSize(width: 110, height: 147),
                                      crop: BoardCrop(x: 0.5, y: 0, width: 0.5, height: 1), scale: 2) == 440)
        check("kleiner Ausschnitt: bezogen aufs ganze Bild größer (55×36,75 bei 25 % → 440 px statt 110)",
              CropMath.decodeMaxPixel(displaySize: CGSize(width: 55, height: 36.75),
                                      crop: BoardCrop(x: 0.25, y: 0.25, width: 0.25, height: 0.25), scale: 2) == 440)
        check("Rundungsrauschen (220,00000000000003 pt) ergibt kein Extra-Pixel",
              CropMath.decodeMaxPixel(displaySize: CGSize(width: 66, height: 44),
                                      crop: BoardCrop(x: 0.1, y: 0.1, width: 0.3, height: 0.3), scale: 2) == 440)
        check("Obergrenze 4096 px", CropMath.decodeMaxPixel(displaySize: CGSize(width: 3000, height: 2000), crop: nil, scale: 2) == 4096
                && CropMath.decodeMaxPixel(displaySize: CGSize(width: 50, height: 50),
                                           crop: BoardCrop(x: 0, y: 0, width: 0.02, height: 0.02), scale: 2) == 4096)
        check("mindestens 1 px", CropMath.decodeMaxPixel(displaySize: CGSize(width: 0.2, height: 0.2), crop: nil, scale: 1) == 1)
        var rng = SplitMix64(seed: 77)
        var sameOK = true
        for _ in 0..<200 {
            let s = CGSize(width: rng.nextDouble(in: 1, 400), height: rng.nextDouble(in: 1, 400))
            let scale = [1.0, 2.0, 3.0][Int(rng.nextUnit() * 3) % 3]
            let old = max(1, Int((max(s.width, s.height) * CGFloat(scale)).rounded(.up)))
            if CropMath.decodeMaxPixel(displaySize: s, crop: nil, scale: scale) != old { sameOK = false }
        }
        check("ohne Crop identisch mit der bisherigen Formel (200 Zufallsgrößen)", sameOK)
        check("reconcile ohne Crop = BoardLayout (C7: 220×165 → 165×220)",
              CropMath.reconciledSize(stored: CGSize(width: 220, height: 165), orientedPixelWidth: 3024,
                                      orientedPixelHeight: 4032, crop: nil) == CGSize(width: 165, height: 220))
        let half = BoardCrop(x: 0, y: 0, width: 0.5, height: 1)
        check("reconcile mit Crop: passendes Verhältnis bleibt exakt",
              CropMath.reconciledSize(stored: CGSize(width: 110, height: 110), orientedPixelWidth: 4000,
                                      orientedPixelHeight: 2000, crop: half) == CGSize(width: 110, height: 110))
        check("reconcile mit Crop: falsches Verhältnis → neu eingepasst",
              near(CropMath.reconciledSize(stored: CGSize(width: 110, height: 55), orientedPixelWidth: 4000,
                                           orientedPixelHeight: 2000, crop: half), CGSize(width: 110, height: 110)))

        // Echter ImageIO-Weg: 600×400-PNG, Ausschnitt 60 % → Bitmap = ganzes Bild in voller Größe (220 pt @2x = 440 px).
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dropboard-selftest-crop-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        guard let image = PaperArt.demoCropImage() else {
            check("Testbild anlegen", false)
            return
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("crop.png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                check("PNG-Ziel anlegen", false)
                return
            }
            CGImageDestinationAddImage(dest, image, nil)
            check("Testbild geschrieben", CGImageDestinationFinalize(dest))
            let crop = BoardCrop(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
            let full = BoardLayout.fittedSize(pixelWidth: 600, pixelHeight: 400, longestEdge: 220) ?? .zero
            let visible = CropMath.visibleSize(fullSize: full, crop: crop)
            let decoded = ImageDecoder.decode(url: url, size: visible, crop: crop, scale: 2)
            check("Dekoder mit Crop: Anzeigegröße = Ausschnitt (132×88,2 pt bleibt exakt)",
                  decoded.map { near($0.size, visible) } == true && near(visible, CGSize(width: 132, height: 88.2)))
            check("Dekoder mit Crop: Bitmap = ganzes Bild in voller Größe × Scale (≈ 440 px breit, Quelle 600)",
                  decoded.map { abs($0.cgImage.width - 440) <= 1 } == true)
            let plain = ImageDecoder.decode(url: url, size: visible, scale: 2)
            check("Vergleich ohne Crop-Angabe: nur Anzeigegröße × Scale (≈ 264 px)",
                  plain.map { abs($0.cgImage.width - 264) <= 1 } == true)
        } catch {
            check("Testordner anlegen (\(error))", false)
        }
    }

    // MARK: 8 – contentsRect-Ursprung per Bitmap

    /// Rendert einen 10×10-Layer, dessen Contents oben schwarz und unten weiß sind, mit dem contentsRect für „obere
    /// Hälfte“. Der Layer zeigt dann nur eine Farbe. Schwarz = Ursprung stimmt.
    // ⚠️ VERIFIZIEREN: CALayer.render(in:) beachtet contentsRect wie der Render-Server (Sichtprüfung im Snapshot).
    @MainActor
    private static func contentsRectBitmap(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("crop contentsRect: " + name, ok) }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let src = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { check("Testbild anlegen", false); return }
        src.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        src.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        src.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        src.fill(CGRect(x: 0, y: 10, width: 20, height: 10))   // y nach oben → obere Bildhälfte
        guard let image = src.makeImage() else { check("Testbild anlegen", false); return }

        /// Rot-Wert des gerenderten Layers (Mitte) bei gegebenem Ursprung; nil = nichts gerendert.
        func renderedRed(originTop: Bool) -> Double? {
            let root = CALayer(), layer = CALayer()
            withoutImplicitAnimations {
                root.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
                layer.frame = root.frame
                layer.contents = image
                layer.contentsRect = CropMath.contentsRect(BoardCrop(x: 0, y: 0, width: 1, height: 0.5), originTop: originTop)
                root.addSublayer(layer)
            }
            var buf = [UInt8](repeating: 0, count: 10 * 10 * 4)
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40,
                                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                root.render(in: ctx)
                return true
            }
            guard ok else { return nil }
            let i = (5 * 10 + 5) * 4
            guard buf[i + 3] > 200 else { return nil }   // nichts (deckend) gerendert
            return Double(buf[i])
        }
        let configured = renderedRed(originTop: CropStyle.contentsRectOriginTop)
        let other = renderedRed(originTop: !CropStyle.contentsRectOriginTop)
        let measured: String
        if let a = renderedRed(originTop: false), a < 64 {
            measured = "unten links (contentsRectOriginTop = false)"
        } else if let b = renderedRed(originTop: true), b < 64 {
            measured = "oben links (contentsRectOriginTop = true)"
        } else {
            measured = "unklar (nichts gerendert?)"
        }
        check("Ursprung laut CropStyle (originTop=\(CropStyle.contentsRectOriginTop)) zeigt den oberen Bildteil; gemessen: \(measured)",
              configured.map { $0 < 64 } == true)
        check("Gegenprobe: der andere Ursprung zeigt den unteren Bildteil", other.map { $0 > 192 } == true)
    }

    // MARK: 9 – Szene: Geometrie, Overlay, Stapel

    @MainActor
    private static func scene(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("crop scene: " + name, ok) }
        let scene = BoardScene(size: CGSize(width: 1000, height: 800), scale: 2, noiseTile: nil)
        guard let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = ctx.makeImage() else { check("Testbild anlegen", false); return }
        let crop = BoardCrop(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let otherID = UUID(), id = UUID(), topID = UUID()
        scene.addImage(id: otherID, image: image, size: CGSize(width: 50, height: 50))
        let layer = scene.addImage(id: id, image: image, size: CGSize(width: 80, height: 40), crop: crop)
        scene.addImage(id: topID, image: image, size: CGSize(width: 50, height: 50))
        StopMotion.setModel(scene.pose(center: CGPoint(x: 500, y: 400), rotation: 1.5), on: layer)
        check("Ausschnitt: bounds = Anzeigegröße, contentsRect = Crop",
              layer.bounds.size == CGSize(width: 80, height: 40)
                && near(layer.contentsRect, CropMath.contentsRect(crop, originTop: CropStyle.contentsRectOriginTop), 1e-12))
        check("Schatten folgt der beschnittenen Größe (shadowPath = bounds)",
              layer.shadowPath.map { near($0.boundingBox, layer.bounds) } == true)
        let plain = scene.itemLayer(id: otherID)
        check("ohne Crop: contentsRect = Einheitsrechteck", plain?.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))

        scene.setSelected(true, id: id)
        let index = scene.bringToFront(id: id)
        check("bringToFront: liefert alten Stapel-Index (1), liegt danach oben",
              index == 1 && layer.superlayer?.sublayers?.last === layer)
        let editor = CropEditor(itemCenter: CGPoint(x: 500, y: 400), itemSize: CGSize(width: 80, height: 40), crop: crop, rotation: 0)
        scene.beginCropEditing(id: id, fullSize: editor.fullSize, crop: editor.crop)
        StopMotion.setModel(scene.pose(center: editor.imageCenter, rotation: 0), on: layer)
        let overlay = scene.cropOverlayForTest
        check("Beschnittmodus: ganzes Bild (bounds = F 200×100, contentsRect ganz)",
              layer.bounds.size == CGSize(width: 200, height: 100) && layer.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
        check("Beschnittmodus: Schatten ums ganze Bild", layer.shadowPath.map { near($0.boundingBox, layer.bounds) } == true)
        check("Beschnittmodus: Overlay liegt im Item-Layer, Auswahl-Rahmen aus",
              overlay != nil && layer.sublayers?.contains { $0.name == CropOverlay.name } == true && layer.borderWidth == 0
                && scene.cropEditingID == id)
        check("Overlay: Rahmen in lokalen Layer-Koordinaten (40, 40, 80×40)",
              overlay.map { near($0.frameLayerRect, CGRect(x: 40, y: 40, width: 80, height: 40)) } == true)
        check("Overlay: Griff oben links bei (40, 80), unten rechts bei (120, 40)",
              overlay.flatMap { $0.handleCenter(.topLeft) }.map { near($0, CGPoint(x: 40, y: 80)) } == true
                && overlay.flatMap { $0.handleCenter(.bottomRight) }.map { near($0, CGPoint(x: 120, y: 40)) } == true)
        let dimArea = overlay?.dimFrames.reduce(CGFloat(0)) { $0 + $1.width * $1.height } ?? -1
        check("Overlay: Abdunklung deckt genau das Bild außerhalb des Rahmens (20000 − 3200 pt²)", near(dimArea, 16800, 1e-6))
        check("Overlay: warmes Graphit, keine Systemfarbe", CropStyle.outsideOpacity > 0 && PaperStyle.graphiteHex == 0x3A2E22)

        scene.setImage(image, size: CGSize(width: 10, height: 10), crop: nil, for: id)
        check("Neu-Dekodieren während des Beschnitts ändert die Geometrie nicht", layer.bounds.size == CGSize(width: 200, height: 100))

        var moved = editor
        moved.pan(from: editor, mouseDelta: CGPoint(x: 10, y: 5))
        scene.updateCropEditing(id: id, fullSize: moved.fullSize, crop: moved.crop, imageCenter: moved.imageCenter)
        check("Drag: Bildlage direkt als Model-Wert, gerade, ohne Animation",
              layer.position == scene.layerPoint(moved.imageCenter) && (layer.animationKeys() ?? []).isEmpty
                && CATransform3DEqualToTransform(layer.transform, StopMotion.transform(for: Pose(position: .zero, rotation: 0))))
        check("Drag: Overlay folgt dem Crop",
              overlay.map { near($0.frameLayerRect, CropOverlay.frameRect(fullSize: moved.fullSize, crop: moved.crop)) } == true)

        let newCrop = BoardCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        scene.endCropEditing(id: id, size: CGSize(width: 100, height: 50), crop: newCrop)
        check("Ende: Overlay weg, Geometrie = neuer Ausschnitt",
              scene.cropEditingID == nil && layer.sublayers?.contains { $0.name == CropOverlay.name } != true
                && layer.bounds.size == CGSize(width: 100, height: 50)
                && near(layer.contentsRect, CropMath.contentsRect(newCrop, originTop: CropStyle.contentsRectOriginTop), 1e-12))
        check("Ende: Schatten folgt der neuen Größe", layer.shadowPath.map { near($0.boundingBox, layer.bounds) } == true)
        scene.restoreStackIndex(id: id, index: 1)
        check("Abbrechen: Stapel-Index wiederhergestellt",
              layer.superlayer?.sublayers?.firstIndex { $0 === layer } == 1 && scene.itemLayer(id: topID)?.superlayer?.sublayers?.last === scene.itemLayer(id: topID))
        let placeholderID = UUID()
        scene.addPlaceholder(id: placeholderID, size: CGSize(width: 10, height: 10))
        check("hasImage: Bild ja, Platzhalter nein (Platzhalter nicht beschneidbar)",
              scene.hasImage(id: id) && !scene.hasImage(id: placeholderID))
    }
}
