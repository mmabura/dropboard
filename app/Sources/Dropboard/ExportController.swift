import AppKit
import DropboardCore

/// Bedienung des Exports (E12): Menüleiste „Board exportieren“ und ⌘E im Ansichtsmodus. Ein Klick exportiert direkt,
/// ohne Speichern-Dialog, in den Exportordner (Standard: Schreibtisch) und zeigt die Datei im Finder.
/// Main Thread nur Start und Ende; Rendern/Schreiben läuft auf `Exporter.queue`. Es läuft höchstens ein Export.
///
/// Fokus: Export und Finder-Anzeige aktivieren Dropboard nicht (activateFileViewerSelecting holt den Finder nach vorn,
/// gewollt). Einzige Ausnahme ist der ausdrücklich angeklickte Ordner-Dialog „Anderer Ordner…“ (siehe chooseFolder).
@MainActor
final class ExportController {
    private let settings: Settings
    private let board: BoardController
    private(set) var isRunning = false
    /// AppController markiert damit die erwartete Aktivierung (Ordner-Dialog), damit `[FOCUS]` sie nicht als Befund meldet.
    var onExpectedActivation: ((Bool) -> Void)?
    /// Nach Ende eines Exports (Menü neu zeichnen).
    var onStateChange: (() -> Void)?

    init(settings: Settings, board: BoardController) {
        self.settings = settings
        self.board = board
    }

    var hasItems: Bool { !board.document.items.isEmpty }
    var canExport: Bool { hasItems && !isRunning }

    /// Zielordner: eigener Ordner, falls er noch existiert, sonst Schreibtisch (mit Logzeile).
    func resolvedDirectory() -> URL {
        if let custom = settings.exportFolder {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: custom.path, isDirectory: &isDir), isDir.boolValue {
                return custom
            }
            Log.line("[EXPORT]", "Exportordner fehlt \(custom.path) → Schreibtisch")
        }
        return Settings.desktopDirectory
    }

    /// Export starten. `reason` nur fürs Log. Leeres Board / laufender Export → nur Logzeile.
    func export(format: ExportFormat, reason: String) {
        guard hasItems else {
            Log.line("[EXPORT]", "Export \(format.rawValue) grund=\(reason): Board ist leer → nichts exportiert")
            return
        }
        guard !isRunning else {
            Log.line("[EXPORT]", "Export \(format.rawValue) grund=\(reason) ignoriert: es läuft schon ein Export")
            return
        }
        let date = Date()
        let directory = resolvedDirectory()
        let url = Exporter.targetURL(in: directory, format: format, date: date)
        let request = ExportRequest(format: format, dpi: settings.exportDPI, area: settings.exportArea,
                                    boardSize: board.scene.size, screenScale: Double(board.scene.scale),
                                    date: date, creator: "Dropboard \(StatusMenuController.versionText)")
        isRunning = true
        onStateChange?()
        // Offene Platzhalter (Datei noch nicht da) stehen nicht im Dokument und fehlen im Export – bewusst.
        Log.line("[EXPORT]", "Export angefordert grund=\(reason) \(settings.exportSummary) items=\(board.document.items.count) "
            + "platzhalter=\(board.pendingCount) (ausgelassen) ziel=\(url.path)")
        let t = Log.now
        Exporter.exportInBackground(document: board.document, store: board.store, request: request, to: url) { [weak self] outcome in
            self?.finish(outcome, mainMs: Log.ms(since: t))
        }
    }

    private func finish(_ outcome: ExportOutcome, mainMs: String) {
        isRunning = false
        onStateChange?()
        switch outcome {
        case .success(let result):
            Log.line("[EXPORT]", result.logLine)
            // Finder kommt nach vorn (gewollt, E12); Dropboard wird dabei nicht aktiviert.
            NSWorkspace.shared.activateFileViewerSelecting([result.url])
            Log.line("[EXPORT]", "Im Finder gezeigt \(result.url.lastPathComponent) (gesamt \(mainMs)ms)")
        case .failure(let message):
            Log.line("[EXPORT]", "FEHLER Export: \(message)")
        }
    }

    // MARK: Exportordner

    func useDesktop() {
        let old = settings.exportFolder?.path ?? "Schreibtisch"
        settings.exportFolder = nil
        Log.line("[EXPORT]", "Exportordner \(old) → Schreibtisch (\(Settings.desktopDirectory.path))")
    }

    /// „Anderer Ordner…“: NSOpenPanel für Ordner. Öffnet NUR auf ausdrücklichen Klick im Menü.
    /// Ausnahme vom Grundsatz „Dropboard aktiviert sich nie“: Ein Dialog einer nie aktiven `.accessory`-App käme
    /// sonst nicht nach vorn bzw. bekäme keine Tasten. Deshalb hier bewusst `NSApp.activate()`, nur für diesen Dialog,
    /// geloggt; danach wird die vorher vordere App wieder aktiviert.
    // ⚠️ VERIFIZIEREN: NSApp.activate() (ab macOS 14) holt den Dialog nach vorn; NSOpenPanel.begin ohne Elternfenster;
    // NSRunningApplication.activate(options: []) gibt den Fokus zurück (macOS 14: kooperative Aktivierung, evtl. ohne
    // Wirkung – dann bleibt Dropboard aktiv bis zum nächsten Klick in eine andere App; Log `[FOCUS]`).
    func chooseFolder() {
        let previous = NSWorkspace.shared.frontmostApplication
        Log.line("[EXPORT]", "Ordner-Dialog: NSApp.activate – vom Nutzer ausgelöste Ausnahme (Klick „Anderer Ordner…“) "
            + "vorher=\(previous?.bundleIdentifier ?? "nil")")
        onExpectedActivation?(true)
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Als Exportordner wählen"
        panel.message = "Ordner für Dropboard-Exporte"
        panel.directoryURL = resolvedDirectory()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                self?.finishChoose(ok: response == .OK, url: panel.url, previous: previous)
            }
        }
    }

    private func finishChoose(ok: Bool, url: URL?, previous: NSRunningApplication?) {
        if ok, let url = url {
            let old = settings.exportFolder?.path ?? "Schreibtisch"
            settings.exportFolder = url
            Log.line("[EXPORT]", "Exportordner \(old) → \(url.path) (Bookmark gespeichert=\(settings.exportFolder != nil))")
        } else {
            Log.line("[EXPORT]", "Ordner-Dialog abgebrochen, Exportordner bleibt \(settings.exportFolder?.path ?? "Schreibtisch")")
        }
        let own = ProcessInfo.processInfo.processIdentifier
        if let prev = previous, prev.processIdentifier != own, !prev.isTerminated {
            let done = prev.activate(options: [])
            Log.line("[EXPORT]", "Ordner-Dialog zu → \(prev.bundleIdentifier ?? "?") wieder aktiviert=\(done)")
        }
        onExpectedActivation?(false)
        onStateChange?()
    }
}
