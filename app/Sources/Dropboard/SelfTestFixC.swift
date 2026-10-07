import AppKit
import QuartzCore
import DropboardCore

/// Phase 4, Fix-Gruppe C (Optik/Motion/Szene): Selftests für Eselsohr, harten Schatten, Realtime-Clip (P5/C13),
/// Drop-Schatten (B6), Jitter in Device-Pixeln und begrenzte Blatt-Rotation (B7), Szene bei Größen-/Scale-Wechsel
/// (C5/C19). Wird vom Orchestrator in SelfTest.run eingetragen: `FixCSelfTest.run(t)`.
/// Läuft ohne Fenster und ohne Run-Loop (wie Snapshot): Layer werden nur als Model-Werte geprüft.
enum FixCSelfTest {
    static func run(_ t: SelfTestChecker) {
        // Selftest läuft synchron auf dem Main Thread (main.swift); die geprüften Typen sind @MainActor.
        // ⚠️ VERIFIZIEREN (Muster aus main.swift): MainActor.assumeIsolated aus nicht isoliertem Kontext.
        MainActor.assumeIsolated {
            runIsolated(t)
        }
    }

    @MainActor
    private static func runIsolated(_ t: SelfTestChecker) {
        ear(t)
        shadow(t)
        realtimeClip(t)
        dropShadow(t)
        jitter(t)
        scene(t)
    }

    // MARK: Hilfen

    /// RGBA8 (premultiplied) eines Bildes; Zeile 0 im Speicher = oberste Bildzeile.
    // ⚠️ VERIFIZIEREN: Speicher-Layout des Bitmap-Kontexts (erste Zeile = oben). Fällt der Ecken-Test für alle vier
    // Ecken genau gespiegelt aus, ist nur diese Annahme falsch, nicht das Eselsohr.
    private struct Pixels {
        let width: Int, height: Int
        let bytes: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var buf = [UInt8](repeating: 0, count: width * height * 4)
            let w = width, h = height
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            bytes = buf
        }

