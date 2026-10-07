import AppKit
import DropboardCore

/// App-Delegate: baut die Teile zusammen und hängt die System-Beobachter ein.
///   BoardStore (Core)   – Dateien, board.json
///   BoardScene          – Layer-Baum (Papier, Noise, Abdunklung, Bilder)
///   BoardController     – Dokument, Platzierung, Import-Ergebnisse
///   ImageImporter       – Drop-Annahme (Promise → fileURL → Bilddaten → URL)
///   BoardPresenter      – Panels, Handoff, Realtime-Öffnen/Schließen
///   DragCoordinator     – Zustandsautomat der Drag-Session
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let store: BoardStore
    private let motion: MotionPreferences
    private var scene: BoardScene?
    private var boardController: BoardController?
    private var importer: ImageImporter?
    private var presenter: BoardPresenter?
    private var coordinator: DragCoordinator?
    private var diagnostics: Diagnostics?

    init(options: LaunchOptions) {
        self.options = options
        store = BoardStore(boardDirectory: options.boardDirectory ?? BoardStore.defaultBoardDirectory())
        motion = MotionPreferences(forced: options.forceReduceMotion)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try store.prepareDirectories()
        } catch {
            Log.line("[STORE]", "FEHLER Ordner anlegen \(store.boardDirectory.path): \(error.localizedDescription)")
        }

        let screen = ScreenGeometry.screenUnderMouse()
        let scale = screen.backingScaleFactor
        let noise = PaperArt.loadNoiseTile()
        let scene = BoardScene(size: screen.frame.size, scale: scale, noiseTile: noise)
        let presenter = BoardPresenter(handoff: options.handoff, screen: screen, scene: scene, noiseTile: noise)
        let board = BoardController(store: store, scene: scene, usableArea: presenter.usableArea,
                                    seed: UInt64(Date().timeIntervalSince1970 * 1000))
        let importer = ImageImporter(store: store, scale: scale)
        importer.sink = board
        let diagnostics = Diagnostics(presenter: presenter)
        let coordinator = DragCoordinator(presenter: presenter, board: board, importer: importer,
                                          motion: motion, diagnostics: diagnostics)
        presenter.attach(coordinator)
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

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(activeSpaceChanged(_:)),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func logStart(_ screen: NSScreen) {
        let pi = ProcessInfo.processInfo
        Log.line("[WIN]", "Start Dropboard handoff=\(options.handoff.rawValue) "
            + "macOS=\(pi.operatingSystemVersionString) pid=\(pi.processIdentifier) "
            + "activationPolicy=\(NSApp.activationPolicy().rawValue) log=\(Log.filePath)")
        diagnostics?.logLevels()
        Log.line("[WIN]", "Bildschirme=\(NSScreen.screens.count) frame=\(fmt(screen.frame)) visibleFrame=\(fmt(screen.visibleFrame)) "
            + "backingScale=\(screen.backingScaleFactor) safeAreaTop=\(screen.safeAreaInsets.top)")
        Log.line("[MOTION]", "Bewegung reduzieren: system=\(motion.system) forced=\(motion.forced) effective=\(motion.effective) "
            + "expandDelay=\(Int(DropboardConfig.expandDelay * 1000))ms dropCloseDelay=\(Int((DropboardConfig.dropCloseDelay * 1000).rounded()))ms")
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
        Log.line("[FOCUS]", "App aktiviert: \(app?.bundleIdentifier ?? "nil") (\(app?.localizedName ?? "?"))"
            + (own ? " !!! DROPBOARD SELBST AKTIVIERT" : ""))
    }

    /// Auflösung/Monitore geändert: Eselsohr neu positionieren, Board-Größe und Ablagefläche nachziehen.
    @objc private func screenParametersChanged(_ note: Notification) {
        guard let presenter = presenter else { return }
        let screen = presenter.ear.screen ?? ScreenGeometry.screenUnderMouse()
        presenter.relayout(screen: screen)
        boardController?.usableArea = presenter.usableArea
        importer?.scale = screen.backingScaleFactor
        Log.line("[WIN]", "Bildschirmparameter geändert Bildschirme=\(NSScreen.screens.count) frame=\(fmt(screen.frame)) "
            + "backingScale=\(screen.backingScaleFactor)")
        diagnostics?.logWindows("Bildschirm-Wechsel")
    }
}
