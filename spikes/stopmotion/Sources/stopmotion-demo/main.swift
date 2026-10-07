import AppKit
import StopMotionCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var controller: DemoController?
    private let seed: UInt64

    init(seed: UInt64) {
        self.seed = seed
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = DemoController(seed: seed)
        self.controller = controller

        // ⚠️ VERIFIZIEREN: Standard-AppKit-Fensterbau (nicht in Report 03): feste Größe, kein Resize, damit die Kartenpositionen gültig bleiben.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: DemoController.boardSize),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Dropboard Spike: Stop-Motion"
        window.contentView = controller.view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.view)
        self.window = window

        // ⚠️ VERIFIZIEREN: NSApplication.activate() ohne Parameter (macOS 14+) bringt die App aus `swift run` nach vorn.
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Einstieg. `--selftest` öffnet kein Fenster und beendet sich mit Exit-Code 0 (alles PASS) oder 1.
let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

// Optional: `--seed <zahl>` für reproduzierbare Zufallswerte (Kartenwahl, Positionen, Jitter).
var launchSeed = UInt64(Date().timeIntervalSince1970 * 1000)
if let i = arguments.firstIndex(of: "--seed"), i + 1 < arguments.count, let value = UInt64(arguments[i + 1]) {
    launchSeed = value
}

// ⚠️ VERIFIZIEREN: MainActor.assumeIsolated (Swift 5.9 / macOS 14) im Top-Level-Code von main.swift.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(seed: launchSeed)
    app.delegate = delegate   // weak; `delegate` bleibt durch diesen Scope bis zum Ende von run() am Leben
    app.run()
}
