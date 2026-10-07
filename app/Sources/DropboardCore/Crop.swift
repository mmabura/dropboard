import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Beschnitt (E11): reine Logik, nur Foundation/CoreGraphics, deshalb im Selftest prüfbar (SelfTestCrop.swift).
//
// Begriffe:
//   Bildraum   – das ORIENTIERTE Bild (EXIF-Drehung schon angewandt), normiert auf [0, 1], Ursprung OBEN LINKS, y nach unten.
//   Crop       – sichtbarer Ausschnitt in diesem Bildraum (`BoardCrop`). Fehlt er (nil), ist das ganze Bild sichtbar.
//   F          – „volle Größe“: Anzeigegröße des GANZEN Bildes in pt = Item-Größe ÷ Crop-Breite/-Höhe. Bleibt beim Beschneiden
//                gleich (der sichtbare Teil behält Ort und Größe, E11), deshalb muss nach dem Übernehmen nicht neu dekodiert werden.
//   lokal      – Item-System ohne Rotation, pt, y nach unten. Board = lokal um `rotation` gedreht (Grad, positiv = gegen den
//                Uhrzeigersinn auf dem Bildschirm, wie BoardItem.rotation und BoardEditing.contains).

/// Normiertes Beschnitt-Rechteck im orientierten Bildraum (Ursprung oben links). Gespeichert in board.json als
/// `"crop": {"x":…, "y":…, "width":…, "height":…}`; fehlt der Schlüssel, ist das ganze Bild sichtbar.
public struct BoardCrop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = BoardCrop(x: 0, y: 0, width: 1, height: 1)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// Ganzes Bild (bis auf Rundung)?
    public var isFull: Bool {
        abs(x) <= CropMath.fullEpsilon && abs(y) <= CropMath.fullEpsilon
            && abs(width - 1) <= CropMath.fullEpsilon && abs(height - 1) <= CropMath.fullEpsilon
    }

    public var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite }

    /// Kurzform fürs Log: `(x,y wxh)` mit 3 Nachkommastellen, `ganz` für nil/ganzes Bild.
    public static func describe(_ crop: BoardCrop?) -> String {
        guard let c = CropMath.effective(crop) else { return "ganz" }
        return String(format: "(%.3f,%.3f %.3fx%.3f)", c.x, c.y, c.width, c.height)
    }
}

/// Die 8 Griffe (4 Ecken, 4 Kanten).
public enum CropHandle: String, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    public var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    public var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    public var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    public var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    /// Lage am Rahmen, normiert relativ zum Rahmen (0 = links/oben, 0.5 = Mitte, 1 = rechts/unten).
    public var relativePosition: (u: Double, v: Double) {
        let u: Double = movesLeft ? 0 : (movesRight ? 1 : 0.5)
        let v: Double = movesTop ? 0 : (movesBottom ? 1 : 0.5)
        return (u, v)
    }
}

/// Ergebnis des Treffer-Tests im Beschnittmodus.
public enum CropHit: Equatable, Sendable {
    case handle(CropHandle)
    /// im Rahmen → Bild darunter verschieben
    case frame
    /// auf dem abgedunkelten Teil des Bildes (außerhalb des Rahmens) → ebenfalls verschieben
    case image
    /// neben dem Bild → übernehmen
    case outside
}

public enum CropMath {
    /// Mindestgröße des sichtbaren Teils: 24 pt in der Anzeige …
    public static let minVisiblePoints = 24.0
    /// … und mindestens 2 % des Bildes je Achse.
    public static let minFraction = 0.02
    /// Obergrenze der Dekodier-Zielgröße (längste Kante des GANZEN Bildes, Pixel).
    public static let maxDecodePixel = 4096
    /// Toleranz für „ganzes Bild“.
    public static let fullEpsilon = 1e-6

    // MARK: Normieren / Klemmen

    /// Wirksamer Crop: nil bei nil, ganzem Bild oder unbrauchbaren Werten (nicht endlich, Breite/Höhe ≤ 0).
    /// Sonst auf [0, 1] begrenzt (ohne Mindestgröße, die hängt an der Anzeigegröße).
    public static func effective(_ crop: BoardCrop?) -> BoardCrop? {
        guard let c = crop, c.isFinite, c.width > 0, c.height > 0 else { return nil }
        let w = min(1, c.width), h = min(1, c.height)
        let x = min(max(0, c.x), 1 - w), y = min(max(0, c.y), 1 - h)
        let r = BoardCrop(x: x, y: y, width: w, height: h)
        return r.isFull ? nil : r
    }

