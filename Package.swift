// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DS3ActivatorCLI",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "DS3ActivatorCLI",
            path: "Sources/DS3ActivatorCLI"
        )
    ]
)