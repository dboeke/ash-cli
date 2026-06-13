// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ash",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "ash",
            path: "Sources/ash"
        )
    ]
)