    /// Mindestgröße (normiert) bei voller Anzeigegröße `fullSize`: max(24 pt, 2 %), höchstens das ganze Bild.
    public static func minSize(fullSize: CGSize) -> (width: Double, height: Double) {
        func m(_ edge: Double) -> Double {
            guard edge > 0 else { return 1 }
            return min(1, max(minFraction, minVisiblePoints / edge))
        }
        return (m(Double(fullSize.width)), m(Double(fullSize.height)))
    }

    /// Crop vollständig klemmen: Größe in [Mindestgröße, 1], Lage im Bild. Unbrauchbare Werte → ganzes Bild.
    public static func clamp(_ crop: BoardCrop, fullSize: CGSize) -> BoardCrop {
        guard crop.isFinite else { return .full }
        let m = minSize(fullSize: fullSize)
        let w = min(1, max(m.width, crop.width))
        let h = min(1, max(m.height, crop.height))
        return BoardCrop(x: min(max(0, crop.x), 1 - w), y: min(max(0, crop.y), 1 - h), width: w, height: h)
    }

    // MARK: Größen

    /// Anzeigegröße des ganzen Bildes (F) aus Item-Größe und Crop.
    public static func fullSize(itemSize: CGSize, crop: BoardCrop?) -> CGSize {
        guard let c = effective(crop) else { return itemSize }
        return CGSize(width: CGFloat(Double(itemSize.width) / c.width), height: CGFloat(Double(itemSize.height) / c.height))
    }

    /// Anzeigegröße des sichtbaren Teils bei voller Größe `fullSize`.
    public static func visibleSize(fullSize: CGSize, crop: BoardCrop?) -> CGSize {
        let c = effective(crop) ?? .full
        return CGSize(width: CGFloat(Double(fullSize.width) * c.width), height: CGFloat(Double(fullSize.height) * c.height))
    }

    /// Dekodier-Zielgröße (längste Kante in Pixeln) für ein Item: das GANZE Bild in voller Größe F × Backing-Scale,
    /// damit der beschnittene Ausschnitt in Anzeigegröße scharf ist (und der Beschnittmodus das ganze Bild scharf zeigt).
    /// Begrenzt auf `cap`, mindestens 1. Ohne Crop wie bisher (Anzeigegröße × Scale, aufgerundet); Rundungsrauschen
    /// unter 1e-6 px über einer ganzen Zahl (z. B. 66 ÷ 0,3 = 220,00000000000003) gibt kein Extra-Pixel.
    public static func decodeMaxPixel(displaySize: CGSize, crop: BoardCrop?, scale: Double, cap: Int = maxDecodePixel) -> Int {
        let full = fullSize(itemSize: displaySize, crop: crop)
        let longest = Double(max(full.width, full.height)) * scale
        guard longest.isFinite else { return max(1, cap) }
        guard longest < Double(cap) else { return max(1, cap) }
        return max(1, min(cap, Int((longest - 1e-6).rounded(.up))))
    }

    /// Wie BoardLayout.reconciledSize, aber gegen das Seitenverhältnis des SICHTBAREN Teils (C7 + Crop).
    /// Ohne Crop exakt BoardLayout.reconciledSize. Mit Crop: passt das Seitenverhältnis bis auf ±1 pt, bleibt `stored`
    /// exakt; sonst neu eingepasst mit derselben längsten Kante (nicht gerundet, damit F exakt bleibt).
    public static func reconciledSize(stored: CGSize, orientedPixelWidth: Int, orientedPixelHeight: Int,
                                      crop: BoardCrop?) -> CGSize {
        guard let c = effective(crop) else {
            return BoardLayout.reconciledSize(stored: stored, orientedPixelWidth: orientedPixelWidth,
                                              orientedPixelHeight: orientedPixelHeight)
        }
        let vw = c.width * Double(orientedPixelWidth), vh = c.height * Double(orientedPixelHeight)
        let longest = Double(max(stored.width, stored.height))
        guard longest > 0, vw > 0, vh > 0 else { return stored }
        let k = longest / max(vw, vh)
        let refit = CGSize(width: CGFloat(vw * k), height: CGFloat(vh * k))
        if abs(refit.width - stored.width) <= 1 && abs(refit.height - stored.height) <= 1 { return stored }
        return refit
    }

