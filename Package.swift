// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NetworkToggle",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "NetworkToggleKit"),
        .executableTarget(name: "NetworkToggle", dependencies: ["NetworkToggleKit"]),
        .executableTarget(name: "NetworkToggleHelper", dependencies: ["NetworkToggleKit"]),
    ]
)
