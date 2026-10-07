// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "board-paper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "board-paper", targets: ["BoardPaper"])
    ],
    targets: [
        .executableTarget(
            name: "BoardPaper",
            path: "Sources/BoardPaper",
            // ⚠️ VERIFIZIEREN: .process legt noise.png flach ins Bundle (Bundle.module.url(forResource:"noise", withExtension:"png")).
            resources: [.process("Resources")]
        )
    ]
)
