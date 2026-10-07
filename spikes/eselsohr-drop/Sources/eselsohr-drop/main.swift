import AppKit

// Spike „Eselsohr-Panel mit Drop-Test“ (Phase 1). App ohne Bundle/Info.plist, NSApplication manuell.
// Aufruf: eselsohr-drop [--handoff two-panels|grow] [--reject-drops]

func parseHandoffMode(_ args: [String]) -> HandoffMode? {
    guard let i = args.firstIndex(of: "--handoff") else { return .twoPanels }
    guard i + 1 < args.count else { return nil }
    return HandoffMode(rawValue: args[i + 1])
}

let arguments = CommandLine.arguments
guard let handoffMode = parseHandoffMode(arguments) else {
    Log.line("[WIN]", "Ungültiger Wert für --handoff (erlaubt: two-panels, grow). Argumente: \(arguments)")
    exit(2)
}
let rejectDrops = arguments.contains("--reject-drops")

// Ctrl-C sauber loggen und beenden.
signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    Log.line("[WIN]", "Ctrl-C – Spike beendet")
    exit(0)
}
sigintSource.resume()

// ⚠️ VERIFIZIEREN: MainActor.assumeIsolated auf dem Haupt-Thread im Top-Level-Code (Swift-5-Modus) läuft ohne Laufzeitfehler.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let policyOK = app.setActivationPolicy(.accessory)
    let controller = AppController(mode: handoffMode, rejectDrops: rejectDrops)
    app.delegate = controller
    Log.line("[WIN]", "setActivationPolicy(.accessory) → \(policyOK)")
    withExtendedLifetime(controller) {
        app.run()
    }
}
