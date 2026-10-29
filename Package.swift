// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FrameTwin",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FrameTwin",
            path: "Sources/FrameTwin"
        )
    ],
    swiftLanguageModes: [.v5]
)
