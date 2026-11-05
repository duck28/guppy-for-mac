// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Guppy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Guppy",
            path: "Sources/Guppy"
        ),
        .testTarget(
            name: "GuppyTests",
            dependencies: ["Guppy"],
            path: "Tests/GuppyTests"
        ),
    ]
)