        /// Pixel bei (x, y) mit y nach OBEN (wie der Zeichen-Kontext). Rückgabe r, g, b, a (0…255, premultiplied).
        func at(_ x: Int, _ yUp: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let row = height - 1 - yUp
            let i = (row * width + x) * 4
            return (Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2]), Double(bytes[i + 3]))
        }
    }

    /// Relative Luminanz (WCAG) einer sRGB-Farbe (0…1).
    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private static func rgb(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private static func over(_ bg: (Double, Double, Double), _ fg: (Double, Double, Double), _ a: Double)
        -> (Double, Double, Double) {
        (bg.0 * (1 - a) + fg.0 * a, bg.1 * (1 - a) + fg.1 * a, bg.2 * (1 - a) + fg.2 * a)
    }

    private static func contrast(_ x: (Double, Double, Double), _ y: (Double, Double, Double)) -> Double {
        let lx = luminance(x.0, x.1, x.2), ly = luminance(y.0, y.1, y.2)
        return (max(lx, ly) + 0.05) / (min(lx, ly) + 0.05)
    }

    private static func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool { abs(a - b) <= eps }
    private static func near(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-6) -> Bool {
        near(a.minX, b.minX, eps) && near(a.minY, b.minY, eps) && near(a.width, b.width, eps) && near(a.height, b.height, eps)
    }

    /// Kleine graue Noise-Kachel (8×8) für Szene-Tests ohne Bundle-Ressource.
    private static func testTile() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()
    }

    // MARK: 1 – Eselsohr: Papierstück mit umgeknickter Ecke

    @MainActor
    private static func ear(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("fixC ear: " + name, ok) }
        let size = CGSize(width: DropboardConfig.earSize, height: DropboardConfig.earSize)

        // Geometrie: Lasche = Spiegelbild der weggeknickten Ecke an der Falzlinie
        let g = PaperArt.earGeometry(pixelWidth: 80, pixelHeight: 80)
        let (p0, p1) = g.fold
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let corner = CGPoint(x: 80, y: 80)
        let u = ((corner.x - p0.x) * dx + (corner.y - p0.y) * dy) / (dx * dx + dy * dy)
        let foot = CGPoint(x: p0.x + u * dx, y: p0.y + u * dy)
        let mirrored = CGPoint(x: 2 * foot.x - corner.x, y: 2 * foot.y - corner.y)
        check("Lasche ist Spiegelbild der weggeknickten Ecke (80 px: (40,40))",
              near(mirrored.x, g.flap[2].x) && near(mirrored.y, g.flap[2].y) && near(mirrored.x, 40) && near(mirrored.y, 40))
        check("Falz von Oberkante (40,80) zur rechten Kante (80,40), Lasche 50 %",
              p0 == CGPoint(x: 40, y: 80) && p1 == CGPoint(x: 80, y: 40) && PaperStyle.earFoldFraction == 0.5)
        check("Vorderseite = Fünfeck (Quadrat ohne Ecke oben rechts)", g.front.count == 5 && !g.front.contains(corner))

        // Raster: für jede Ecke und Scale 1/2 – weggeknickte Ecke transparent, übrige Ecken Papier (opak),
        // Lasche dunkler und kühler als die Vorderseite (ohne Noise gemessen).
        var cornersOK = true, sizeOK = true, flapOK = true, opaqueOK = true
        for scale in [CGFloat(1), 2] {
            for c in EarCorner.allCases {
                guard let img = PaperArt.earImage(size: size, scale: scale, noiseTile: nil, corner: c),
                      let px = Pixels(img) else { cornersOK = false; continue }
                let w = px.width, h = px.height
                if w != Int(size.width * scale) || h != Int(size.height * scale) { sizeOK = false }
                let outerX = c.isRight ? w - 1 : 0, outerY = c.isTop ? h - 1 : 0
                let innerX = c.isRight ? 0 : w - 1, innerY = c.isTop ? 0 : h - 1
                if px.at(outerX, outerY).a != 0 { cornersOK = false }
                for (x, y) in [(innerX, innerY), (outerX, innerY), (innerX, outerY)] where px.at(x, y).a < 254 {
                    opaqueOK = false
                }
                // Lasche: Schwerpunkt (W − 2/3·f, H − 2/3·f) für .topRight; Vorderseite: (W/4, H/4); gespiegelt
                let f = Double(w) * Double(PaperStyle.earFoldFraction)
                func mirrorX(_ x: Double) -> Int { Int(c.isRight ? x : Double(w) - 1 - x) }
                func mirrorY(_ y: Double) -> Int { Int(c.isTop ? y : Double(h) - 1 - y) }
                let flap = px.at(mirrorX(Double(w) - 2 * f / 3), mirrorY(Double(h) - 2 * f / 3))
                let front = px.at(mirrorX(Double(w) / 4), mirrorY(Double(h) / 4))
                let lFlap = luminance(flap.r / 255, flap.g / 255, flap.b / 255)
                let lFront = luminance(front.r / 255, front.g / 255, front.b / 255)
                let coolerFlap = (flap.b - flap.r) > (front.b - front.r)
                if !(flap.a == 255 && front.a == 255 && lFlap < lFront && coolerFlap) { flapOK = false }
            }
        }
        check("Bitmap = Größe × Backing-Scale (40 pt → 40/80 px, alle Ecken)", sizeOK)
        check("weggeknickte Ecke zur Bildschirmecke ist transparent (4 Ecken × Scale 1/2)", cornersOK)
        check("die drei anderen Ecken sind Papier (opak)", opaqueOK)
        check("Lasche (Rückseite) dunkler und kühler als die Vorderseite", flapOK)
        check("Vorderseite = Board-Papier (paperHex)", PaperStyle.paperHex == 0xF4F0E8)
        check("Eselsohr gedämpft (earOpacity < 1)", PaperStyle.earOpacity < 1)
    }

    // MARK: 2 – Harter Schatten

    private static func shadow(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("fixC shadow: " + name, ok) }
        check("Radius 0 (kein Blur)", PaperStyle.shadowRadius == 0)
        check("Versatz 2 pt nach unten rechts (Briefing-Obergrenze)",
              PaperStyle.shadowOffset.width == 2 && PaperStyle.shadowOffset.height == -2)
        // Papier inkl. Noise (Mittelwert 128/255, Deckkraft noiseOpacity)
        let paper = over(rgb(PaperStyle.paperHex), (128.0 / 255, 128.0 / 255, 128.0 / 255), Double(PaperStyle.noiseOpacity))
        let graphite = rgb(PaperStyle.graphiteHex)
        let a = Double(PaperStyle.shadowOpacity)
        let shadowOnPaper = over(paper, graphite, a)
        check("Kontrast Schatten/Papier ≥ 3:1 (WCAG 1.4.11; Wert \(String(format: "%.2f", contrast(shadowOnPaper, paper))):1)",
              contrast(shadowOnPaper, paper) >= 3)
        let dimmed = over(paper, graphite, Double(PaperStyle.dimOpacity))
        let shadowOnDim = over(dimmed, graphite, a)
        check("Kontrast auf abgedunkeltem Papier ≥ 2.5:1 (Wert \(String(format: "%.2f", contrast(shadowOnDim, dimmed))):1)",
              contrast(shadowOnDim, dimmed) >= 2.5)
        let lShadow = luminance(shadowOnPaper.0, shadowOnPaper.1, shadowOnPaper.2)
        let demo: [UInt32] = [0x8FA3A0, 0xC48B7A, 0xB8A86B, 0x7C8DA8, 0x9A7F9E, PaperStyle.placeholderHex]
        check("Schatten dunkler als jedes gedämpfte Demo-Bild und der Platzhalter",
              demo.allSatisfy { let c = rgb($0); return luminance(c.0, c.1, c.2) > lShadow })
        check("warm (Rot > Blau)", shadowOnPaper.0 > shadowOnPaper.2)
    }

    // MARK: 3 – P5/C13/P6: Realtime-Aufblättern ohne Vollbild-Maske

    @MainActor
    private static func realtimeClip(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("fixC realtime: " + name, ok) }
        let size = CGSize(width: 1920, height: 1080)
        let full = CGRect(origin: .zero, size: size)

        // Geometrie: bei linear interpolierten bounds deckt sich der Container-Rahmen in jedem Frame mit bounds
        // (Papier steht still), Start = leeres Rechteck in der Ecke, Ende = ganzes Blatt.
        var stillOK = true, endsOK = true
        let anchors = [CGPoint(x: 1880, y: 1050), CGPoint(x: 40, y: 1050), CGPoint(x: 1880, y: 30), CGPoint(x: 40, y: 30),
                       CGPoint(x: 2500, y: -10)]   // letzter: außerhalb → begrenzt
        for anchor in anchors {
            let a = RealtimeMotion.clampedAnchor(anchor, in: size)
            let start = RealtimeMotion.collapsedRect(a.point)
            for step in 0...10 {
                let s = CGFloat(step) / 10
                let b = CGRect(x: start.minX + (full.minX - start.minX) * s, y: start.minY + (full.minY - start.minY) * s,
                               width: start.width + (full.width - start.width) * s,
                               height: start.height + (full.height - start.height) * s)
                if !near(RealtimeMotion.visibleFrame(bounds: b, anchor: a), b, 1e-6) { stillOK = false }
            }
            if !(start.size == .zero && near(RealtimeMotion.visibleFrame(bounds: full, anchor: a), full)) { endsOK = false }
        }
        check("Container-Rahmen == bounds in jedem Zwischenschritt (Papier steht still, 5 Anker × 11 Schritte)", stillOK)
        check("Start = leeres Rechteck im Anker, Ende = ganzes Blatt", endsOK)

        // Szene: reveal legt KEINE Maske an, sondern clippt den Container und animiert dessen bounds.
        let scene = BoardScene(size: size, scale: 2, noiseTile: nil)
        let clip = RealtimeMotion.clipContainer(of: scene.sheet)
        check("BoardScene: Papier hängt im Clip-Container", clip === scene.clip && clip != nil)
        check("Ruhezustand: kein Clipping, Rahmen = Blatt", !scene.clip.masksToBounds && near(scene.clip.frame, full))
        let anchor = CGPoint(x: 1880, y: 1050)
        let animated = RealtimeMotion.reveal(scene.sheet, from: anchor, reduceMotion: false)
        let anim = scene.clip.animation(forKey: RealtimeMotion.revealKey) as? CABasicAnimation
        check("reveal: animiert, keine Maske auf dem Papier (kein Offscreen-Pass)", animated && scene.sheet.mask == nil)
        check("reveal: Container clippt, Model-Wert = Endzustand (ganzes Blatt, Rahmen deckungsgleich)",
              scene.clip.masksToBounds && near(scene.clip.bounds, full) && near(scene.clip.frame, full))
        check("reveal: bounds-Animation 200 ms, easeOut, ab leerem Rechteck im Anker",
              anim?.keyPath == "bounds" && anim?.duration == RealtimeMotion.duration
                && near((anim?.fromValue as? NSValue)?.rectValue ?? .null,
                        RealtimeMotion.collapsedRect(RealtimeMotion.clampedAnchor(anchor, in: size).point))
                && near(RealtimeMotion.collapsedRect(anchor), CGRect(x: 1880, y: 1050, width: 0, height: 0), 1e-6))
        check("P6: reveal-Animation hat Start-Logger (animationDidStart → [MOTION] reveal gestartet)",
              anim?.delegate is RevealStartLogger)

        // C13: Zuklappen startet beim sichtbaren Wert einer laufenden Animation (reine Entscheidung).
        let shown = CGRect(x: 1100, y: 600, width: 780, height: 450)
        check("C13: laufendes Aufblättern → Start = Presentation-Wert",
              RealtimeMotion.collapseStart(running: true, presented: shown, model: full, clipping: true, full: full) == shown)
        check("C13: nichts läuft → Start = ganzes Blatt",
              RealtimeMotion.collapseStart(running: false, presented: nil, model: full, clipping: false, full: full) == full)
        check("C13: Dauer anteilig (Hälfte sichtbar → 100 ms), mindestens 50 ms",
              abs(RealtimeMotion.collapseDuration(from: CGRect(x: 0, y: 0, width: 960, height: 540), full: full) - 0.1) < 1e-9
                && RealtimeMotion.collapseDuration(from: .zero, full: full) == 0.05
                && RealtimeMotion.collapseDuration(from: full, full: full) == RealtimeMotion.duration)

        RealtimeMotion.clear(scene.sheet)
        check("clear: Ruhezustand ohne Animation und Clipping, Rahmen = Blatt",
              !scene.clip.masksToBounds && (scene.clip.animationKeys() ?? []).isEmpty && near(scene.clip.frame, full))
        check("Reduce Motion: nicht animiert, keine Maske",
              !RealtimeMotion.reveal(scene.sheet, from: anchor, reduceMotion: true) && scene.sheet.mask == nil)
    }

    // MARK: 4 – B6: Drop-Frame 0 ohne Schatten, Frame 1 final mit Schatten und Kipp

    @MainActor
    private static func dropShadow(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("fixC B6: " + name, ok) }
        let target = Pose(position: CGPoint(x: 400, y: 300), rotation: 1.5)
        var allOK = true
        for jitter in [true, false] {
            for scale in [1.0, 2.0] {
                var rng = SplitMix64(seed: 11)
                let plan = StopMotionSequences.drop(target: target,
                                                    options: PlanOptions(jitter: jitter, reduceMotion: false, backingScale: scale),
                                                    using: &rng)
                let f0 = plan.frames[0], f1 = plan.frames[1]
                if !(f0.shadow == 0 && abs(f0.scale - StopMotionSequences.dropScale) < 1e-9 && abs(f0.rotation) <= StopMotionJitter.maxRotation
                     && f1 == target && f1.shadow == 1 && f1.rotation == 1.5) { allOK = false }
            }
        }
        check("Frame 0 groß, ohne Schatten, ohne Kipp (nur Jitter); Frame 1 = final mit Schatten und Kipp", allOK)
        var r0 = SplitMix64(seed: 3)
        let reduced = StopMotionSequences.drop(target: target, options: PlanOptions(jitter: true, reduceMotion: true), using: &r0)
        check("Reduce Motion: 1 Frame, mit Schatten", reduced.frames == [target] && reduced.frames[0].shadow == 1)

        var r1 = SplitMix64(seed: 4)
        let opts = PlanOptions(jitter: true, reduceMotion: false, backingScale: 2)
        let others = [StopMotionSequences.reveal(target: target, options: opts, using: &r1),
                      StopMotionSequences.move(from: target, to: Pose(position: CGPoint(x: 800, y: 300)), options: opts, using: &r1),
                      StopMotionSequences.delete(from: target, options: opts, using: &r1),
                      ViewModeSequences.open(target: StopMotionSheet.fullPose(anchor: .zero), options: opts, using: &r1),
                      ViewModeSequences.close(target: StopMotionSheet.fullPose(anchor: .zero), options: opts, using: &r1)]
        check("nur der Drop führt eine Schatten-Spur (reveal/move/delete/Blatt nicht)",
              others.allSatisfy { !StopMotion.tracksShadow($0) })

        var r2 = SplitMix64(seed: 5)
        let plan = StopMotionSequences.drop(target: target, options: opts, using: &r2)
        let layer = CALayer()
        layer.shadowOpacity = 0
        StopMotion.apply(plan, to: layer)
        let track = layer.animation(forKey: StopMotion.keyPrefix + "shadowOpacity") as? CAKeyframeAnimation
        let values = (track?.values as? [NSNumber])?.map { $0.floatValue }
        check("apply(drop): Model shadowOpacity = final, discrete-Keyframes [0, final]",
              layer.shadowOpacity == PaperStyle.shadowOpacity && track?.calculationMode == .discrete
                && values == [0, PaperStyle.shadowOpacity])
        let mask = CALayer()
        var r3 = SplitMix64(seed: 6)
        StopMotion.apply(StopMotionSequences.reveal(target: target, options: opts, using: &r3), to: mask)
        check("apply(reveal) auf Maske: kein Schatten, keine Schatten-Spur",
              mask.shadowOpacity == 0 && mask.animation(forKey: StopMotion.keyPrefix + "shadowOpacity") == nil)
    }

    // MARK: 5 – B7: Jitter in Device-Pixeln, Blatt-Rotation begrenzt

    @MainActor
    private static func jitter(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("fixC B7: " + name, ok) }
        let a = Pose(position: CGPoint(x: 400, y: 300), rotation: 1.5)
        var pxOK = true
        for scale in [1.0, 2.0, 3.0] {
            for seed in UInt64(1)...200 {
                var r1 = SplitMix64(seed: seed), r2 = SplitMix64(seed: seed)
                let on = StopMotionSequences.reveal(target: a, options: PlanOptions(jitter: true, backingScale: scale), using: &r1)
                let off = StopMotionSequences.reveal(target: a, options: PlanOptions(jitter: false, backingScale: scale), using: &r2)
                for i in 0..<(on.frames.count - 1) {
                    let dx = Double(on.frames[i].position.x - off.frames[i].position.x) * scale
                    let dy = Double(on.frames[i].position.y - off.frames[i].position.y) * scale
                    let m = (dx * dx + dy * dy).squareRoot()
                    if abs(m - 1) > 1e-6 || (dx != 0 && dy != 0) { pxOK = false }
                }
            }
        }
        check("Positions-Jitter = genau 1 Device-Pixel auf einer Achse (Scale 1/2/3 × 200 Seeds; Briefing 0,5–1 px)", pxOK)

        // Blatt im Ansichtsmodus: Drehung um die Eselsohr-Ecke, ferne Kante ≤ 1 Device-Pixel
        var sheetOK = true, oldFar = 0.0
        for (size, anchor) in [(CGSize(width: 1920, height: 1080), CGPoint(x: 1880, y: 1050)),
                               (CGSize(width: 1512, height: 982), CGPoint(x: 40, y: 30))] {
            for scale in [1.0, 2.0] {
                let r = StopMotionSheet.farthestDistance(sheetSize: size, anchor: anchor)
                oldFar = max(oldFar, 2 * r * sin(StopMotionJitter.maxRotation / 2 * Double.pi / 180))
                for seed in UInt64(1)...50 {
                    var rng = SplitMix64(seed: seed)
                    let plan = ViewModeSequences.open(target: StopMotionSheet.fullPose(anchor: anchor),
                                                      options: PlanOptions(jitter: true, backingScale: scale), using: &rng)
                    let limited = StopMotionSheet.limitRotation(plan, sheetSize: size, anchor: anchor, backingScale: scale)
                    for f in limited.frames {
                        let shift = 2 * r * sin(abs(f.rotation) / 2 * Double.pi / 180)   // Sehne am fernsten Punkt, pt
                        if shift > 1 / scale + 1e-9 { sheetOK = false }
                    }
                    if limited.frames.map({ $0.position }) != plan.frames.map({ $0.position })
                        || limited.frames.last?.rotation != 0 { sheetOK = false }
                }
            }
        }
        check("Blatt-Rotation: fernste Papierkante bewegt sich ≤ 1 Device-Pixel (vorher bis \(String(format: "%.1f", oldFar)) pt)",
              sheetOK && oldFar > 5)
    }

    // MARK: 6 – C5/C19: Szene bei Größen- und Scale-Wechsel

    @MainActor
    private static func scene(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: Bool) { t.check("fixC scene: " + name, ok) }
        let scene = BoardScene(size: CGSize(width: 2560, height: 1440), scale: 1, noiseTile: testTile())
        check("Noise 1:1 in Device-Pixeln (2560×1440 @1x)", scene.noisePixelSize == CGSize(width: 2560, height: 1440))
        let id = UUID(), center = CGPoint(x: 500, y: 300)
        let layer = scene.addPlaceholder(id: id, size: CGSize(width: 200, height: 150))
        StopMotion.setModel(scene.pose(center: center, rotation: 1), on: layer)
        var reported: (CGFloat, CGFloat)?
        scene.onBackingScaleChange = { reported = ($0, $1) }

        scene.resize(size: CGSize(width: 1512, height: 982), scale: 2)
        check("C5: Item-Layer nach resize = layerPoint(Board-Mitte) mit neuer Höhe",
              near(layer.position.x, 500) && near(layer.position.y, 982 - 300) && layer.position == scene.layerPoint(center))
        check("C19: Noise neu gekachelt in neuer Pixelgröße (1512×982 @2x → 3024×1964)",
              scene.noisePixelSize == CGSize(width: 3024, height: 1964))
        check("C19: Scale-Wechsel gemeldet (1 → 2), Item-contentsScale nachgezogen",
              reported?.0 == 1 && reported?.1 == 2 && layer.contentsScale == 2)
        check("Clip-Container nach resize im Ruhezustand (Rahmen = Blatt)",
              near(scene.clip.frame, CGRect(x: 0, y: 0, width: 1512, height: 982)) && !scene.clip.masksToBounds)
        reported = nil
        scene.resize(size: CGSize(width: 1512, height: 982), scale: 2)
        check("gleiche Größe/Scale: keine Meldung, Position unverändert", reported == nil && layer.position == scene.layerPoint(center))

        let ear1 = PaperArt.earImage(size: CGSize(width: 40, height: 40), scale: 1, noiseTile: nil)
        let ear2 = PaperArt.earImage(size: CGSize(width: 40, height: 40), scale: 2, noiseTile: nil)
        check("C19: Eselsohr-Bitmap folgt dem Scale (40 → 80 px)", ear1?.width == 40 && ear2?.width == 80)

        scene.relayoutItems([id: (center: CGPoint(x: 100, y: 100), rotation: 0)])
        check("relayoutItems: Position aus Modell", layer.position == scene.layerPoint(CGPoint(x: 100, y: 100)))
    }
}
