// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TextKitProbe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TextKitProbe", targets: ["TextKitProbe"]),
    ],
    dependencies: [
        .package(name: "CodeInsight", path: "../.."),
    ],
    targets: [
        .target(
            name: "TextKitProbeCore",
            dependencies: [
                .product(name: "TreeSitterKit", package: "CodeInsight"),
                // The root package does not publish CTreeSitterRust as a product;
                // this product links that grammar without changing the root package.
                .product(name: "CodeInsightRustExtractor", package: "CodeInsight"),
            ]
        ),
        .executableTarget(
            name: "TextKitProbe",
            dependencies: ["TextKitProbeCore"]
        ),
        .testTarget(
            name: "TextKitProbeCoreTests",
            dependencies: ["TextKitProbeCore"]
        ),
    ]
)
