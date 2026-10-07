import AppKit

// Übernommen aus spikes/eselsohr-drop/Sources/eselsohr-drop/Log.swift (Pfad und Kopf angepasst).
// Tags: [WIN] [PB] [DROP] [HANDOFF] [FOCUS] [MOTION] [STORE] [VIEW] (Ansichtsmodus)

/// Thread-sicheres Logging: jede Zeile mit ISO-Zeitstempel (ms) auf stdout UND angehängt an
/// ~/Library/Logs/Dropboard/dropboard.log. Wird auch von der Promise-Queue aus aufgerufen.
enum Log {
    private static let lock = NSLock()

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        return f
    }()

    static let filePath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Dropboard/dropboard.log").path

    private static let file: FileHandle? = {
        let fm = FileManager.default
        let dir = (filePath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: filePath) {
            fm.createFile(atPath: filePath, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: filePath)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    /// Monotone Zeit in Sekunden (für Dauer-Messungen).
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Millisekunden seit `t`, eine Nachkommastelle.
    static func ms(since t: TimeInterval) -> String {
        String(format: "%.1f", (now - t) * 1000)
    }

    static func line(_ tag: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = "\(formatter.string(from: Date())) \(tag) \(message)\n"
        let data = Data(text.utf8)
        try? FileHandle.standardOutput.write(contentsOf: data)
        try? file?.write(contentsOf: data)
    }
}

func fmt(_ p: NSPoint) -> String {
    String(format: "(%.1f,%.1f)", p.x, p.y)
}

func fmt(_ r: NSRect) -> String {
    String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
}

/// Datei-Prüfungen ohne Actor-Bindung (laufen auch auf Hintergrund-Queues). Aus dem Spike.
enum FileProbe {
    /// Pfad, Existenz und Größe. Löst File-Reference-URLs (file:///.file/id=…) auf.
    // ⚠️ VERIFIZIEREN (aus Spike): Finder liefert evtl. File-Reference-URLs; NSURL.filePathURL löst sie auf.
    static func info(_ url: URL) -> String {
        let resolved = (url as NSURL).filePathURL ?? url
        let path = resolved.path
        let exists = FileManager.default.fileExists(atPath: path)
        var s = "path=\(path) exists=\(exists)"
        if exists, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber {
            s += " size=\(size.int64Value)B"
        }
        if resolved != url { s += " (aus \(url.absoluteString))" }
        return s
    }

    /// Report 01, Offener Punkt 2 / T2: Lebensdauer der Quell-fileURL nach dem Drop.
    static func scheduleLifetimeChecks(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        for delay in [0.1, 1.0, 2.0, 5.0] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                for path in paths {
                    let exists = FileManager.default.fileExists(atPath: path)
                    Log.line("[DROP]", "Quelle +\(Int(delay * 1000))ms nach Drop exists=\(exists) \(path)")
                }
            }
        }
    }
}
