// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MLXPilot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MLX Pilot", targets: ["MLXPilot"])
    ],
    targets: [
        .executableTarget(
            name: "MLXPilot",
            path: "Sources/MLXPilot"
        )
    ]
)
