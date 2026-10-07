// swift-tools-version: 5.9
import PackageDescription

// Spike "Eselsohr-Panel mit Drop-Test" (Phase 1). Messinstrument, kein Produkt.
// Eigenständiges Package, keine externen Dependencies, Swift-5-Sprachmodus (E9).
let package = Package(
    name: "eselsohr-drop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "eselsohr-drop", path: "Sources/eselsohr-drop")
    ]
)