    /// `CALayer.contentsRect` für einen Crop. contentsRect ist in Einheitskoordinaten; ob deren Ursprung bei
    /// CGImage-Contents oben (iOS-Konvention) oder unten links (macOS, nicht geflippter Layer) liegt, entscheidet
    /// `originTop` (Konstante in der App, Selftest prüft per Bitmap).
    public static func contentsRect(_ crop: BoardCrop?, originTop: Bool) -> CGRect {
        guard let c = effective(crop) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let y = originTop ? c.y : 1 - c.y - c.height
        return CGRect(x: CGFloat(c.x), y: CGFloat(y), width: CGFloat(c.width), height: CGFloat(c.height))
    }

    // MARK: Drehung (lokal ↔ Board, beide y nach unten)

    /// Lokaler Vektor → Board-Vektor (Drehung um `degrees`, positiv = gegen den Uhrzeigersinn auf dem Bildschirm).
    /// Umkehrung von BoardEditing.contains.
    public static func toBoard(_ v: CGPoint, rotation degrees: Double) -> CGPoint {
        let t = degrees * Double.pi / 180
        let x = Double(v.x), y = Double(v.y)
        return CGPoint(x: CGFloat(x * cos(t) + y * sin(t)), y: CGFloat(-x * sin(t) + y * cos(t)))
    }

    /// Board-Vektor → lokaler Vektor.
    public static func toLocal(_ v: CGPoint, rotation degrees: Double) -> CGPoint {
        toBoard(v, rotation: -degrees)
    }

    /// Board-Position eines Bildpunkts (u, v normiert im ganzen Bild, oben links) für ein Item mit Mittelpunkt,
    /// Größe, Rotation und Crop. Grundlage für „sichtbarer Teil bleibt an Ort“ (Selftest) und später den Export.
    public static func boardPoint(imageU u: Double, imageV v: Double, center: CGPoint, size: CGSize,
                                  rotation: Double, crop: BoardCrop?) -> CGPoint {
        let c = effective(crop) ?? .full
        let f = fullSize(itemSize: size, crop: crop)
        let local = CGPoint(x: CGFloat((u - c.midX) * Double(f.width)), y: CGFloat((v - c.midY) * Double(f.height)))
        let b = toBoard(local, rotation: rotation)
        return CGPoint(x: center.x + b.x, y: center.y + b.y)
    }

    // MARK: Griffe, Verschieben

