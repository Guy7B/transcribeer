// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "capture",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
    ],
    targets: [
        .target(
            name: "CaptureCore",
            path: "Sources/CaptureCore"
        ),
        .executableTarget(
            name: "capture",
            dependencies: ["CaptureCore"],
            path: "Sources/capture"
        ),
        .testTarget(
            name: "captureCoreTests",
            dependencies: ["CaptureCore"],
            path: "Tests/captureCoreTests"
        )
    ]
)
