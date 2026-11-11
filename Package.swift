// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NordvaNotch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "NordvaNotchCore"),
        .executableTarget(name: "NordvaNotch", dependencies: ["NordvaNotchCore"]),
        .executableTarget(name: "notch-hook", dependencies: ["NordvaNotchCore"]),
        .testTarget(name: "NordvaNotchCoreTests", dependencies: ["NordvaNotchCore"]),
    ]
)