    /// Griff ziehen. `delta` = Mausweg seit Beginn in LOKALEN pt (y nach unten), `start` = Crop bei Beginn.
    /// Die Gegenkante (bzw. -ecke) bleibt fest. Ohne ⇧: Kanten unabhängig, begrenzt auf das Bild und die Mindestgröße.
    /// Mit ⇧ (`keepAspect`): Seitenverhältnis von `start` bleibt (normiert = in pt, weil F fest ist); Ecke: die Achse mit
    /// der größeren relativen Änderung bestimmt den Faktor; Kante: die andere Achse wächst symmetrisch um ihre Mitte.
    public static func dragHandle(_ handle: CropHandle, start: BoardCrop, delta: CGPoint, fullSize: CGSize,
                                  keepAspect: Bool) -> BoardCrop {
        let s = clamp(start, fullSize: fullSize)
        guard fullSize.width > 0, fullSize.height > 0 else { return s }
        let dx = Double(delta.x) / Double(fullSize.width)
        let dy = Double(delta.y) / Double(fullSize.height)
        let m = minSize(fullSize: fullSize)
        func limit(_ v: Double, _ lo: Double, _ hi: Double) -> Double { hi < lo ? lo : min(max(v, lo), hi) }
        var l = s.minX, r = s.maxX, t = s.minY, b = s.maxY

        if !keepAspect {
            if handle.movesLeft { l = limit(l + dx, 0, r - m.width) }
            if handle.movesRight { r = limit(r + dx, l + m.width, 1) }
            if handle.movesTop { t = limit(t + dy, 0, b - m.height) }
            if handle.movesBottom { b = limit(b + dy, t + m.height, 1) }
            // Achse ohne bewegte Kante exakt übernehmen (nicht aus r − l neu rechnen: 0.2 + 0.4 − 0.2 ≠ 0.4 in Double).
            let movesX = handle.movesLeft || handle.movesRight
            let movesY = handle.movesTop || handle.movesBottom
            return BoardCrop(x: movesX ? l : s.x, y: movesY ? t : s.y,
                             width: movesX ? r - l : s.width, height: movesY ? b - t : s.height)
        }

        let w0 = s.width, h0 = s.height
        let horizontal = handle.movesLeft || handle.movesRight
        let vertical = handle.movesTop || handle.movesBottom
        let fx = horizontal ? (handle.movesRight ? (w0 + dx) : (w0 - dx)) / w0 : 1
        let fy = vertical ? (handle.movesBottom ? (h0 + dy) : (h0 - dy)) / h0 : 1
        var factor: Double
        if horizontal && vertical {
            factor = abs(fx - 1) >= abs(fy - 1) ? fx : fy
        } else {
            factor = horizontal ? fx : fy
        }
        // Verfügbarer Platz je Achse: von der festen Kante/Ecke bis zum Bildrand; bei Kanten-Griffen wächst die andere
        // Achse symmetrisch um die Mitte (Platz = 2 × Abstand zum näheren Rand).
        let availW: Double = horizontal ? (handle.movesRight ? 1 - l : r) : 2 * min(s.midX, 1 - s.midX)
        let availH: Double = vertical ? (handle.movesBottom ? 1 - t : b) : 2 * min(s.midY, 1 - s.midY)
        let maxFactor = min(availW / w0, availH / h0)
        let minFactor = max(m.width / w0, m.height / h0)
        factor = min(max(factor, min(minFactor, maxFactor)), maxFactor)
        let w = w0 * factor, h = h0 * factor
        let x: Double = horizontal ? (handle.movesRight ? l : r - w) : s.midX - w / 2
        let y: Double = vertical ? (handle.movesBottom ? t : b - h) : s.midY - h / 2
        // Nur Rundungsreste (1e-16) an den Rändern abfangen; die Größe bleibt, damit das Verhältnis exakt bleibt.
        let cw = min(1, w), ch = min(1, h)
        return BoardCrop(x: min(max(0, x), 1 - cw), y: min(max(0, y), 1 - ch), width: cw, height: ch)
    }

    /// Bild unter dem festen Rahmen verschieben. `delta` = Mausweg in LOKALEN pt: das Bild folgt der Maus, der Crop
    /// wandert also entgegengesetzt; begrenzt, so dass der Rahmen im Bild bleibt.
    public static func pan(start: BoardCrop, delta: CGPoint, fullSize: CGSize) -> BoardCrop {
        let s = clamp(start, fullSize: fullSize)
        guard fullSize.width > 0, fullSize.height > 0 else { return s }
        let x = s.x - Double(delta.x) / Double(fullSize.width)
        let y = s.y - Double(delta.y) / Double(fullSize.height)
        return BoardCrop(x: min(max(0, x), 1 - s.width), y: min(max(0, y), 1 - s.height), width: s.width, height: s.height)
    }

    /// „Sichtbarer Teil bleibt an Ort und Größe“: neue Item-Größe und neuer Mittelpunkt, wenn ein Item (Mittelpunkt,
    /// Größe, Rotation, alter Crop) auf `new` beschnitten wird und das Bild selbst dabei liegen bleibt.
    /// Größe = Crop × F (F bleibt). Mittelpunkt = alter Mittelpunkt + gedrehter Versatz der Ausschnitt-Mitten.
    public static func placement(center: CGPoint, size: CGSize, rotation: Double, old: BoardCrop?, new: BoardCrop?)
        -> (center: CGPoint, size: CGSize) {
        var editor = CropEditor(itemCenter: center, itemSize: size, crop: old, rotation: rotation)
        editor.setCropKeepingImage(new ?? .full)
        return (editor.frameCenter, editor.frameSize)
    }
}

/// Zustand während des Beschneidens: das ganze Bild liegt (gedreht um `rotation`) mit seiner Mitte bei `imageCenter`
/// (Board-Koordinaten), der Rahmen zeigt `crop`. Werte sind immer aus einem Startzustand + Gesamt-Mausweg berechnet
/// (kein Aufaddieren pro Ereignis → kein Driften, kein Zittern).
public struct CropEditor: Equatable, Sendable {
    /// Anzeigegröße des ganzen Bildes (F), fest während der Sitzung.
    public let fullSize: CGSize
    /// Darstellungs-Rotation während des Beschneidens (die App zeigt das Bild gerade: 0).
    public let rotation: Double
    public private(set) var imageCenter: CGPoint
    public private(set) var crop: BoardCrop

