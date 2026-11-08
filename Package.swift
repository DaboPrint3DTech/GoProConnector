// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GoProConnector",
    defaultLocalization: "it",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GoProConnector",
            path: "Sources/GoProConnector"
        )
    ]
)
