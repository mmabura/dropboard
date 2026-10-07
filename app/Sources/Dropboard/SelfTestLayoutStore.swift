import Foundation
import DropboardCore

/// Teil 2: Layout – Grid-Snap, Overlap, Free-Slot-Finder (Lesereihenfolge, Konfliktfreiheit), Drop-Snap, Größen, Kipp.
enum LayoutSelfTest {
    static func run(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("layout: " + name, ok()) }
        let m = LayoutMetrics.standard
        let g = CGFloat(m.grid)
        let square = CGSize(width: 220, height: 220)

        // Snap
        check("snap (13,37) → (24,48)", BoardLayout.snap(CGPoint(x: 13, y: 37), grid: 24) == CGPoint(x: 24, y: 48))
        check("snap (11,35) → (0,24)", BoardLayout.snap(CGPoint(x: 11, y: 35), grid: 24) == CGPoint(x: 0, y: 24))
        check("snap mit grid 0 ist Identität", BoardLayout.snap(CGPoint(x: 13.5, y: 2), grid: 0) == CGPoint(x: 13.5, y: 2))

        // Overlap
        let r = CGRect(x: 0, y: 0, width: 10, height: 10)
        check("overlap: echte Überlappung", BoardLayout.overlaps(r, CGRect(x: 5, y: 5, width: 10, height: 10)))
        check("overlap: Kanten berühren zählt nicht (gap 0)", !BoardLayout.overlaps(r, CGRect(x: 10, y: 0, width: 10, height: 10)))
        check("overlap: Kanten berühren zählt mit gap 12", BoardLayout.overlaps(r, CGRect(x: 10, y: 0, width: 10, height: 10), gap: 12))
        check("overlap: Abstand 12 bei gap 12 ist frei", !BoardLayout.overlaps(r, CGRect(x: 22, y: 0, width: 10, height: 10), gap: 12))
        check("frame(center:size:) ist zentriert",
              BoardLayout.frame(center: CGPoint(x: 100, y: 50), size: CGSize(width: 40, height: 20)) == CGRect(x: 80, y: 40, width: 40, height: 20))

        // Free-Slot: erste Position oben links, dann rechts daneben
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let first = BoardLayout.findFreeSlot(size: square, occupied: [], area: area, grid: m.grid, gap: m.gap)
        check("free slot: leeres Board → oben links (120,120)", first == CGPoint(x: 120, y: 120))
        let second = BoardLayout.findFreeSlot(size: square, occupied: [BoardLayout.frame(center: CGPoint(x: 120, y: 120), size: square)],
                                              area: area, grid: m.grid, gap: m.gap)
        check("free slot: zweites Bild rechts daneben (360,120)", second == CGPoint(x: 360, y: 120))
        check("free slot: Bereich zu klein → nil",
              BoardLayout.findFreeSlot(size: square, occupied: [], area: CGRect(x: 0, y: 0, width: 200, height: 800),
                                       grid: m.grid, gap: m.gap) == nil)

