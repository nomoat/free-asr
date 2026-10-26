// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DoubaoASR",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "DoubaoASR", targets: ["DoubaoASR"]),
        .executable(name: "doubao-asr-cli", targets: ["doubao-asr-cli"])
    ],
    targets: [
        .target(
            name: "DoubaoASR",
            path: "Sources/DoubaoASR"
        ),
        .executableTarget(
            name: "doubao-asr-cli",
            dependencies: ["DoubaoASR"],
            path: "Sources/doubao-asr-cli"
        )
    ]
)
