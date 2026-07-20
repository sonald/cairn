// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ExactProbe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExactProbeCore", targets: ["ExactProbeCore"]),
        .executable(name: "exactprobe", targets: ["exactprobe"]),
    ],
    targets: [
        .target(name: "ExactProbeCore"),
        .executableTarget(name: "exactprobe", dependencies: ["ExactProbeCore"]),
        .testTarget(name: "ExactProbeCoreTests", dependencies: ["ExactProbeCore"]),
    ]
)