        // Free-Slot: füllen bis voll, gemischte Größen
        let sizes = [CGSize(width: 220, height: 147), CGSize(width: 147, height: 220), square, CGSize(width: 220, height: 124)]
        var placed: [CGRect] = []
        var centers: [CGPoint] = []
        var guardCount = 0
        while guardCount < 500, let c = BoardLayout.findFreeSlot(size: sizes[guardCount % sizes.count], occupied: placed,
                                                                  area: area, grid: m.grid, gap: m.gap) {
            placed.append(BoardLayout.frame(center: c, size: sizes[guardCount % sizes.count]))
            centers.append(c)
            guardCount += 1
        }
        check("free slot: Board läuft voll und liefert dann nil (\(placed.count) Bilder)", guardCount < 500 && placed.count >= 8)
        var pairwiseFree = true
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count where BoardLayout.overlaps(placed[i], placed[j], gap: m.gap - 0.001) {
                pairwiseFree = false
            }
        }
        check("Konfliktfreiheit: keine zwei Rahmen überlappen (inkl. Abstand)", pairwiseFree)
        check("alle Rahmen liegen in der Ablagefläche", placed.allSatisfy { area.contains($0) })
        check("alle Mittelpunkte liegen auf dem Grid",
              centers.allSatisfy { $0.x.truncatingRemainder(dividingBy: g) == 0 && $0.y.truncatingRemainder(dividingBy: g) == 0 })

        // Lesereihenfolge bei gleicher Größe: y nie kleiner als vorher, in einer Zeile x aufsteigend
        var sameSize: [CGRect] = []
        var order: [CGPoint] = []
        while let c = BoardLayout.findFreeSlot(size: square, occupied: sameSize, area: area, grid: m.grid, gap: m.gap) {
            sameSize.append(BoardLayout.frame(center: c, size: square))
            order.append(c)
        }
        let readingOrder = zip(order, order.dropFirst()).allSatisfy { $0.y < $1.y || ($0.y == $1.y && $0.x < $1.x) }
        check("Lesereihenfolge: oben links → rechts → nächste Zeile (\(order.count) Bilder)", readingOrder && order.count == 12)

        // Drop an Cursorposition
        let usable = CGRect(x: 48, y: 72, width: 900, height: 600)
        let d1 = BoardLayout.dropCenter(cursor: CGPoint(x: 500, y: 300), size: square, area: usable, grid: m.grid)
        check("dropCenter: Mitte gesnappt (504,312)", d1 == CGPoint(x: 504, y: 312))
        let d2 = BoardLayout.dropCenter(cursor: CGPoint(x: 5, y: 5), size: square, area: usable, grid: m.grid)
        check("dropCenter: Ecke wird in die Fläche gezogen und bleibt drin",
              usable.contains(BoardLayout.frame(center: d2, size: square)))
        check("dropCenter: Ecke bleibt auf dem Grid",
              d2.x.truncatingRemainder(dividingBy: g) == 0 && d2.y.truncatingRemainder(dividingBy: g) == 0)

        // Größen und Kipp
        check("fittedSize 4000x3000 → 220x165", BoardLayout.fittedSize(pixelWidth: 4000, pixelHeight: 3000, longestEdge: 220) == CGSize(width: 220, height: 165))
        check("fittedSize 1000x2000 → 110x220", BoardLayout.fittedSize(pixelWidth: 1000, pixelHeight: 2000, longestEdge: 220) == CGSize(width: 110, height: 220))
        check("fittedSize 0 → nil", BoardLayout.fittedSize(pixelWidth: 0, pixelHeight: 10, longestEdge: 220) == nil)
        check("Platzhalter ist so groß wie das größte mögliche Bild",
              m.placeholderSize.width == CGFloat(m.longestEdge) && m.placeholderSize.height == CGFloat(m.longestEdge))
        var rng = SplitMix64(seed: 11)
        var tiltOK = true, positive = 0
        for _ in 0..<10_000 {
            let tilt = BoardLayout.randomTilt(range: m.tiltRange, using: &rng)
            if abs(tilt) < 1 - 1e-9 || abs(tilt) > 2 + 1e-9 { tiltOK = false }
            if tilt > 0 { positive += 1 }
        }
        check("Zufallsrotation: Betrag in [1, 2] Grad (10000 Samples)", tiltOK)
        check("Zufallsrotation: beide Vorzeichen (\(positive) positiv)", positive > 4000 && positive < 6000)
    }
}

