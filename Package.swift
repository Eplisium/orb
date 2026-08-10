// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ORB",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ORB",
            path: "Sources/ORB"
        ),
        .testTarget(
            name: "ORBTests",
            dependencies: ["ORB"],
            path: "Tests/ORBTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
