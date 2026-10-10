// swift-tools-version: 6.0
// tx — Transcript indeX
// MVP1 — macOS 26.1+, Apple Silicon only

import PackageDescription

let package = Package(
    name: "tx",
    platforms: [
        .macOS("26.1")
    ],
    products: [
        .library(name: "TxCore", targets: ["TxCore"]),
        .executable(name: "tx", targets: ["TxApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.11.0"),
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage.git", from: "14.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "TxCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/TxCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "TxApp",
            dependencies: [
                "TxCore",
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
                .product(name: "DSWaveformImageViews", package: "DSWaveformImage"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/TxApp",
            exclude: ["App"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "TxCoreTests",
            dependencies: ["TxCore"],
            path: "Tests/TxCoreTests"
        ),
    ]
)
