// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GoProConnector",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GoProConnector",
            path: "Sources/GoProConnector",
            linkerSettings: [
                // SwiftUI's VideoPlayer (_AVKit_SwiftUI) subclasses AVPlayerView at runtime, but the
                // linker drops the AVKit auto-link because no AVKit symbol is referenced directly:
                // without this the app aborts as soon as a video is opened.
                .linkedFramework("AVKit")
            ]
        )
    ]
)
