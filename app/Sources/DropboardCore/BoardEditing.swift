import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Ansichtsmodus (Briefing-Schritt 7): reine Logik für Auswahl, Umsortieren, Löschen und die
// Stop-Motion-Sequenzen des Board-Blatts. Nur Foundation/CoreGraphics, deshalb im Selftest prüfbar.
// Koordinaten wie überall in DropboardCore: Board-Koordinaten, pt, oben links, y nach unten.

public enum BoardEditing {
    /// Liegt `point` auf dem (gedrehten) Bild? Rotation wie BoardItem.rotation: Grad, positiv = gegen den
    /// Uhrzeigersinn auf dem Bildschirm. Der Punkt wird in das ungedrehte Item-System zurückgedreht.
    public static func contains(_ item: BoardItem, point: CGPoint) -> Bool {
        let dx = Double(point.x) - item.center.x
        let dyUp = -(Double(point.y) - item.center.y)          // Board y nach unten → y nach oben
        let theta = item.rotation * Double.pi / 180.0
        let lx = dx * cos(theta) + dyUp * sin(theta)            // Drehung um −theta
        let ly = -dx * sin(theta) + dyUp * cos(theta)
        return abs(lx) <= item.size.width / 2 && abs(ly) <= item.size.height / 2
    }

    /// Oberstes Item unter `point` (Stapelreihenfolge: letztes Element liegt oben). `nil` = leeres Papier.
    public static func hitTest(_ items: [BoardItem], at point: CGPoint) -> UUID? {
        for item in items.reversed() where contains(item, point: point) {
            return item.id
        }
        return nil
    }

    /// Ziel beim Loslassen eines gezogenen Bildes: wie ein Drop aufs Board (begrenzt, aufs Grid gesnappt).
    public static func snappedCenter(dragged: CGPoint, size: CGSize, area: CGRect, grid: Double) -> CGPoint {
        BoardLayout.dropCenter(cursor: dragged, size: size, area: area, grid: grid)
    }

    /// Umsortieren: Mittelpunkt und Rotation ersetzen und das Item nach oben legen (ans Ende der Liste,
    /// wie beim Ziehen sichtbar). Rückgabe: das geänderte Item, `nil` wenn die id fehlt (Dokument unverändert).
    @discardableResult
    public static func move(_ document: inout BoardDocument, id: UUID, to center: CGPoint, rotation: Double) -> BoardItem? {
        guard var item = document.remove(id: id) else { return nil }
        item.center = BoardPoint(center)
        item.rotation = rotation
        document.items.append(item)
        return item
    }

    /// Löschen aus dem Modell. Rückgabe: das entfernte Item, `nil` wenn die id fehlt.
    @discardableResult
    public static func delete(_ document: inout BoardDocument, id: UUID) -> BoardItem? {
        document.remove(id: id)
    }
}

/// Stop-Motion-Sequenzen für das Board-Blatt im Ansichtsmodus. Aufblättern = StopMotionSequences.reveal
/// (3 Frames, Scale 0.6 → 0.85 → 1.0). Schließen = reveal rückwärts, ebenfalls 3 Frames.
public enum ViewModeSequences {
    public static let frameCount = 3

    /// Aufblättern: unverändert die reveal-Sequenz aus dem Planer.
    public static func open<G: RandomNumberGenerator>(target: Pose, options: PlanOptions, using rng: inout G) -> StopMotionPlan {
        StopMotionSequences.reveal(target: target, options: options, using: &rng)
    }

    /// Schließen: reveal rückwärts und sofort beginnend (E1). Der erste reveal-Frame rückwärts wäre der
    /// unveränderte Vollzustand (sähe wie Lag aus), deshalb: Frame 0 = 0.85, Frame 1 = 0.6 (beide mit Jitter
    /// aus derselben reveal-Planung), Frame 2 = weg (Scale 0.6, opacity 0). Danach blendet der Aufrufer das Fenster aus.
    /// Reduce Motion (E2): genau ein Frame „weg“, nicht animiert, kein Zufall verbraucht.
    public static func close<G: RandomNumberGenerator>(target: Pose, options: PlanOptions, using rng: inout G) -> StopMotionPlan {
        var gone = target
        gone.scale = target.scale * StopMotionSequences.revealStartScale
        gone.opacity = 0
        if options.reduceMotion {
            return StopMotionPlan(frames: [gone], keyTimes: [0, 1], duration: 0)
        }
        let reveal = StopMotionSequences.reveal(target: target, options: options, using: &rng)
        let frames = [reveal.frames[1], reveal.frames[0], gone]
        let keyTimes = (0...frames.count).map { Double($0) / Double(frames.count) }
        return StopMotionPlan(frames: frames, keyTimes: keyTimes, duration: Double(frames.count) * StopMotionClock.frameDuration)
    }
}

public enum BoardTrashError: Error, CustomStringConvertible {
    case missingImage(String)

    public var description: String {
        switch self {
        case .missingImage(let name): return "Bilddatei fehlt: \(name)"
        }
    }
}

/// Löschen im Ansichtsmodus: Bilddateien werden nicht hart gelöscht, sondern nach `trash/` verschoben.
///   <boardDirectory>/trash/<uuid>.<ext>
/// Der Ordner entsteht erst beim ersten Löschen (prepareDirectories bleibt unverändert).
public extension BoardStore {
    var trashDirectory: URL { boardDirectory.appendingPathComponent("trash", isDirectory: true) }

    /// `images/<fileName>` → `trash/<fileName>`. Gibt es den Namen in trash/ schon, wird `-1`, `-2`, …
    /// vor die Endung gehängt. Nur die letzte Pfadkomponente von `fileName` zählt (kein Ausbrechen per `../`).
    @discardableResult
    func moveImageToTrash(fileName: String) throws -> URL {
        let fm = FileManager.default
        let name = (fileName as NSString).lastPathComponent
        let source = imageURL(fileName: name)
        guard !name.isEmpty, fm.fileExists(atPath: source.path) else { throw BoardTrashError.missingImage(name) }
        try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let target = Self.uniqueTrashURL(in: trashDirectory, fileName: name) { fm.fileExists(atPath: $0.path) }
        try fm.moveItem(at: source, to: target)
        return target
    }

    /// Erster freier Name: `<name>`, dann `<basis>-1.<ext>`, `<basis>-2.<ext>`, …
    static func uniqueTrashURL(in directory: URL, fileName: String, exists: (URL) -> Bool) -> URL {
        let first = directory.appendingPathComponent(fileName)
        guard exists(first) else { return first }
        let ns = fileName as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        func numbered(_ n: Int) -> URL {
            directory.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
        }
        var n = 1
        var candidate = numbered(n)
        while exists(candidate) {
            n += 1
            candidate = numbered(n)
        }
        return candidate
    }
}
