// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PacTrack",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PacEngine"),
        .testTarget(name: "PacEngineTests", dependencies: ["PacEngine"]),
    ]
)
