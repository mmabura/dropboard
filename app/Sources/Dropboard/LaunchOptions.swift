import Foundation

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
struct LaunchOptions {
    var handoff: HandoffMode = DropboardConfig.defaultHandoff
    var boardDirectory: URL?
    var forceReduceMotion = false
    var selftest = false
    var snapshotPath: String?
    var snapshotDemo = false
    var snapshotDimmed = false
    var diagPasteboard = false

    static let diagPasteboardFlag = "--diag-pasteboard"
    /// Direkt aus den Prozess-Argumenten (ImageImporter liest das ohne Umweg über AppController).
    static let diagPasteboardRequested: Bool = CommandLine.arguments.contains(diagPasteboardFlag)

    struct ParseError: Error {
        let message: String
    }

    static let usage = "Dropboard [--handoff two-panels|grow] [--board-dir <pfad>] [--reduce-motion] [--diag-pasteboard] "
        + "| --selftest | --snapshot <pfad.png> [--snapshot-demo] [--snapshot-dimmed] [--board-dir <pfad>]"

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
        if (o.snapshotDemo || o.snapshotDimmed) && o.snapshotPath == nil {
            throw ParseError(message: "--snapshot-demo/--snapshot-dimmed nur zusammen mit --snapshot <pfad.png>")
        }
        return o
    }
}
