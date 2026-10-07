import Foundation
import ImageIO
import DropboardCore

/// Phase 4, Fix-Gruppe A (Import/Dekodieren/Store): reine Logik plus ImageIO/Dateisystem im Temp-Ordner.
/// Eintrag in SelfTest.run macht der Orchestrator: `FixASelfTest.run(t)`.
enum FixASelfTest {
    static func run(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("fixA: " + name, ok()) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dropboard-selftest-fixA-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }

        // MARK: B8 – Codable abwärtskompatibel (alte board.json ohne originalURL, ein Item ganz ohne source)
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
            },
            {
              "addedAt" : "2026-10-01T12:00:05Z",
              "center" : { "x" : 360, "y" : 120 },
              "fileName" : "7F9619FF-8B86-D011-B42D-00C04FC964FF.jpg",
              "id" : "7F9619FF-8B86-D011-B42D-00C04FC964FF",
              "rotation" : 1.25,
              "size" : { "height" : 220, "width" : 165 }
            }
          ],
          "version" : 1
        }
        """
        let oldDoc = try? BoardStore.makeDecoder().decode(BoardDocument.self, from: Data(oldJSON.utf8))
        check("B8 alte board.json (ohne originalURL) lädt", oldDoc?.items.count == 2)
        check("B8 alte Felder bleiben, originalURL = nil",
              oldDoc?.items[0].source?.app == "com.apple.Safari" && oldDoc?.items[0].source?.route == "imageData"
                && oldDoc?.items[0].source?.originalURL == nil)
        check("B8 Item ganz ohne source lädt (source = nil)", oldDoc != nil && oldDoc?.items[1].source == nil)

        let withURL = BoardItem(id: UUID(), fileName: "x.png", center: BoardPoint(x: 1, y: 2), rotation: 0.5,
                                size: BoardSize(width: 220, height: 110), addedAt: BoardClock.timestamp(),
                                source: ItemSource(route: "imageData", app: "com.google.Chrome",
                                                   originalURL: "https://example.com/bild.jpg"))
        let roundDoc = BoardDocument(items: [withURL])
        let encoded = try? BoardStore.makeEncoder().encode(roundDoc)
        let decoded = encoded.flatMap { try? BoardStore.makeDecoder().decode(BoardDocument.self, from: $0) }
        check("B8 Roundtrip mit originalURL verlustfrei", decoded == roundDoc)
        let noURLData = try? BoardStore.makeEncoder().encode(BoardDocument(items: [BoardItem(
            id: UUID(), fileName: "y.png", center: BoardPoint(x: 0, y: 0), rotation: 0, size: BoardSize(width: 1, height: 1),
            addedAt: BoardClock.timestamp(), source: ItemSource(route: "fileURL"))]))
        check("B8 nil-originalURL wird nicht geschrieben (Datei bleibt für alte Versionen gleich)",
              noURLData.map { !String(decoding: $0, as: UTF8.self).contains("originalURL") } == true)

        // MARK: B8 – Herkunfts-URL filtern
        check("B8 https-URL bleibt", ImageImporter.sanitizedOriginURL("https://example.com/a.jpg") == "https://example.com/a.jpg")
        check("B8 URL wird getrimmt", ImageImporter.sanitizedOriginURL("  http://x.y/z \n") == "http://x.y/z")
        check("B8 data:-URL wird verworfen", ImageImporter.sanitizedOriginURL("data:image/png;base64,AAAA") == nil)
        check("B8 file:-URL wird verworfen", ImageImporter.sanitizedOriginURL("file:///tmp/a.png") == nil)
        check("B8 überlange URL (> 2048) wird verworfen",
              ImageImporter.sanitizedOriginURL("https://e.com/" + String(repeating: "a", count: 3000)) == nil)

        // MARK: C14 – Promise nur mit Bild-UTI
        check("C14 public.png ist Bild", ImageImporter.announcesImage(["public.png"]))
        check("C14 public.heic ist Bild", ImageImporter.announcesImage(["public.heic"]))
        check("C14 com.adobe.pdf ist kein Bild", !ImageImporter.announcesImage(["com.adobe.pdf"]))
        check("C14 keine fileTypes = kein Bild", !ImageImporter.announcesImage([]))
        check("C14 gemischt (pdf + jpeg) = Bild", ImageImporter.announcesImage(["com.adobe.pdf", "public.jpeg"]))
        check("C14 Endung jpg (Alt-Promise) = Bild", ImageImporter.announcesImage(["jpg"]))
        check("C14 Mail (com.apple.mail.email) ist kein Bild", !ImageImporter.announcesImage(["com.apple.mail.email"]))

        // MARK: P3/C15 – kurzlebige Quellen, APFS-Klon
        check("P3 Screenshot-Temp-Pfad ist kurzlebig",
              ImageImporter.isShortLivedTemporary(path: "/var/folders/ab/xyz/T/TemporaryItems/NSIRD_screencaptureui_Z9ThME/Bildschirmfoto.png"))
        check("P3 /private/var/folders ist kurzlebig", ImageImporter.isShortLivedTemporary(path: "/private/var/folders/ab/T/x.png"))
        check("P3 Bilder-Ordner ist nicht kurzlebig", !ImageImporter.isShortLivedTemporary(path: "/Users/max/Pictures/a.png"))

        // MARK: C7 – Orientierung und Größenabgleich
        let o6 = BoardLayout.orientedPixelSize(width: 4032, height: 3024, orientation: 6)
        let o1 = BoardLayout.orientedPixelSize(width: 4032, height: 3024, orientation: 1)
        let o3 = BoardLayout.orientedPixelSize(width: 4032, height: 3024, orientation: 3)
        let o8 = BoardLayout.orientedPixelSize(width: 4032, height: 3024, orientation: 8)
        let o0 = BoardLayout.orientedPixelSize(width: 4032, height: 3024, orientation: 0)
        func dims(_ p: (width: Int, height: Int)) -> [Int] { [p.width, p.height] }
        check("C7 Orientierung 6/8 tauscht Breite und Höhe", dims(o6) == [3024, 4032] && dims(o8) == [3024, 4032])
        check("C7 Orientierung 1/3/unbekannt bleibt",
              dims(o1) == [4032, 3024] && dims(o3) == [4032, 3024] && dims(o0) == [4032, 3024])
        check("C7 alte quere Größe für Hochkant-Foto wird korrigiert (220x165 → 165x220)",
              BoardLayout.reconciledSize(stored: CGSize(width: 220, height: 165), orientedPixelWidth: 3024,
                                         orientedPixelHeight: 4032) == CGSize(width: 165, height: 220))
        check("C7 passende Größe bleibt exakt (165x220)",
              BoardLayout.reconciledSize(stored: CGSize(width: 165, height: 220), orientedPixelWidth: 3024,
                                         orientedPixelHeight: 4032) == CGSize(width: 165, height: 220))
        check("C7 Rundungsdifferenz ±1 pt bleibt gespeichert (220x147 bei 4000x2667)",
              BoardLayout.reconciledSize(stored: CGSize(width: 220, height: 147), orientedPixelWidth: 4000,
                                         orientedPixelHeight: 2667) == CGSize(width: 220, height: 147))

        // MARK: C7/P4 – echter ImageIO-Weg: JPEG 40x20 mit EXIF-Orientierung 6 → hochkant
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let jpegURL = dir.appendingPathComponent("o6.jpg")
            let tiffData = try makeTestImage(type: "public.tiff", orientation: 6)
            try makeTestImage(type: "public.jpeg", orientation: 6).write(to: jpegURL)
            let fresh = ImageDecoder.decode(url: jpegURL, size: nil, scale: 2)
            check("C7 Dekoder: EXIF 6 → Anzeigegröße hochkant 110x220", fresh?.size == CGSize(width: 110, height: 220))
            check("C7 Dekoder: Pixel sind gedreht (Höhe > Breite)",
                  fresh.map { $0.cgImage.height > $0.cgImage.width } == true)
            check("P4 Thumbnail vergrößert nicht über die Quelle (≤ 40 px)",
                  fresh.map { max($0.cgImage.width, $0.cgImage.height) <= 40 } == true)
            let legacy = ImageDecoder.decode(url: jpegURL, size: CGSize(width: 220, height: 110), scale: 2)
            check("C7 Dekoder korrigiert alte quere Größe 220x110 → 110x220", legacy?.size == CGSize(width: 110, height: 220))
            let fromData = ImageDecoder.decode(data: tiffData, size: nil, scale: 2)
            check("B2 Dekodieren aus Drop-Daten (TIFF, EXIF 6) → 110x220", fromData?.size == CGSize(width: 110, height: 220))
            let pngURL = dir.appendingPathComponent("tiff.png")
            try ImageDecoder.writePNG(from: tiffData, to: pngURL)
            let png = ImageDecoder.decode(url: pngURL, size: nil, scale: 2)
            check("P2 TIFF → PNG (Hintergrund-Weg) behält Orientierung (in Pixel eingerechnet)",
                  png?.size == CGSize(width: 110, height: 220))
            check("Dekoder: keine Bilddatei → nil",
                  ImageDecoder.decode(data: Data("kein bild".utf8), size: nil, scale: 2) == nil)

            // clonefile im Temp-Ordner (APFS auf dem Mac)
            let cloneDst = dir.appendingPathComponent("klon.jpg")
            check("P3 clonefile im selben Volume gelingt (errno 0)", ImageImporter.cloneFile(from: jpegURL, to: cloneDst) == 0)
            check("P3 Klon hat identischen Inhalt", (try? Data(contentsOf: cloneDst)) == (try? Data(contentsOf: jpegURL)))
            check("P3 clonefile auf vorhandenes Ziel scheitert (EEXIST), ohne zu überschreiben",
                  ImageImporter.cloneFile(from: pngURL, to: cloneDst) == EEXIST
                    && (try? Data(contentsOf: cloneDst)) == (try? Data(contentsOf: jpegURL)))
        } catch {
            check("ImageIO-Testbilder anlegen (\(error))", false)
        }

        // MARK: C11 – in die Ablagefläche klemmen
        let area = CGRect(x: 48, y: 72, width: 900, height: 600)
        func item(_ x: Double, _ y: Double, w: Double = 220, h: Double = 147, file: String = "f.png") -> BoardItem {
            BoardItem(id: UUID(), fileName: file, center: BoardPoint(x: x, y: y), rotation: 1, size: BoardSize(width: w, height: h),
                      addedAt: BoardClock.timestamp())
        }
        let inside = item(300, 300)
        let outside = item(2400, 300)
        let huge = item(500, 500, w: 2000, h: 2000)
        var items = [inside, outside, huge]
        let moved = BoardLayout.clampIntoArea(&items, area: area)
        check("C11 nur Items außerhalb werden verschoben", moved == [outside.id, huge.id])
        check("C11 Item innerhalb bleibt bitgenau", items[0] == inside)
        check("C11 Item bei x=2400 liegt danach ganz in der Fläche (838,300)",
              items[1].center == BoardPoint(x: 838, y: 300) && area.contains(items[1].frame))
        check("C11 zu großes Item → Mitte der Fläche", items[2].center == BoardPoint(x: Double(area.midX), y: Double(area.midY)))
        var none = [inside]
        check("C11 leere Fläche: nichts passiert", BoardLayout.clampIntoArea(&none, area: .zero).isEmpty && none == [inside])

        // MARK: C9 – Items ohne Bilddatei entfernen
        let store = BoardStore(boardDirectory: dir.appendingPathComponent("board", isDirectory: true))
        do {
            try store.prepareDirectories()
            let a = item(120, 120, file: "a.png"), b = item(360, 120, file: "b.png"), c = item(600, 120, file: "c.png")
            try Data("a".utf8).write(to: store.imageURL(fileName: "a.png"))
            try Data("c".utf8).write(to: store.imageURL(fileName: "c.png"))
            var doc = BoardDocument(items: [a, b, c])
            let removed = doc.removeItems { !fm.fileExists(atPath: store.imageURL(fileName: $0.fileName).path) }
            check("C9 Item ohne Datei wird entfernt", removed == [b])
            check("C9 übrige Items behalten ihre Reihenfolge", doc.items == [a, c])

            // C10 – Rückrollen eines Löschens
            var editing = BoardDocument(items: [a, b, c])
            let original = editing
            let index = editing.index(id: b.id) ?? -1
            BoardEditing.delete(&editing, id: b.id)
            editing.insert(b, at: index)
            check("C10 Rückrollen stellt Dokument und Stapelreihenfolge exakt wieder her", editing == original && index == 1)
            editing.insert(b, at: 0)
            check("C10 erneutes Einfügen derselben id erzeugt kein Duplikat", editing.items.count == 3)
            var tail = BoardDocument(items: [a])
            tail.insert(c, at: 99)
            check("C10 Index wird begrenzt (99 → ans Ende)", tail.items == [a, c])

            // P10 – Save-Queue: Reihenfolge, letzter Snapshot liegt auf der Platte, Fehler kommt an
            let queue = BoardSaveQueue(label: "Dropboard.selftest.save")
            let results = ResultBox()
            var snapshot = BoardDocument()
            for x in [a, b, c] {
                snapshot.upsert(x)
                queue.save(snapshot, to: store) { results.append($0) }   // Wert-Snapshot je Aufruf
            }
            snapshot.items.removeAll()   // spätere Änderung am Original darf eingereihte Snapshots nicht berühren
            queue.flush()
            check("P10 alle 3 Speichervorgänge erfolgreich", results.successes == 3 && results.failures == 0)
            check("P10 Reihenfolge: zuletzt eingereihter Snapshot liegt auf der Platte",
                  (try? store.load()) == BoardDocument(items: [a, b, c]))
            let blocker = dir.appendingPathComponent("datei-statt-ordner")
            try Data("x".utf8).write(to: blocker)
            let broken = BoardStore(boardDirectory: blocker.appendingPathComponent("sub", isDirectory: true))
            let failBox = ResultBox()
            queue.save(BoardDocument(items: [a]), to: broken) { failBox.append($0) }
            queue.flush()
            check("P10/C10 Schreibfehler kommt als failure an (Grundlage für Rückrollen)", failBox.failures == 1)
        } catch {
            check("C9/C10/P10 Testordner (\(error))", false)
        }

        // MARK: C20 – Quarantäne
        struct Boom: Error {}
        let ok = BoardStore.resolveLoad(load: { BoardDocument(items: [inside]) }, quarantine: { throw Boom() })
        check("C20 lesbar → loaded, Speichern erlaubt", ok.document == BoardDocument(items: [inside]) && ok.allowsSaving)
        let quarantined = BoardStore.resolveLoad(load: { throw Boom() }, quarantine: { URL(fileURLWithPath: "/tmp/board.corrupt-1.json") })
        var isQuarantined = false
        if case .quarantined = quarantined { isQuarantined = true }
        check("C20 defekt + gesichert → leer, Speichern erlaubt",
              isQuarantined && quarantined.document == BoardDocument() && quarantined.allowsSaving)
        let locked = BoardStore.resolveLoad(load: { throw Boom() }, quarantine: { throw Boom() })
        var isUnrecoverable = false
        if case .unrecoverable = locked { isUnrecoverable = true }
        check("C20 defekt + Umbenennen scheitert → leer, Speichern GESPERRT",
              isUnrecoverable && locked.document == BoardDocument() && !locked.allowsSaving)

        // MARK: P1/P9 – Startargument
        let diagOn = try? LaunchOptions.parse(["Dropboard", "--diag-pasteboard"])
        let diagOff = try? LaunchOptions.parse(["Dropboard"])
        check("P1 --diag-pasteboard wird angenommen", diagOn?.diagPasteboard == true)
        check("P1 ohne Argument: Diagnose aus", diagOff?.diagPasteboard == false)
    }

    /// 40x20-Testbild (linke Hälfte schwarz) mit EXIF/TIFF-Orientierung, in Daten kodiert.
    private static func makeTestImage(type: String, orientation: Int) throws -> Data {
        struct MakeError: Error {}
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw MakeError() }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        guard let image = ctx.makeImage() else { throw MakeError() }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { throw MakeError() }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MakeError() }
        return data as Data
    }
}

/// Thread-sicherer Sammler für Completion-Ergebnisse der Save-Queue (läuft auf deren Queue).
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ok = 0
    private var failed = 0

    func append(_ result: Result<Double, Error>) {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success: ok += 1
        case .failure: failed += 1
        }
    }

    var successes: Int { lock.lock(); defer { lock.unlock() }; return ok }
    var failures: Int { lock.lock(); defer { lock.unlock() }; return failed }
}
