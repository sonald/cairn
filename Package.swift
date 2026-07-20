// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodeInsight",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "TreeSitterKit", targets: ["TreeSitterKit"]),
        .library(name: "CodeInsightCore", targets: ["CodeInsightCore"]),
        .library(
            name: "CodeInsightRustExtractor",
            targets: ["CodeInsightRustExtractor"]
        ),
        .library(name: "CodeInsightEngine", targets: ["CodeInsightEngine"]),
        .executable(name: "codeinsight", targets: ["CodeInsightCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
    ],
    targets: [
        .target(
            name: "CTreeSitter",
            path: "Sources/CTreeSitter",
            sources: ["src/lib.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
            ]
        ),
        .target(
            name: "CTreeSitterRust",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterRust",
            exclude: ["src/node-types.json"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "TreeSitterKit",
            dependencies: ["CTreeSitter"]
        ),
        .target(name: "CodeInsightCore"),
        .target(
            name: "CodeInsightRustExtractor",
            dependencies: [
                "CodeInsightCore",
                "TreeSitterKit",
                "CTreeSitterRust",
            ]
        ),
        .target(
            name: "CodeInsightEngine",
            dependencies: ["CodeInsightCore", "CodeInsightRustExtractor"]
        ),
        .executableTarget(
            name: "CodeInsightCLI",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightEngine",
                "TreeSitterKit",
                "CTreeSitterRust",
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser"
                ),
            ]
        ),
        .testTarget(
            name: "TreeSitterKitTests",
            dependencies: ["TreeSitterKit", "CTreeSitterRust"]
        ),
        .testTarget(
            name: "CodeInsightCoreTests",
            dependencies: ["CodeInsightCore"]
        ),
        .testTarget(
            name: "RustExtractorTests",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightEngine",
                "CodeInsightRustExtractor",
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "CodeInsightEngineTests",
            dependencies: ["CodeInsightCore", "CodeInsightEngine"]
        ),
    ]
)
