// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Yap",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Native Parakeet ASR on the Apple Neural Engine (the "ears").
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.4")),
    ],
    targets: [
        .executableTarget(
            name: "Yap",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Yap",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
