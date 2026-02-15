// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoDoo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhoDoo",
            path: "Sources"
        )
    ]
)