/// Teil 3: Store – JSON-Roundtrip in temporärem Ordner, atomisches Schreiben, Fehlerfälle, Dateinamen.
enum StoreSelfTest {
    static func run(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("store: " + name, ok()) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dropboard-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let store = BoardStore(boardDirectory: dir)

        check("Standardordner endet auf Dropboard/Boards/default",
              BoardStore.defaultBoardDirectory().path.hasSuffix("Library/Application Support/Dropboard/Boards/default"))
        check("Pfade: board.json, images/, incoming/",
              store.documentURL.lastPathComponent == "board.json" && store.imagesDirectory.lastPathComponent == "images"
                && store.incomingDirectory.lastPathComponent == "incoming")

        do {
            try store.prepareDirectories()
            let initial = try store.load()
            check("fehlende board.json → leeres Board", initial == BoardDocument())

            let a = BoardItem(id: UUID(), fileName: "a.png", center: BoardPoint(x: 120, y: 120), rotation: -1.25,
                              size: BoardSize(width: 220, height: 147), addedAt: BoardClock.timestamp(),
                              source: ItemSource(route: "promise", originalName: "Bildschirmfoto.png", app: "com.apple.finder"))
            let b = BoardItem(id: UUID(), fileName: "b.heic", center: BoardPoint(x: 360.5, y: 96), rotation: 1.75,
                              size: BoardSize(width: 110, height: 220), addedAt: BoardClock.timestamp(Date(timeIntervalSince1970: 1_791_000_000.7)))
            let doc = BoardDocument(items: [a, b])
            try store.save(doc)
            let loaded = try store.load()
            check("JSON-Roundtrip: geladen == gespeichert", loaded == doc)
            check("Version wird geschrieben", loaded.version == BoardDocument.currentVersion)
            check("Zeitstempel auf ganze Sekunden", loaded.items[1].addedAt.timeIntervalSince1970 == 1_791_000_000)
            let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            check("atomisch: keine Hilfsdateien neben board.json (\(entries.sorted()))",
                  Set(entries) == ["board.json", "images", "incoming"])

            // Speichern überschreibt vollständig
            var changed = loaded
            changed.remove(id: a.id)
            try store.save(changed)
            let reloaded = try store.load()
            check("erneut speichern: nur noch 1 Item", reloaded.items.map { $0.id } == [b.id])

            // upsert ersetzt statt zu verdoppeln
            var up = changed
            var moved = b
            moved.center = BoardPoint(x: 1, y: 2)
            up.upsert(moved)
            check("upsert ersetzt vorhandenes Item", up.items.count == 1 && up.items[0].center == BoardPoint(x: 1, y: 2))

            // Zu neue Version
            try Data("{\"version\": 99, \"items\": []}".utf8).write(to: store.documentURL, options: .atomic)
            var threwVersion = false
            do { _ = try store.load() } catch { threwVersion = true }
            check("Version 99 wird abgelehnt", threwVersion)

            // Defekte Datei → werfen, Quarantäne, danach leer
            try Data("{kaputt".utf8).write(to: store.documentURL, options: .atomic)
            var threwCorrupt = false
            do { _ = try store.load() } catch { threwCorrupt = true }
            check("defekte board.json wirft", threwCorrupt)
            let quarantined = try store.quarantineDocument()
            check("Quarantäne verschiebt die Datei", fm.fileExists(atPath: quarantined.path) && !fm.fileExists(atPath: store.documentURL.path))
            let afterQuarantine = try store.load()
            check("nach Quarantäne leeres Board", afterQuarantine == BoardDocument())
        } catch {
            check("unerwarteter Fehler: \(error)", false)
        }

        // Dateinamen: eindeutig, Endung bereinigt
        let id = UUID()
        check("Dateiname <uuid>.png bei Endung PNG", BoardStore.imageFileName(id: id, fileExtension: "PNG") == "\(id.uuidString).png")
        check("Dateiname-Fallback .png bei leerer/ungültiger Endung",
              BoardStore.imageFileName(id: id, fileExtension: "") == "\(id.uuidString).png"
                && BoardStore.imageFileName(id: id, fileExtension: "p/ng") == "\(id.uuidString).png")
        let names = Set((0..<1000).map { _ in BoardStore.imageFileName(id: UUID(), fileExtension: "jpg") })
        check("Konfliktfreiheit: 1000 Dateinamen eindeutig", names.count == 1000)
    }
}
