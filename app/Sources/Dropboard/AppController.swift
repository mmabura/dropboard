import AppKit
import DropboardCore

/// App-Delegate: baut die Teile zusammen und hängt die System-Beobachter ein.
///   BoardStore (Core)   – Dateien, board.json
///   BoardScene          – Layer-Baum (Papier, Noise, Abdunklung, Bilder)
///   BoardController     – Dokument, Platzierung, Import-Ergebnisse
///   ImageImporter       – Drop-Annahme (Promise → fileURL → Bilddaten → URL)
///   BoardPresenter      – Panels, Handoff, Realtime-Öffnen/Schließen
///   DragCoordinator     – Zustandsautomat der Drag-Session und des Ansichtsmodus (ViewModeController)
///   Settings            – Ecke, Verzögerung, Login-Spiegel (UserDefaults, Schritt 8)
///   StatusMenuController – Menüleisten-Symbol + Menü; GlobalHotKey – Ausblenden-Hotkey (Carbon)
@MainActor
final class AppController: NSObject, NSApplicationDelegate, StatusMenuHost {
    private let options: LaunchOptions
    private let store: BoardStore
    private let motion: MotionPreferences
    private let settings: Settings
    private var statusMenu: StatusMenuController?
    private var hideHotKey: GlobalHotKey?
    private var lastHideToggle: TimeInterval = -1
    private var scene: BoardScene?
    private var boardController: BoardController?
    private var importer: ImageImporter?
    private var presenter: BoardPresenter?
    private var coordinator: DragCoordinator?
    private var diagnostics: Diagnostics?
    /// E12: Export (Menüleiste, ⌘E im Ansichtsmodus).
    private var exporter: ExportController?
    /// Ordner-Dialog offen: die eigene Aktivierung ist erwartet (vom Nutzer ausgelöst), kein Befund.
    private var expectingActivation = false

    init(options: LaunchOptions) {
        self.options = options
        store = BoardStore(boardDirectory: options.boardDirectory ?? BoardStore.defaultBoardDirectory())
        motion = MotionPreferences(forced: options.forceReduceMotion)
        settings = Settings()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // S1: vor allem anderen (kein Fenster, kein Hotkey, kein Board-Zugriff), damit sich zwei Instanzen nicht
        // gegenseitig stören.
        exitIfAnotherInstanceRuns()
        do {
            try store.prepareDirectories()
        } catch {
            Log.line("[STORE]", "FEHLER Ordner anlegen \(store.boardDirectory.path): \(error.localizedDescription)")
        }
        // Bildschirm-Beobachter zuerst: ohne Bildschirm startet das Eselsohr bei der nächsten Notification (C2).
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        startIfScreenAvailable()
    }

    func applicationWillTerminate(_ notification: Notification) {
        boardController?.flushPendingSaves()   // P10: eingereihte board.json-Schreibvorgänge abschließen
        Log.flush()   // P7: asynchrones Log vollständig schreiben
    }