    /// Aus einem Item: der sichtbare Teil liegt mit seiner Mitte bei `itemCenter`; das ganze Bild wird so gelegt, dass
    /// das so bleibt (bei Darstellungs-Rotation `rotation`).
    public init(itemCenter: CGPoint, itemSize: CGSize, crop: BoardCrop?, rotation: Double) {
        let f = CropMath.fullSize(itemSize: itemSize, crop: crop)
        let c = CropMath.effective(crop) ?? .full
        fullSize = f
        self.rotation = rotation
        self.crop = c
        let offset = CropMath.toBoard(CGPoint(x: CGFloat((c.midX - 0.5) * Double(f.width)),
                                              y: CGFloat((c.midY - 0.5) * Double(f.height))), rotation: rotation)
        imageCenter = CGPoint(x: itemCenter.x - offset.x, y: itemCenter.y - offset.y)
    }

    /// Mitte des Rahmens (= Mitte des späteren Items) in Board-Koordinaten.
    public var frameCenter: CGPoint {
        let offset = CropMath.toBoard(CGPoint(x: CGFloat((crop.midX - 0.5) * Double(fullSize.width)),
                                              y: CGFloat((crop.midY - 0.5) * Double(fullSize.height))), rotation: rotation)
        return CGPoint(x: imageCenter.x + offset.x, y: imageCenter.y + offset.y)
    }

    /// Größe des Rahmens (= Größe des späteren Items) in pt.
    public var frameSize: CGSize { CropMath.visibleSize(fullSize: fullSize, crop: crop) }

    /// Board-Position eines Punkts im ganzen Bild (u, v normiert, oben links).
    public func boardPoint(u: Double, v: Double) -> CGPoint {
        let local = CGPoint(x: CGFloat((u - 0.5) * Double(fullSize.width)), y: CGFloat((v - 0.5) * Double(fullSize.height)))
        let b = CropMath.toBoard(local, rotation: rotation)
        return CGPoint(x: imageCenter.x + b.x, y: imageCenter.y + b.y)
    }

    /// Board-Punkt → normierte Bildkoordinate (u, v); außerhalb des Bildes < 0 bzw. > 1.
    public func imagePoint(_ p: CGPoint) -> (u: Double, v: Double) {
        let local = CropMath.toLocal(CGPoint(x: p.x - imageCenter.x, y: p.y - imageCenter.y), rotation: rotation)
        let u = fullSize.width > 0 ? 0.5 + Double(local.x) / Double(fullSize.width) : 0.5
        let v = fullSize.height > 0 ? 0.5 + Double(local.y) / Double(fullSize.height) : 0.5
        return (u, v)
    }

    /// Griffpunkt in Board-Koordinaten.
    public func handlePoint(_ h: CropHandle) -> CGPoint {
        let r = h.relativePosition
        return boardPoint(u: crop.x + r.u * crop.width, v: crop.y + r.v * crop.height)
    }

    /// Treffer-Test: nächster Griff innerhalb `tolerance` pt (Ecken vor Kanten bei gleichem Abstand), sonst Rahmen,
    /// sonst Bild, sonst daneben.
    public func hit(_ p: CGPoint, tolerance: Double) -> CropHit {
        var best: (handle: CropHandle, distance: Double)?
        for h in CropHandle.allCases {
            let q = handlePoint(h)
            let d = (Double(p.x - q.x) * Double(p.x - q.x) + Double(p.y - q.y) * Double(p.y - q.y)).squareRoot()
            guard d <= tolerance else { continue }
            if let b = best {
                if d < b.distance - 1e-9 || (abs(d - b.distance) <= 1e-9 && h.isCorner && !b.handle.isCorner) {
                    best = (h, d)
                }
            } else {
                best = (h, d)
            }
        }
        if let b = best { return .handle(b.handle) }
        let q = imagePoint(p)
        if q.u >= crop.minX && q.u <= crop.maxX && q.v >= crop.minY && q.v <= crop.maxY { return .frame }
        if q.u >= 0 && q.u <= 1 && q.v >= 0 && q.v <= 1 { return .image }
        return .outside
    }

