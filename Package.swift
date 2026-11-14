// swift-tools-version: 5.9
import PackageDescription

/// Swift 6 data-race diagnostics at the `targeted` level, reported as warnings
/// while the package stays in the Swift 5 language mode. None are errors. The
/// current unique-warning counts (clean build, Swift 6.4) are the ceiling in
/// `scripts/warnings-baseline.txt`, which CI enforces. Move toward `complete`
/// and then the Swift 6 language mode by fixing these, not by silencing them.
let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency=targeted")
]

let package = Package(
    name: "ORB",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ORB",
            path: "Sources/ORB",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ORBTests",
            dependencies: ["ORB"],
            path: "Tests/ORBTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: strictConcurrency
        )
    ]
)
