// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "deskman",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DeskmanCore",
            linkerSettings: [
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
            ]
        ),
        .executableTarget(name: "deskman", dependencies: ["DeskmanCore"]),
        .testTarget(name: "DeskmanCoreTests", dependencies: ["DeskmanCore"]),
    ]
)
