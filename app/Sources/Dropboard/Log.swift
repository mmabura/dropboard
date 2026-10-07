import AppKit

// Übernommen aus spikes/eselsohr-drop/Sources/eselsohr-drop/Log.swift (Pfad und Kopf angepasst).
// Tags: [WIN] [PB] [DROP] [HANDOFF] [FOCUS] [MOTION] [STORE] [VIEW] (Ansichtsmodus) [CROP] (Beschnitt, E11) [SETTINGS] (Menüleiste, Einstellungen, Hotkey)

/// Thread-sicheres Logging: jede Zeile mit ISO-Zeitstempel (ms) in ~/Library/Logs/Dropboard/dropboard.log, auf
/// stdout nur, wenn stdout ein Terminal ist oder DROPBOARD_VERBOSE=1 gesetzt ist. Wird auch von der Promise-Queue
/// aus aufgerufen.
/// P7: Der Aufrufer (meist Main-Thread) nimmt nur den Zeitpunkt und hängt die Zeile an eine serielle Queue;
/// Formatieren, stdout- und Datei-Schreiben laufen dort. Rotation ab 5 MB nach `dropboard.log.1`.
/// `flush()` wartet, bis alles geschrieben ist (Beenden; zusätzlich per atexit).
/// Hinweis: Ein Startargument `--verbose` bräuchte LaunchOptions.swift (nicht im Dateiset von Fix-Gruppe B);
/// bis dahin Umgebungsvariable DROPBOARD_VERBOSE=1.
enum Log {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        return f
    }()

    static let filePath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Dropboard/dropboard.log").path

    /// stdout zusätzlich zur Datei (Terminal oder DROPBOARD_VERBOSE=1).
    static let echoToStdout: Bool = isatty(STDOUT_FILENO) != 0
        || ProcessInfo.processInfo.environment["DROPBOARD_VERBOSE"] == "1"

    private static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "dropboard.log", qos: .utility)
        // ⚠️ VERIFIZIEREN: Closure ohne Captures als @convention(c) für atexit; schreibt beim exit() (Ctrl-C,
        // Single-Instance-Abbruch) noch ausstehende Zeilen.
        _ = atexit { Log.flush() }
        return q
    }()

    /// Nur auf `queue` benutzt.
    private static let sink = LogFileSink(path: filePath, limit: DropboardConfig.logRotateBytes)

    /// Monotone Zeit in Sekunden (für Dauer-Messungen).
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Millisekunden seit `t`, eine Nachkommastelle.
    static func ms(since t: TimeInterval) -> String {
        String(format: "%.1f", (now - t) * 1000)
    }

    static func line(_ tag: String, _ message: String) {
        let date = Date()
        queue.async {
            let data = Data("\(formatter.string(from: date)) \(tag) \(message)\n".utf8)
            if echoToStdout { try? FileHandle.standardOutput.write(contentsOf: data) }
            sink.write(data)
        }
    }

    /// Wartet, bis alle bisherigen Zeilen geschrieben sind. Nicht von der Log-Queue aus aufrufen.
    static func flush() {
        queue.sync {}
    }
}

/// Datei-Ziel des Logs mit einfacher Rotation (P7). Nicht thread-sicher – nur auf der Log-Queue benutzen.
private final class LogFileSink {
    private let path: String
    private let limit: UInt64
    private var handle: FileHandle?
    private var size: UInt64 = 0

    init(path: String, limit: UInt64) {
        self.path = path
        self.limit = limit
        open()
        if LogRotation.shouldRotate(size: size, limit: limit) { rotate() }
    }

    func write(_ data: Data) {
        if LogRotation.shouldRotate(size: size, limit: limit) { rotate() }
        guard let h = handle else { return }
        do {
            try h.write(contentsOf: data)
            size += UInt64(data.count)
        } catch {
            // Datei weg (z. B. von Hand gelöscht) → beim nächsten Mal neu öffnen.
            try? h.close()
            handle = nil
            open()
        }
    }

    private func open() {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let old = LogRotation.rotatedPath(path)
        try? fm.removeItem(atPath: old)
        try? fm.moveItem(atPath: path, toPath: old)
        open()
        let note = Data("\(Date()) [WIN] Log rotiert → \(old)\n".utf8)
        try? handle?.write(contentsOf: note)
        size += UInt64(note.count)
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
