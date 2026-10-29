// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FreeASR",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "DoubaoASR", targets: ["DoubaoASR"]),
        .library(name: "WeTypeASR", targets: ["WeTypeASR"]),
        .executable(name: "doubao-asr-cli", targets: ["doubao-asr-cli"]),
        .executable(name: "wetype-asr-cli", targets: ["wetype-asr-cli"])
    ],
    targets: [
        .target(
            name: "DoubaoASR",
            path: "Sources/DoubaoASR"
        ),
        .target(
            name: "WeTypeASR",
            path: "Sources/WeTypeASR"
        ),
        .executableTarget(
            name: "doubao-asr-cli",
            dependencies: ["DoubaoASR"],
            path: "Sources/doubao-asr-cli"
        ),
        .executableTarget(
            name: "wetype-asr-cli",
            dependencies: ["WeTypeASR"],
            path: "Sources/wetype-asr-cli"
        )
    ]
)
