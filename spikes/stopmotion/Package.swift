// swift-tools-version:5.9
import PackageDescription

// Spike "Stop-Motion-Ticker" (Phase 1). Eigenständiges Package, keine externen Dependencies.
// Bewusst KEIN XCTest-Target (auf dem Test-Mac sind nur die Command Line Tools installiert);
// Tests laufen über `swift run stopmotion-demo --selftest`.
let package = Package(
    name: "stopmotion",
    platforms: [.macOS(.v14)],
    targets: [
        // Reiner Planer: nur Foundation + CoreGraphics-Typen, kein AppKit/QuartzCore.
        .target(name: "StopMotionCore"),
        // Demo-App (AppKit + QuartzCore) und Selftest.
        .executableTarget(name: "stopmotion-demo", dependencies: ["StopMotionCore"]),
    ]
)
