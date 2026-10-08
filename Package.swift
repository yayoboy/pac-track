// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PacTrack",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PacEngine"),
        .target(name: "PacKit", dependencies: ["PacEngine"]),
        .executableTarget(name: "PacTrack", dependencies: ["PacKit", "PacEngine"]),
        .testTarget(name: "PacEngineTests", dependencies: ["PacEngine"]),
        .testTarget(name: "PacKitTests", dependencies: ["PacKit", "PacEngine"]),
    ]
)
