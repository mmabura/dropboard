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

    static func title(of corner: EarCorner) -> String {
        switch corner {
        case .topRight: return "Oben rechts"
        case .topLeft: return "Oben links"
        case .bottomRight: return "Unten rechts"
        case .bottomLeft: return "Unten links"
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