    /// Neuer Crop, das Bild bleibt liegen (Griffe, Zurücksetzen): der Rahmen wandert.
    public mutating func setCropKeepingImage(_ newCrop: BoardCrop) {
        crop = CropMath.clamp(newCrop, fullSize: fullSize)
    }

    /// Neuer Crop, der Rahmen bleibt liegen (Verschieben): das Bild wandert darunter.
    public mutating func setCropKeepingFrame(_ newCrop: BoardCrop) {
        let frame = frameCenter
        crop = CropMath.clamp(newCrop, fullSize: fullSize)
        let offset = CropMath.toBoard(CGPoint(x: CGFloat((crop.midX - 0.5) * Double(fullSize.width)),
                                              y: CGFloat((crop.midY - 0.5) * Double(fullSize.height))), rotation: rotation)
        imageCenter = CGPoint(x: frame.x - offset.x, y: frame.y - offset.y)
    }

    /// Griff ziehen: Ergebnis = `start` + Gesamt-Mausweg `mouseDelta` (Board-pt).
    public mutating func dragHandle(_ h: CropHandle, from start: CropEditor, mouseDelta: CGPoint, keepAspect: Bool) {
        self = start
        let local = CropMath.toLocal(mouseDelta, rotation: rotation)
        setCropKeepingImage(CropMath.dragHandle(h, start: start.crop, delta: local, fullSize: fullSize, keepAspect: keepAspect))
    }

    /// Bild unter dem Rahmen verschieben: Ergebnis = `start` + Gesamt-Mausweg `mouseDelta` (Board-pt).
    public mutating func pan(from start: CropEditor, mouseDelta: CGPoint) {
        self = start
        let local = CropMath.toLocal(mouseDelta, rotation: rotation)
        setCropKeepingFrame(CropMath.pan(start: start.crop, delta: local, fullSize: fullSize))
    }

    /// R: ganzes Bild (noch nicht übernommen). Das Bild bleibt liegen, der Rahmen umfasst danach das ganze Bild.
    public mutating func reset() {
        crop = .full
    }

    /// Ergebnis zum Übernehmen: Mittelpunkt und Größe des Rahmens, Crop (nil = ganzes Bild).
    public var result: (center: CGPoint, size: CGSize, crop: BoardCrop?) {
        (frameCenter, frameSize, CropMath.effective(crop))
    }
}

/// Beschnitt im Modell übernehmen: Crop, Größe, Mittelpunkt, Rotation setzen und das Item nach oben legen (wie
/// Umsortieren; im Beschnittmodus lag es schon oben). Ganzes Bild → `crop = nil` (wird nicht geschrieben).
public enum CropEditing {
    @discardableResult
    public static func apply(_ document: inout BoardDocument, id: UUID, crop: BoardCrop?, center: CGPoint,
                             size: CGSize, rotation: Double) -> BoardItem? {
        guard var item = document.remove(id: id) else { return nil }
        item.crop = CropMath.effective(crop)
        item.center = BoardPoint(center)
        item.size = BoardSize(size)
        item.rotation = rotation
        document.items.append(item)
        return item
    }
}

/// Stop-Motion-Sequenzen des Beschnittmodus (Planer, 6 fps, Jitter nur in Zwischenframes, Reduce Motion: 1 Frame).
public enum CropSequences {
    /// Anteil des ersten Frames beim Geraderücken/Zurückdrehen.
    public static let turnProgress: [Double] = [0.5, 1]

    /// Öffnen (Rotation → 0) und Abbrechen (0 → alte Rotation): 2 Frames, Frame 0 auf halbem Weg (mit Jitter),
    /// Frame 1 = Ziel exakt.
    public static func turn<G: RandomNumberGenerator>(from: Pose, to: Pose, options: PlanOptions, using rng: inout G) -> StopMotionPlan {
        StopMotionPlanner.plan(SequenceSpec(start: from, end: to, frameCount: 2, progress: turnProgress, options: options),
                               using: &rng)
    }

    /// Übernehmen: 2 Frames. Frame 0 = beschnitten und noch gerade (mit Jitter), Frame 1 = final mit neuem Kipp.
    public static func settle<G: RandomNumberGenerator>(from straight: Pose, to target: Pose, options: PlanOptions,
                                                        using rng: inout G) -> StopMotionPlan {
        StopMotionPlanner.plan(SequenceSpec(start: straight, end: target, frameCount: 2, options: options), using: &rng)
    }
}
