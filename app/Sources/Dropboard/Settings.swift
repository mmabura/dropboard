import Foundation
import DropboardCore

/// Einstellungen (Briefing-Schritt 8) zentral an einer Stelle, persistent in UserDefaults.
/// Suite = Standard (`UserDefaults.standard`), alle Keys mit Präfix `dropboard.`. Die Konstanten in
/// `DropboardConfig` (`defaultCorner`, `defaultExpandDelayMs`) sind nur noch die Standardwerte.
///
/// Domäne: In `Dropboard.app` ist das die Bundle-ID `app.dropboard.Dropboard`
/// (`~/Library/Preferences/app.dropboard.Dropboard.plist`). Bei `swift run` (ohne Bundle) eine eigene Domäne nach
/// dem Prozessnamen – Einstellungen aus `swift run` und aus der .app sind also getrennt.
/// ⚠️ VERIFIZIEREN: Domäne von `UserDefaults.standard` für das unbundled SwiftPM-Executable.
///
/// Bewusst NICHT gespeichert: „Eselsohr ausblenden“ (nach jedem Neustart wieder sichtbar, sonst vergisst man es).
/// Nicht an einen Actor gebunden, damit `--selftest` es mit einer eigenen Suite prüfen kann.
final class Settings {
    enum Key {
        static let prefix = "dropboard."
        static let corner = "dropboard.corner"
        static let expandDelayMs = "dropboard.expandDelayMs"
        /// Nur Spiegel: maßgeblich ist `SMAppService.mainApp.status` (LoginItem).
        static let launchAtLogin = "dropboard.launchAtLogin"
        static let all = [corner, expandDelayMs, launchAtLogin]
        // Export (E12). Bewusst nicht in `all` (das sind die Schritt-8-Einstellungen, Selftest zählt sie).
        static let exportFormat = "dropboard.exportFormat"
        static let exportDPI = "dropboard.exportDPI"
        static let exportArea = "dropboard.exportArea"
        static let exportFolderPath = "dropboard.exportFolderPath"
        static let exportFolderBookmark = "dropboard.exportFolderBookmark"
        static let export = [exportFormat, exportDPI, exportArea, exportFolderPath, exportFolderBookmark]
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Ecke des Eselsohrs. Unbekannter/fehlender Wert → `DropboardConfig.defaultCorner`.
    var corner: EarCorner {
        get { defaults.string(forKey: Key.corner).flatMap { EarCorner(rawValue: $0) } ?? DropboardConfig.defaultCorner }
        set { defaults.set(newValue.rawValue, forKey: Key.corner) }
    }

    /// Verzögerung bis zum Aufklappen in ms. Nur `ExpandDelay.choicesMs`; sonst `DropboardConfig.defaultExpandDelayMs`.
    var expandDelayMs: Int {
        get {
            let stored = defaults.object(forKey: Key.expandDelayMs) as? Int
            guard let ms = stored, ExpandDelay.choicesMs.contains(ms) else { return DropboardConfig.defaultExpandDelayMs }
            return ms
        }
        set {
            let ms = ExpandDelay.choicesMs.contains(newValue) ? newValue : DropboardConfig.defaultExpandDelayMs
            defaults.set(ms, forKey: Key.expandDelayMs)
        }
    }

    /// Für Timer (`perform(_:with:afterDelay:)`).
    var expandDelay: TimeInterval { Double(expandDelayMs) / 1000 }

    /// Spiegel des Login-Item-Status (nur fürs Log/Diagnose; die Wahrheit ist `SMAppService.mainApp.status`).
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    // MARK: Export (E12)

    /// Zuletzt gewähltes Exportformat (⌘E im Ansichtsmodus). Unbekannt/fehlend → PNG.
    var exportFormat: ExportFormat {
        get { defaults.string(forKey: Key.exportFormat).flatMap { ExportFormat(rawValue: $0) } ?? ExportMath.defaultFormat }
        set { defaults.set(newValue.rawValue, forKey: Key.exportFormat) }
    }

    /// Export-DPI, nur `ExportMath.dpiChoices` (72/150/300/600); sonst 300.
    var exportDPI: Int {
        get {
            guard let dpi = defaults.object(forKey: Key.exportDPI) as? Int, ExportMath.isValidDPI(dpi) else {
                return ExportMath.defaultDPI
            }
            return dpi
        }
        set { defaults.set(ExportMath.isValidDPI(newValue) ? newValue : ExportMath.defaultDPI, forKey: Key.exportDPI) }
    }

    /// Exportbereich; Standard „nur Inhalt“.
    var exportArea: ExportArea {
        get { defaults.string(forKey: Key.exportArea).flatMap { ExportArea(rawValue: $0) } ?? ExportMath.defaultArea }
        set { defaults.set(newValue.rawValue, forKey: Key.exportArea) }
    }

    /// Eigener Exportordner (nil = Schreibtisch). Gespeichert als Pfad plus Bookmark (folgt Umbenennen/Verschieben).
    /// Ohne App Sandbox (E4) reicht ein normales Bookmark, kein security-scoped.
    // ⚠️ VERIFIZIEREN: URL.bookmarkData()/URL(resolvingBookmarkData:…) ohne Sandbox für einen Ordner.
    var exportFolder: URL? {
        get {
            if let data = defaults.data(forKey: Key.exportFolderBookmark) {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil,
                                      bookmarkDataIsStale: &stale) {
                    return url
                }
            }
            guard let path = defaults.string(forKey: Key.exportFolderPath), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            guard let url = newValue else {
                defaults.removeObject(forKey: Key.exportFolderPath)
                defaults.removeObject(forKey: Key.exportFolderBookmark)
                return
            }
            defaults.set(url.path, forKey: Key.exportFolderPath)
            if let data = try? url.bookmarkData() {
                defaults.set(data, forKey: Key.exportFolderBookmark)
            } else {
                defaults.removeObject(forKey: Key.exportFolderBookmark)
            }
        }
    }

    /// Schreibtisch des Nutzers (Standard-Exportordner, E12).
    static var desktopDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Eine Zeile fürs Log.
    var summary: String {
        "ecke=\(corner.rawValue) verzögerung=\(expandDelayMs)ms anmeldung(spiegel)=\(launchAtLogin)"
    }

    /// Export-Einstellungen fürs Log.
    var exportSummary: String {
        "format=\(exportFormat.rawValue) dpi=\(exportDPI) bereich=\(exportArea.rawValue) "
            + "ordner=\(exportFolder?.path ?? "Schreibtisch")"
    }
}