    /// S1: Single-Instance-Schutz. Läuft schon eine ältere Dropboard-Instanz (gleiche Bundle-ID, andere PID),
    /// beendet sich diese sofort – OHNE die andere zu aktivieren (kein Fokusraub). Ohne Bundle-ID (swift run) kein Check.
    private func exitIfAnotherInstanceRuns() {
        let bundleID = Bundle.main.bundleIdentifier
        let me = NSRunningApplication.current
        let running = bundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) } ?? []
        let infos = running.filter { !$0.isTerminated }.map { InstanceInfo(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        guard let other = SingleInstance.instanceToYieldTo(ownPID: me.processIdentifier, ownLaunch: me.launchDate,
                                                           bundleID: bundleID, running: infos) else {
            if bundleID == nil {
                Log.line("[WIN]", "Instanz-Check übersprungen (keine Bundle-ID, swift run)")
            } else if infos.count > 1 {
                Log.line("[WIN]", "Weitere Instanz(en) gefunden, diese ist die älteste → läuft weiter "
                    + "pids=\(infos.map { $0.pid })")
            }
            return
        }
        Log.line("[WIN]", "Bereits eine Instanz aktiv (pid \(other.pid)) – beende mich (pid \(me.processIdentifier), "
            + "pfad=\(Bundle.main.bundleURL.path))")
        Log.flush()
        exit(0)
    }

    /// Eselsohr, Board und Menüleiste aufbauen, sobald ein Bildschirm da ist (C2: Mac mini ohne Monitor beim Login).
    /// Standard-Bildschirm ist der Hauptbildschirm mit Menüleiste (C18/B12), nicht der unter der Maus.
    private func startIfScreenAvailable() {
        guard presenter == nil else { return }
        guard let screen = ScreenGeometry.primaryScreen() else {
            Log.line("[WIN]", "Kein Bildschirm beim Start → warte auf didChangeScreenParameters (Eselsohr erst dann)")
            return
        }
        let scale = screen.backingScaleFactor
        let noise = PaperArt.loadNoiseTile()
        let scene = BoardScene(size: screen.frame.size, scale: scale, noiseTile: noise)
        let presenter = BoardPresenter(handoff: options.handoff, screen: screen, corner: settings.corner,
                                       scene: scene, noiseTile: noise)
        let board = BoardController(store: store, scene: scene, usableArea: presenter.usableArea,
                                    seed: UInt64(Date().timeIntervalSince1970 * 1000))
        let importer = ImageImporter(store: store, scale: scale)
        importer.sink = board
        let diagnostics = Diagnostics(presenter: presenter)
        let coordinator = DragCoordinator(presenter: presenter, board: board, importer: importer,
                                          motion: motion, diagnostics: diagnostics, settings: settings)
        presenter.attach(coordinator)
        let exporter = ExportController(settings: settings, board: board)
        exporter.onExpectedActivation = { [weak self] expected in
            self?.expectingActivation = expected
        }
        exporter.onStateChange = { [weak self] in
            self?.statusMenu?.refresh()
        }
        coordinator.setExportHandler { [weak self] in
            self?.exportFromShortcut()
        }
        self.exporter = exporter
        self.scene = scene
        self.presenter = presenter
        self.boardController = board
        self.importer = importer
        self.diagnostics = diagnostics
        self.coordinator = coordinator

        logStart(screen)
        board.loadFromDisk()
        presenter.showEar()   // nie makeKeyAndOrderFront / NSApp.activate (Report 02)
        diagnostics.logWindows("Start")
        diagnostics.logFocus("Start")
        setUpMenuBarAndHotKey()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(activeSpaceChanged(_:)),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func logStart(_ screen: NSScreen) {
        let pi = ProcessInfo.processInfo
        Log.line("[WIN]", "Start Dropboard handoff=\(options.handoff.rawValue) "
            + "macOS=\(pi.operatingSystemVersionString) pid=\(pi.processIdentifier) "
            + "activationPolicy=\(NSApp.activationPolicy().rawValue) log=\(Log.filePath)")
        diagnostics?.logLevels()
        Log.line("[WIN]", "Bildschirme=\(NSScreen.screens.count) Eselsohr auf Hauptbildschirm (screens[0], Menüleiste) frame=\(fmt(screen.frame)) visibleFrame=\(fmt(screen.visibleFrame)) "
            + "backingScale=\(screen.backingScaleFactor) safeAreaTop=\(screen.safeAreaInsets.top)")
        Log.line("[MOTION]", "Bewegung reduzieren: system=\(motion.system) forced=\(motion.forced) effective=\(motion.effective) "
            + "expandDelay=\(settings.expandDelayMs)ms dropCloseDelay=\(Int((DropboardConfig.dropCloseDelay * 1000).rounded()))ms")
        Log.line("[STORE]", "Board-Ordner=\(store.boardDirectory.path) ablage=\(fmt(presenter?.usableArea ?? .zero))")
        Log.line("[DROP]", "registriert=[\(ImageImporter.acceptedTypes.map { $0.rawValue }.joined(separator: ","))]")
    }

    @objc private func activeSpaceChanged(_ note: Notification) {
        Log.line("[WIN]", "activeSpaceDidChange")
        diagnostics?.logWindows("Space-Wechsel")
        diagnostics?.logFocus("Space-Wechsel")
    }

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let own = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let note: String
        if own {
            note = expectingActivation ? " (erwartet: Ordner-Dialog Exportordner, vom Nutzer ausgelöst)" : " !!! DROPBOARD SELBST AKTIVIERT"
        } else {
            note = ""
        }
        Log.line("[FOCUS]", "App aktiviert: \(app?.bundleIdentifier ?? "nil") (\(app?.localizedName ?? "?"))" + note)
    }

    /// Auflösung/Monitore geändert: ALLE Phasen sauber beenden (C4), Eselsohr auf dem Hauptbildschirm neu
    /// positionieren, Board-Größe und Ablagefläche nachziehen. Ohne Bildschirm: Eselsohr weg, auf den nächsten warten (C2).
    /// ⚠️ VERIFIZIEREN: didChangeScreenParameters kommt auch beim Wechsel von 0 auf 1 Bildschirm (Monitor wieder an).
    @objc private func screenParametersChanged(_ note: Notification) {
        guard let presenter = presenter else {
            Log.line("[WIN]", "Bildschirmparameter geändert Bildschirme=\(NSScreen.screens.count) (noch nicht gestartet)")
            startIfScreenAvailable()
            return
        }
        coordinator?.endAllImmediately(reason: "Bildschirmparameter geändert")
        guard let screen = ScreenGeometry.primaryScreen() else {
            presenter.screenLost()
            Log.line("[WIN]", "Bildschirmparameter geändert Bildschirme=0 → Eselsohr ausgeblendet, warte auf Bildschirm")
            statusMenu?.refresh()
            return
        }
        presenter.relayout(screen: screen)
        boardController?.usableArea = presenter.usableArea
        importer?.scale = screen.backingScaleFactor
        Log.line("[WIN]", "Bildschirmparameter geändert Bildschirme=\(NSScreen.screens.count) frame=\(fmt(screen.frame)) "
            + "backingScale=\(screen.backingScaleFactor)")
        diagnostics?.logWindows("Bildschirm-Wechsel")
    }

    // MARK: Menüleiste und Einstellungen (Schritt 8)

    private func setUpMenuBarAndHotKey() {
        statusMenu = StatusMenuController(settings: settings, host: self)
        let loginText: String
        if LoginItem.isAppBundle {
            let status = LoginItem.status
            settings.launchAtLogin = status == .enabled   // Spiegel nachziehen (Wahrheit: SMAppService)
            loginText = LoginItem.describe(status)
        } else {
            loginText = "nur in Dropboard.app (läuft aus \(Bundle.main.bundleURL.path))"
        }
        Log.line("[SETTINGS]", "Start \(settings.summary) version=\(StatusMenuController.versionText) "
            + "anmeldung=\(loginText) ear=\(fmt(presenter?.earFrame ?? .zero))")
        Log.line("[SETTINGS]", "Menüleisten-Symbol angelegt \(statusMenu?.diagnosticsText ?? "fehlt")")
        Log.line("[EXPORT]", "Start \(settings.exportSummary) (Menü „Board exportieren“, ⌘E im Ansichtsmodus)")

        let hotKey = GlobalHotKey(id: 1) { [weak self] in
            self?.toggleEarHidden(source: "Hotkey \(HideHotKey.display)")
        }
        let result = hotKey.register(keyCode: HideHotKey.keyCode, modifiers: HideHotKey.carbonModifiers)
        hideHotKey = hotKey
        Log.line("[SETTINGS]", "Hotkey \(HideHotKey.display) (Eselsohr ausblenden) registriert=\(result.ok)"
            + (result.ok ? "" : " FEHLER \(result.status)") + " (Carbon RegisterEventHotKey, ohne Berechtigung)")
    }

    var isEarHidden: Bool { presenter?.earHidden ?? false }

    func openBoardFromMenu() {
        guard let coordinator = coordinator else { return }
        diagnostics?.logFocus("vor Board öffnen (Menü)")
        coordinator.openViewing(reason: "Menüleiste")
    }

    func toggleEarHidden(source: String) {
        guard let presenter = presenter else { return }
        let now = Log.now
        if now - lastHideToggle < HideHotKey.debounce {
            Log.line("[SETTINGS]", "Ausblenden doppelt ausgelöst quelle=\(source) → ignoriert (<\(Int(HideHotKey.debounce * 1000))ms)")
            return
        }
        lastHideToggle = now
        let hide = !presenter.earHidden
        if hide { coordinator?.endAllImmediately(reason: "Eselsohr ausgeblendet") }
        presenter.setEarHidden(hide)
        Log.line("[SETTINGS]", "Eselsohr \(hide ? "ausgeblendet" : "eingeblendet") quelle=\(source) "
            + "visible=\(presenter.ear.isVisible) (nicht gespeichert; nach Neustart sichtbar)")
        statusMenu?.refresh()
    }

    func applyCorner(_ corner: EarCorner) {
        guard let presenter = presenter else { return }
        let old = settings.corner
        settings.corner = corner
        coordinator?.endAllImmediately(reason: "Ecke geändert")
        let screen = ScreenGeometry.primaryScreen()
        presenter.setCorner(corner, screen: screen)
        boardController?.usableArea = presenter.usableArea
        Log.line("[SETTINGS]", "Ecke \(old.rawValue) → \(corner.rawValue) ear=\(fmt(presenter.earFrame)) "
            + "visibleFrame=\(screen.map { fmt($0.visibleFrame) } ?? "kein Bildschirm") versteckt=\(presenter.earHidden) gespeichert=\(settings.corner == corner)")
        diagnostics?.logWindows("Ecke geändert")
    }

    func applyExpandDelay(ms: Int) {
        let old = settings.expandDelayMs
        settings.expandDelayMs = ms
        Log.line("[SETTINGS]", "Verzögerung bis Aufklappen \(old)ms → \(settings.expandDelayMs)ms (ab dem nächsten Drag)")
    }

    func revealBoardFolder() {
        Log.line("[SETTINGS]", "Board-Ordner im Finder zeigen \(store.boardDirectory.path)")
        NSWorkspace.shared.activateFileViewerSelecting([store.boardDirectory])
    }

    func revealLogFile() {
        Log.line("[SETTINGS]", "Protokoll im Finder zeigen \(Log.filePath)")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Log.filePath)])
    }

    // MARK: Export (E12)

    var canExportBoard: Bool { exporter?.canExport ?? false }
    var isExportRunning: Bool { exporter?.isRunning ?? false }

    func exportBoard(format: ExportFormat) {
        guard let exporter = exporter else { return }
        settings.exportFormat = format   // zuletzt gewähltes Format (⌘E)
        exporter.export(format: format, reason: "Menüleiste")
    }

    func chooseExportFolder() {
        exporter?.chooseFolder()
    }

    func useDesktopExportFolder() {
        exporter?.useDesktop()
    }

    /// ⌘E im Ansichtsmodus: Export im zuletzt gewählten Format. Der Ansichtsmodus schließt dabei (Stop-Motion wie Esc),
    /// sonst läge das Board über dem Finder-Fenster, das die Datei zeigt. Leeres Board: nur Hinweis, Board bleibt offen.
    private func exportFromShortcut() {
        guard let exporter = exporter else { return }
        let format = settings.exportFormat
        guard exporter.hasItems else {
            Log.line("[EXPORT]", "⌘E: Board ist leer → nichts exportiert")
            return
        }
        coordinator?.closeViewing(reason: "Export ⌘E")
        exporter.export(format: format, reason: "⌘E im Ansichtsmodus")
    }

    func quitFromMenu() {
        Log.line("[SETTINGS]", "Dropboard beenden (Menüleiste)")
        Log.flush()
        hideHotKey?.unregister()
        NSApp.terminate(nil)
    }
}
