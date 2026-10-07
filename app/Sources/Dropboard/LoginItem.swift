import Foundation
import ServiceManagement

/// „Beim Anmelden starten“ über `SMAppService.mainApp` (ServiceManagement, ab macOS 13; Deployment-Target ist 14).
/// Maßgeblich ist immer `SMAppService.mainApp.status`; `Settings.launchAtLogin` ist nur ein Spiegel.
///
/// Nur sinnvoll aus einer .app: Läuft das Binary nicht aus einem .app-Bundle (`swift run`), wird der Menüeintrag
/// deaktiviert („nur in Dropboard.app“).
///
/// ⚠️ VERIFIZIEREN: Verhalten mit der nur ad-hoc signierten App (codesign -s -). Erwartet: register() klappt, der
/// Eintrag erscheint unter Systemeinstellungen → Allgemein → Anmeldeobjekte (evtl. mit Hinweis auf nicht
/// identifizierten Entwickler, evtl. Status .requiresApproval). Möglich ist auch ein Fehler (Signatur/Team-ID) –
/// dann steht er im Log `[SETTINGS] Beim Anmelden starten … FEHLER`, und das Häkchen bleibt aus.
/// ⚠️ VERIFIZIEREN: Die Registrierung gilt dem Bundle an seinem aktuellen Ort. Nach einem Neubau/Verschieben
/// (dist/ → /Applications, neue ad-hoc-Signatur = neuer cdhash) kann der Eintrag ins Leere zeigen → Status prüfen,
/// ggf. aus- und wieder einschalten. Am besten nur aus /Applications/Dropboard.app einschalten.
enum LoginItem {
    /// Läuft das Binary aus einem .app-Bundle?
    static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool { status == .enabled }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unbekannt(\(status.rawValue))"
        }
    }

    /// Ein-/Ausschalten. Rückgabe: Status danach und ggf. Fehlertext. Wirft nie.
    static func set(_ enabled: Bool) -> (status: SMAppService.Status, error: String?) {
        // ⚠️ VERIFIZIEREN: register()/unregister() sind synchron und werfen (Swift-Import von -registerAndReturnError:).
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return (status, nil)
        } catch {
            let ns = error as NSError
            return (status, "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)")
        }
    }

    /// Status .requiresApproval: Nutzer muss in den Systemeinstellungen bestätigen.
    static func openSystemSettings() {
        // ⚠️ VERIFIZIEREN: SMAppService.openSystemSettingsLoginItems() (macOS 13+) öffnet Allgemein → Anmeldeobjekte.
        SMAppService.openSystemSettingsLoginItems()
    }
}
