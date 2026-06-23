// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Parley",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Native Parakeet ASR on the Apple Neural Engine (the "ears").
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.4")),
    ],
    targets: [
        .executableTarget(
            name: "Parley",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Parley",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
