import AppKit
import DropboardCore

/// Was das Menüleisten-Menü auslösen kann (implementiert vom AppController).
@MainActor
protocol StatusMenuHost: AnyObject {
    var isEarHidden: Bool { get }
    func openBoardFromMenu()
    func toggleEarHidden(source: String)
    func applyCorner(_ corner: EarCorner)
    func applyExpandDelay(ms: Int)
    func revealBoardFolder()
    func revealLogFile()
    func quitFromMenu()
    // Export (E12)
    var canExportBoard: Bool { get }
    var isExportRunning: Bool { get }
    func exportBoard(format: ExportFormat)
    func chooseExportFolder()
    func useDesktopExportFolder()
}

/// Menüleisten-Symbol (Briefing-Schritt 8): Bedienen und Beenden ohne Terminal.
/// Ein Klick aufs Symbol öffnet das Menü; jede Einstellung ist ein Klick im (Unter-)Menü und wirkt sofort.
/// Nur Systemmenü-Darstellung (Häkchen, keine eigenen Farben) – keine Systemblau-Akzente in eigener UI.
///
/// ⚠️ VERIFIZIEREN: NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) in einer
/// `.accessory`-App (LSUIElement) – erwartet: Symbol erscheint rechts in der Menüleiste; ein Klick öffnet das Menü,
/// OHNE Dropboard zu aktivieren (sonst Log `!!! DROPBOARD SELBST AKTIVIERT`).
/// ⚠️ VERIFIZIEREN: macOS 26 kann Menüleisten-Symbole pro App ausblenden (Systemeinstellungen → Menüleiste);
/// fehlt das Symbol, dort „Dropboard“ erlauben. Bei vielen Symbolen kann es auch hinter der Kamera-Aussparung landen.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let settings: Settings
    private weak var host: StatusMenuHost?
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let hideItem: NSMenuItem
    private let cornerItems: [(EarCorner, NSMenuItem)]
    private let delayItems: [(Int, NSMenuItem)]
    private let loginItem: NSMenuItem
    // Export (E12)
    private let exportParent: NSMenuItem
    private let exportFormatItems: [(ExportFormat, NSMenuItem)]
    private let exportDPIItems: [(Int, NSMenuItem)]
    private let exportAreaItems: [(ExportArea, NSMenuItem)]
    private let exportDesktopItem: NSMenuItem
    private let exportCustomItem: NSMenuItem
    private let exportChooseItem: NSMenuItem

    static func title(of corner: EarCorner) -> String {
        switch corner {
        case .topRight: return "Oben rechts"
        case .topLeft: return "Oben links"
        case .bottomRight: return "Unten rechts"
        case .bottomLeft: return "Unten links"
        }
    }

    static func title(of format: ExportFormat) -> String {
        switch format {
        case .png: return "Als PNG"
        case .pdf: return "Als PDF"
        case .folder: return "Originale als Ordner"
        }
    }

    static func title(of area: ExportArea) -> String {
        switch area {
        case .content: return "Nur Inhalt"
        case .full: return "Ganze Fläche"
        }
    }

    /// Version aus der Info.plist (in Dropboard.app), sonst „dev“ (swift run).
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else { return "dev" }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty { return "\(version) (Build \(build))" }
        return version
    }

    init(settings: Settings, host: StatusMenuHost) {
        self.settings = settings
        self.host = host
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu(title: "Dropboard")
        hideItem = NSMenuItem(title: "Eselsohr ausblenden", action: nil, keyEquivalent: HideHotKey.menuKeyEquivalent)
        cornerItems = [EarCorner.topRight, .topLeft, .bottomRight, .bottomLeft].map {
            ($0, NSMenuItem(title: StatusMenuController.title(of: $0), action: nil, keyEquivalent: ""))
        }
        delayItems = ExpandDelay.choicesMs.map { ms in
            let suffix = ms == DropboardConfig.defaultExpandDelayMs ? " (Standard)" : ""
            return (ms, NSMenuItem(title: "\(ms) ms\(suffix)", action: nil, keyEquivalent: ""))
        }
        loginItem = NSMenuItem(title: "Beim Anmelden starten", action: nil, keyEquivalent: "")
        exportParent = NSMenuItem(title: "Board exportieren", action: nil, keyEquivalent: "")
        exportFormatItems = ExportFormat.allCases.map {
            ($0, NSMenuItem(title: StatusMenuController.title(of: $0), action: nil, keyEquivalent: ""))
        }
        exportDPIItems = ExportMath.dpiChoices.map { dpi in
            let suffix = dpi == ExportMath.defaultDPI ? " (Standard)" : ""
            return (dpi, NSMenuItem(title: "\(dpi) dpi\(suffix)", action: nil, keyEquivalent: ""))
        }
        exportAreaItems = ExportArea.allCases.map {
            ($0, NSMenuItem(title: StatusMenuController.title(of: $0), action: nil, keyEquivalent: ""))
        }
        exportDesktopItem = NSMenuItem(title: "Schreibtisch", action: nil, keyEquivalent: "")
        exportCustomItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        exportChooseItem = NSMenuItem(title: "Anderer Ordner…", action: nil, keyEquivalent: "")
        super.init()
        buildMenu()
        statusItem.button?.image = StatusMenuController.makeIcon()
        statusItem.button?.toolTip = "Dropboard"
        statusItem.menu = menu
        refresh()
    }

    // MARK: Aufbau

    private func buildMenu() {
        menu.autoenablesItems = false   // Aktiv/inaktiv setzen wir selbst (Login-Eintrag außerhalb der .app)
        menu.delegate = self

        menu.addItem(item("Board öffnen", #selector(openBoard(_:))))

        hideItem.action = #selector(toggleHidden(_:))
        hideItem.target = self
        // Nur Anzeige des globalen Hotkeys (der eigentliche Hotkey läuft über Carbon, GlobalHotKey).
        hideItem.keyEquivalentModifierMask = HideHotKey.menuModifiers
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let cornerMenu = NSMenu(title: "Ecke")
        cornerMenu.autoenablesItems = false
        for (corner, entry) in cornerItems {
            entry.action = #selector(chooseCorner(_:))
            entry.target = self
            entry.representedObject = corner.rawValue
            cornerMenu.addItem(entry)
        }
        let cornerParent = NSMenuItem(title: "Ecke", action: nil, keyEquivalent: "")
        cornerParent.submenu = cornerMenu
        menu.addItem(cornerParent)

        let delayMenu = NSMenu(title: "Verzögerung bis Aufklappen")
        delayMenu.autoenablesItems = false
        for (ms, entry) in delayItems {
            entry.action = #selector(chooseDelay(_:))
            entry.target = self
            entry.tag = ms
            delayMenu.addItem(entry)
        }
        let delayParent = NSMenuItem(title: "Verzögerung bis Aufklappen", action: nil, keyEquivalent: "")
        delayParent.submenu = delayMenu
        menu.addItem(delayParent)

        loginItem.action = #selector(toggleLaunchAtLogin(_:))
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        buildExportMenu()
        menu.addItem(item("Board-Ordner im Finder zeigen", #selector(revealBoardFolder(_:))))

        menu.addItem(.separator())
        // „Über Dropboard“ als Untermenü statt Über-Fenster: ein Fenster müsste die App aktivieren (Fokusraub).
        let aboutMenu = NSMenu(title: "Über Dropboard")
        aboutMenu.autoenablesItems = false
        let versionItem = NSMenuItem(title: "Dropboard \(StatusMenuController.versionText)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        aboutMenu.addItem(versionItem)
        aboutMenu.addItem(item("Protokoll im Finder zeigen", #selector(revealLog(_:))))
        let aboutParent = NSMenuItem(title: "Über Dropboard", action: nil, keyEquivalent: "")
        aboutParent.submenu = aboutMenu
        menu.addItem(aboutParent)

        let quitItem = item("Dropboard beenden", #selector(quit(_:)), key: "q")
        quitItem.keyEquivalentModifierMask = [.command]   // Anzeige ⌘Q; greift, solange das Menü offen ist
        menu.addItem(quitItem)
    }

    /// E12: Untermenü „Board exportieren“ – drei Formate (ein Klick exportiert sofort), DPI, Bereich, Exportordner.
    /// Häkchen = gewählter Wert (Systemmenü-Darstellung). Das zuletzt gewählte Format zeigt ⌘E (= Kürzel im Ansichtsmodus).
    private func buildExportMenu() {
        let exportMenu = NSMenu(title: "Board exportieren")
        exportMenu.autoenablesItems = false
        for (format, entry) in exportFormatItems {
            entry.action = #selector(exportAs(_:))
            entry.target = self
            entry.representedObject = format.rawValue
            exportMenu.addItem(entry)
        }
        exportMenu.addItem(.separator())
        exportMenu.addItem(header("Auflösung"))
        for (dpi, entry) in exportDPIItems {
            entry.action = #selector(chooseExportDPI(_:))
            entry.target = self
            entry.tag = dpi
            entry.indentationLevel = 1
            exportMenu.addItem(entry)
        }
        exportMenu.addItem(.separator())
        exportMenu.addItem(header("Bereich"))
        for (area, entry) in exportAreaItems {
            entry.action = #selector(chooseExportArea(_:))
            entry.target = self
            entry.representedObject = area.rawValue
            entry.indentationLevel = 1
            exportMenu.addItem(entry)
        }
        exportMenu.addItem(.separator())
        exportMenu.addItem(header("Exportordner"))
        exportDesktopItem.action = #selector(chooseExportDesktop(_:))
        exportDesktopItem.target = self
        exportDesktopItem.indentationLevel = 1
        exportMenu.addItem(exportDesktopItem)
        // Eigener Ordner (nur sichtbar, wenn gewählt): Anzeige mit Häkchen, Klick ändert nichts.
        exportCustomItem.indentationLevel = 1
        exportCustomItem.isHidden = true
        exportMenu.addItem(exportCustomItem)
        exportChooseItem.action = #selector(chooseExportFolder(_:))
        exportChooseItem.target = self
        exportChooseItem.indentationLevel = 1
        exportMenu.addItem(exportChooseItem)

        exportParent.submenu = exportMenu
        menu.addItem(exportParent)
    }

    /// Nicht anklickbare Zwischenüberschrift.
    private func header(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.isEnabled = true
        return entry
    }

    /// Häkchen und Zustände aus Settings/Presenter/SMAppService neu setzen (vor jedem Öffnen und nach jeder Änderung).
    func refresh() {
        hideItem.state = (host?.isEarHidden ?? false) ? .on : .off
        let corner = settings.corner
        for (c, entry) in cornerItems { entry.state = c == corner ? .on : .off }
        let delay = settings.expandDelayMs
        for (ms, entry) in delayItems { entry.state = ms == delay ? .on : .off }

        refreshExport()

        if LoginItem.isAppBundle {
            let status = LoginItem.status
            loginItem.isEnabled = true
            switch status {
            case .enabled:
                loginItem.title = "Beim Anmelden starten"
                loginItem.state = .on
            case .requiresApproval:
                loginItem.title = "Beim Anmelden starten (in Systemeinstellungen bestätigen)"
                loginItem.state = .mixed
            default:
                loginItem.title = "Beim Anmelden starten"
                loginItem.state = .off
            }
        } else {
            loginItem.title = "Beim Anmelden starten (nur in Dropboard.app)"
            loginItem.state = .off
            loginItem.isEnabled = false
        }
    }

    private func refreshExport() {
        let canExport = host?.canExportBoard ?? false
        let running = host?.isExportRunning ?? false
        exportParent.title = running ? "Board exportieren (läuft …)" : "Board exportieren"
        let last = settings.exportFormat
        for (format, entry) in exportFormatItems {
            entry.isEnabled = canExport
            entry.toolTip = canExport ? nil : (running ? "Es läuft schon ein Export" : "Das Board ist leer")
            // Anzeige ⌘E am zuletzt gewählten Format (greift auch bei offenem Menü).
            entry.keyEquivalent = format == last ? "e" : ""
            entry.keyEquivalentModifierMask = format == last ? [.command] : []
        }
        let dpi = settings.exportDPI
        for (d, entry) in exportDPIItems { entry.state = d == dpi ? .on : .off }
        let area = settings.exportArea
        for (a, entry) in exportAreaItems { entry.state = a == area ? .on : .off }
        let custom = settings.exportFolder
        exportDesktopItem.state = custom == nil ? .on : .off
        if let url = custom {
            exportCustomItem.isHidden = false
            exportCustomItem.title = url.lastPathComponent
            exportCustomItem.toolTip = url.path
            exportCustomItem.state = .on
        } else {
            exportCustomItem.isHidden = true
            exportCustomItem.state = .off
        }
    }

    /// Nur Diagnose fürs Log.
    var diagnosticsText: String {
        "button=\(statusItem.button != nil) image=\(statusItem.button?.image != nil) template=\(statusItem.button?.image?.isTemplate ?? false)"
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    // MARK: Aktionen

    @objc private func openBoard(_ sender: NSMenuItem) {
        Log.line("[SETTINGS]", "Menü: Board öffnen")
        host?.openBoardFromMenu()
    }

    @objc private func toggleHidden(_ sender: NSMenuItem) {
        host?.toggleEarHidden(source: "Menü")
        refresh()
    }

    @objc private func chooseCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let corner = EarCorner(rawValue: raw) else { return }
        host?.applyCorner(corner)
        refresh()
    }

    @objc private func chooseDelay(_ sender: NSMenuItem) {
        host?.applyExpandDelay(ms: sender.tag)
        refresh()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard LoginItem.isAppBundle else {
            Log.line("[SETTINGS]", "Beim Anmelden starten: nur in Dropboard.app (läuft aus \(Bundle.main.bundleURL.path))")
            return
        }
        let before = LoginItem.status
        if before == .requiresApproval {
            Log.line("[SETTINGS]", "Beim Anmelden starten: status=requiresApproval → Systemeinstellungen (Anmeldeobjekte) geöffnet")
            LoginItem.openSystemSettings()
            return
        }
        let want = before != .enabled
        let result = LoginItem.set(want)
        settings.launchAtLogin = result.status == .enabled   // Spiegel = tatsächlicher Status, nicht der Wunsch
        if let error = result.error {
            Log.line("[SETTINGS]", "Beim Anmelden starten → \(want) FEHLER \(error) status=\(LoginItem.describe(result.status)) "
                + "(Häkchen folgt dem tatsächlichen Status)")
        } else {
            Log.line("[SETTINGS]", "Beim Anmelden starten → \(want) ok status=\(LoginItem.describe(before))→\(LoginItem.describe(result.status)) "
                + "app=\(Bundle.main.bundleURL.path)")
        }
        if want && result.status == .requiresApproval {
            Log.line("[SETTINGS]", "Beim Anmelden starten: Bestätigung nötig → Systemeinstellungen (Anmeldeobjekte) geöffnet")
            LoginItem.openSystemSettings()
        }
        refresh()
    }

    // MARK: Export (E12)

    @objc private func exportAs(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = ExportFormat(rawValue: raw) else { return }
        Log.line("[EXPORT]", "Menü: Board exportieren → \(sender.title)")
        host?.exportBoard(format: format)
        refresh()
    }

    @objc private func chooseExportDPI(_ sender: NSMenuItem) {
        let old = settings.exportDPI
        settings.exportDPI = sender.tag
        Log.line("[EXPORT]", "DPI \(old) → \(settings.exportDPI) (gespeichert)")
        refresh()
    }

    @objc private func chooseExportArea(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let area = ExportArea(rawValue: raw) else { return }
        let old = settings.exportArea
        settings.exportArea = area
        Log.line("[EXPORT]", "Bereich \(old.rawValue) → \(area.rawValue) (gespeichert)")
        refresh()
    }

    @objc private func chooseExportDesktop(_ sender: NSMenuItem) {
        host?.useDesktopExportFolder()
        refresh()
    }

    @objc private func chooseExportFolder(_ sender: NSMenuItem) {
        Log.line("[EXPORT]", "Menü: Exportordner → Anderer Ordner…")
        host?.chooseExportFolder()
    }

    @objc private func revealBoardFolder(_ sender: NSMenuItem) {
        host?.revealBoardFolder()
    }

    @objc private func revealLog(_ sender: NSMenuItem) {
        host?.revealLogFile()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        host?.quitFromMenu()
    }

    // MARK: Symbol

    /// Eselsohr-/Papiereck-Symbol, programmatisch gezeichnet: Blatt mit umgeknickter Ecke oben rechts.
    /// Template-Bild (18 × 18 pt): die Menüleiste färbt es selbst (hell/dunkel), keine eigenen Farben.
    static func makeIcon() -> NSImage {
        // ⚠️ VERIFIZIEREN: NSImage(size:flipped:drawingHandler:) – der Handler fängt nichts ein (evtl. @Sendable im SDK)
        // und wird bei jeder Auflösung neu aufgerufen (scharf auf Retina).
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let left: CGFloat = 3.5, right: CGFloat = 14.5, bottom: CGFloat = 1.5, top: CGFloat = 16.5, fold: CGFloat = 5

            // Blattumriss mit abgeschnittener Ecke oben rechts
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: left, y: bottom))
            outline.line(to: NSPoint(x: left, y: top))
            outline.line(to: NSPoint(x: right - fold, y: top))
            outline.line(to: NSPoint(x: right, y: top - fold))
            outline.line(to: NSPoint(x: right, y: bottom))
            outline.close()
            outline.lineWidth = 1.5
            outline.lineJoinStyle = .round
            NSColor.black.setStroke()
            outline.stroke()

            // umgeknickte Lasche (gefüllt)
            let flap = NSBezierPath()
            flap.move(to: NSPoint(x: right - fold, y: top))
            flap.line(to: NSPoint(x: right - fold, y: top - fold))
            flap.line(to: NSPoint(x: right, y: top - fold))
            flap.close()
            flap.lineWidth = 1.5
            flap.lineJoinStyle = .round
            NSColor.black.setFill()
            flap.fill()
            flap.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
