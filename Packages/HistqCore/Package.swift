// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HistqCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HistqCore", targets: ["HistqCore"]),
    ],
    targets: [
        .target(name: "HistqCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "HistqCoreTests", dependencies: ["HistqCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
