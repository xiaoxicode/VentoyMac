// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VentoyMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VentoyMac", targets: ["VentoyMac"]),
        .executable(name: "ventoymac-cli", targets: ["VentoymacCLI"])
    ],
    targets: [
        .target(
            name: "VentoyCore",
            path: "Sources/VentoyCore"
        ),
        .executableTarget(
            name: "VentoyMac",
            dependencies: ["VentoyCore"],
            path: "Sources/VentoyMac"
        ),
        .executableTarget(
            name: "VentoymacCLI",
            dependencies: ["VentoyCore"],
            path: "Sources/VentoymacCLI"
        ),
        .testTarget(
            name: "VentoyCoreTests",
            dependencies: ["VentoyCore"],
            path: "Tests/VentoyCoreTests"
        )
    ]
)
