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

    /// Eine Zeile fürs Log.
    var summary: String {
        "ecke=\(corner.rawValue) verzögerung=\(expandDelayMs)ms anmeldung(spiegel)=\(launchAtLogin)"
    }
}
