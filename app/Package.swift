// swift-tools-version: 5.9
import PackageDescription

// Dropboard – Prototyp (Phase 2, Briefing-Schritte 1–6).
// Swift-5-Sprachmodus (E9), macOS 14 (E3), keine Dependencies, kein XCTest
// (Tests laufen über `swift run Dropboard --selftest`).
let package = Package(
    name: "Dropboard",
    platforms: [.macOS(.v14)],
    targets: [
        // Reine Logik: nur Foundation + CoreGraphics-Typen (Modell, Store, Layout, Stop-Motion-Planer).
        .target(name: "DropboardCore", path: "Sources/DropboardCore"),
        // App: AppKit + QuartzCore.
        .executableTarget(
            name: "Dropboard",
            dependencies: ["DropboardCore"],
            path: "Sources/Dropboard",
            // Wie Spike board-paper (dort auf dem Mac mini bestätigt: noise.png liegt flach im Bundle).
            resources: [.process("Resources")]
        ),
    ]
)
