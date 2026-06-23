// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Parley",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Parley",
            path: "Sources/Parley",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
