import Foundation
import DropboardCore

/// Startargumente:
///   --handoff two-panels|grow   Übergabe-Variante (Default: DropboardConfig.defaultHandoff)
///   --board-dir <pfad>          alternativer Board-Ordner (Tests)
///   --reduce-motion             „Bewegung reduzieren“ erzwingen (zusätzlich zur Systemeinstellung)
///   --diag-pasteboard           Diagnose: voller Pasteboard-Dump (liest Daten aller Typen!) und
///                               Lebensdauer-Checks der Quelldateien nach dem Drop (P1/C6/P9). Sonst nur Typnamen.
///   --selftest                  Logik-Assertions, kein Fenster, Exit 0/1
///   --snapshot <pfad.png>       Board + Eselsohr offscreen als PNG, dann beenden
///   --snapshot-demo             mit --snapshot: 5 Platzhalterbilder in einem temporären Board
///   --snapshot-dimmed           mit --snapshot: abgedunkeltes Papier (Look während des Drags)
///   --export <pfad>             Board ohne Fenster exportieren (E12), dann beenden. Ordner → automatischer Name darin
///   --format png|pdf|folder     mit --export: Format (sonst aus der Endung, sonst PNG)
///   --dpi <n>                   mit --export: DPI (Standard 300; 1…2400, Menü nur 72/150/300/600)
///   --area content|full         mit --export: nur Inhalt (Standard) oder ganze Fläche
///   --pdf-layers                mit --export und PDF: Layer direkt in den PDF-Kontext (Versuch, ⚠️ VERIFIZIEREN)
///   --snapshot-demo             auch mit --export: temporäres Demo-Board
struct LaunchOptions {
    var handoff: HandoffMode = DropboardConfig.defaultHandoff
    var boardDirectory: URL?
    var forceReduceMotion = false
    var selftest = false
    var snapshotPath: String?
    var snapshotDemo = false
    var snapshotDimmed = false
    var diagPasteboard = false
    var exportPath: String?
    var exportFormat: ExportFormat?
    var exportDPI: Int?
    var exportArea: ExportArea?
    var pdfLayers = false

    /// Erlaubte DPI im CLI (Selftest/Prüfung auch krumme Werte wie 144).
    static let cliDPIRange = 1...2400

    static let diagPasteboardFlag = "--diag-pasteboard"
    /// Direkt aus den Prozess-Argumenten (ImageImporter liest das ohne Umweg über AppController).
    static let diagPasteboardRequested: Bool = CommandLine.arguments.contains(diagPasteboardFlag)

    struct ParseError: Error {
        let message: String
    }

    static let usage = "Dropboard [--handoff two-panels|grow] [--board-dir <pfad>] [--reduce-motion] [--diag-pasteboard] "
        + "| --selftest | --snapshot <pfad.png> [--snapshot-demo] [--snapshot-dimmed] [--board-dir <pfad>] "
        + "| --export <pfad> [--format png|pdf|folder] [--dpi N] [--area content|full] [--pdf-layers] [--snapshot-demo] [--board-dir <pfad>]"

    static func parse(_ args: [String]) throws -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--":
                break   // `swift run Dropboard -- …` reicht das Trennzeichen evtl. durch (wie Spike)
            case "--selftest":
                o.selftest = true
            case "--snapshot-demo":
                o.snapshotDemo = true
            case "--snapshot-dimmed":
                o.snapshotDimmed = true
            case "--reduce-motion":
                o.forceReduceMotion = true
            case diagPasteboardFlag:
                o.diagPasteboard = true
            case "--pdf-layers":
                o.pdfLayers = true
            case "--export", "--format", "--dpi", "--area":
                guard i + 1 < args.count else { throw ParseError(message: "\(a) braucht einen Wert") }
                let value = args[i + 1]
                i += 1
                switch a {
                case "--export":
                    o.exportPath = (value as NSString).expandingTildeInPath
                case "--format":
                    guard let f = ExportFormat(rawValue: value.lowercased()) else {
                        throw ParseError(message: "Ungültiger Wert für --format: \(value) (erlaubt: png, pdf, folder)")
                    }
                    o.exportFormat = f
                case "--dpi":
                    guard let dpi = Int(value), cliDPIRange.contains(dpi) else {
                        throw ParseError(message: "Ungültiger Wert für --dpi: \(value) (erlaubt: \(cliDPIRange.lowerBound)…\(cliDPIRange.upperBound))")
                    }
                    o.exportDPI = dpi
                default:
                    guard let area = ExportArea(rawValue: value.lowercased()) else {
                        throw ParseError(message: "Ungültiger Wert für --area: \(value) (erlaubt: content, full)")
                    }
                    o.exportArea = area
                }
            case "--handoff", "--snapshot", "--board-dir":
                guard i + 1 < args.count else { throw ParseError(message: "\(a) braucht einen Wert") }
                let value = args[i + 1]
                i += 1
                if a == "--handoff" {
                    guard let mode = HandoffMode(rawValue: value) else {
                        throw ParseError(message: "Ungültiger Wert für --handoff: \(value) (erlaubt: two-panels, grow)")
                    }
                    o.handoff = mode
                } else if a == "--snapshot" {
                    o.snapshotPath = (value as NSString).expandingTildeInPath
                } else {
                    o.boardDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
                }
            default:
                // Einfache Bindestrich-Argumente (z. B. -NS…, -psn_…) setzt das System; ignorieren.
                if a.hasPrefix("--") { throw ParseError(message: "Unbekanntes Argument: \(a)") }
            }
            i += 1
        }
        if o.snapshotDimmed && o.snapshotPath == nil {
            throw ParseError(message: "--snapshot-dimmed nur zusammen mit --snapshot <pfad.png>")
        }
        if o.snapshotDemo && o.snapshotPath == nil && o.exportPath == nil {
            throw ParseError(message: "--snapshot-demo nur zusammen mit --snapshot <pfad.png> oder --export <pfad>")
        }
        if o.snapshotPath != nil && o.exportPath != nil {
            throw ParseError(message: "--snapshot und --export nicht zusammen")
        }
        if o.exportPath == nil && (o.exportFormat != nil || o.exportDPI != nil || o.exportArea != nil || o.pdfLayers) {
            throw ParseError(message: "--format/--dpi/--area/--pdf-layers nur zusammen mit --export <pfad>")
        }
        return o
    }
}
