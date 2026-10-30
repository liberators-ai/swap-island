// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwapIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IslandCore"),
        .executableTarget(name: "SwapIsland", dependencies: ["IslandCore"]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
    ]
)
