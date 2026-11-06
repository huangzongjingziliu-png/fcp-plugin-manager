// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FCPXPluginManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FCPXPluginManager",
            path: "FCPXPluginManager"
        ),
        .testTarget(
            name: "FCPXPluginManagerTests",
            dependencies: ["FCPXPluginManager"],
            path: "Tests/FCPXPluginManagerTests"
        )
    ]
)
