import AppKit

// Dropboard – Prototyp (Briefing-Schritte 1–6). App ohne Bundle/Info.plist, NSApplication manuell (wie die Spikes).
// Aufruf: siehe LaunchOptions.usage und README.md.

func parseLaunchOptions(_ args: [String]) -> LaunchOptions {
    do {
        return try LaunchOptions.parse(args)
    } catch let error as LaunchOptions.ParseError {
        print("\(error.message)\nAufruf: \(LaunchOptions.usage)")
        exit(2)
    } catch {
        print("\(error)\nAufruf: \(LaunchOptions.usage)")
        exit(2)
    }
}

let launchOptions = parseLaunchOptions(CommandLine.arguments)

// `--selftest`: kein Fenster, Exit 0 (alles PASS) oder 1 (wie Spike stopmotion).
if launchOptions.selftest {
    exit(SelfTest.run() ? 0 : 1)
}

// Ctrl-C sauber loggen und beenden (wie Spike eselsohr-drop).
signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    Log.line("[WIN]", "Ctrl-C – Dropboard beendet")
    // über applicationWillTerminate: eingereihte Speichervorgänge und Log abschließen (Handler läuft auf .main)
    MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
}
sigintSource.resume()

// ⚠️ VERIFIZIEREN (aus Spike, dort kompiliert): MainActor.assumeIsolated im Top-Level-Code von main.swift.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    if launchOptions.snapshotPath != nil {
        // Offscreen, ohne Fenster und ohne Run-Loop.
        exit(Snapshot.run(launchOptions) ? 0 : 1)
    }
    if launchOptions.exportPath != nil {
        // E12: Export ohne Fenster und ohne Run-Loop (synchron), wie Snapshot.
        exit(ExportCLI.run(launchOptions) ? 0 : 1)
    }
    let policyOK = app.setActivationPolicy(.accessory)
    let controller = AppController(options: launchOptions)
    app.delegate = controller
    Log.line("[WIN]", "setActivationPolicy(.accessory) → \(policyOK)")
    withExtendedLifetime(controller) {
        app.run()
    }
}
