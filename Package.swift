// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenRouterBrowser",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenRouterBrowser",
            path: "Sources/OpenRouterBrowser"
        )
    ]
)
