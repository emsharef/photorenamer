// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoRenamer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhotoRenamer",
            path: "Sources"
        )
    ]
)
