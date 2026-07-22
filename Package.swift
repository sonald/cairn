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
        .library(name: "CodeInsightGit", targets: ["CodeInsightGit"]),
        .library(name: "CodeInsightExact", targets: ["CodeInsightExact"]),
        .library(
            name: "CodeInsightRustExtractor",
            targets: ["CodeInsightRustExtractor"]
        ),
        .library(name: "CodeInsightEngine", targets: ["CodeInsightEngine"]),
        .executable(name: "codeinsight", targets: ["CodeInsightCLI"]),
        .executable(name: "codeinsight-app", targets: ["CodeInsightApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CLibGit2",
            pkgConfig: "libgit2",
            providers: [.brew(["libgit2"])]
        ),
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
            name: "CodeInsightGit",
            dependencies: ["CLibGit2", "CodeInsightCore"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/opt/libgit2/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/opt/libgit2/lib"]),
            ]
        ),
        .target(
            name: "CodeInsightRustExtractor",
            dependencies: [
                "CodeInsightCore",
                "TreeSitterKit",
                "CTreeSitterRust",
            ]
        ),
        .target(
            name: "CodeInsightExact",
            dependencies: ["CodeInsightCore", "CodeInsightGit"]
        ),
        .target(
            name: "CodeInsightEngine",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightGit",
                "CodeInsightRustExtractor",
            ]
        ),
        .executableTarget(
            name: "CodeInsightCLI",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightEngine",
                "CodeInsightExact",
                "CodeInsightGit",
                "TreeSitterKit",
                "CTreeSitterRust",
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser"
                ),
            ]
        ),
        .target(
            name: "CodeInsightAppModel",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightEngine",
                "CodeInsightGit",
                "CodeInsightReaderCore",
            ]
        ),
        .target(
            name: "CodeInsightReaderCore",
            dependencies: [
                "CodeInsightCore",
                "TreeSitterKit",
                "CTreeSitterRust",
            ]
        ),
        .target(
            name: "CodeInsightReaderUI",
            dependencies: ["CodeInsightReaderCore"]
        ),
        .executableTarget(
            name: "CodeInsightApp",
            dependencies: [
                "CodeInsightAppModel",
                "CodeInsightGit",
                "CodeInsightReaderCore",
                "CodeInsightReaderUI",
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
            name: "CodeInsightGitTests",
            dependencies: ["CodeInsightGit"]
        ),
        .testTarget(
            name: "CodeInsightExactTests",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightExact",
                "CodeInsightGit",
            ],
            exclude: ["Fixtures"]
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
            dependencies: [
                "CodeInsightCore",
                "CodeInsightEngine",
                "CodeInsightGit",
            ]
        ),
        .testTarget(
            name: "CodeInsightAppModelTests",
            dependencies: [
                "CodeInsightAppModel",
                "CodeInsightEngine",
                "CodeInsightGit",
                "CodeInsightReaderCore",
            ]
        ),
        .testTarget(
            name: "CodeInsightReaderCoreTests",
            dependencies: ["CodeInsightReaderCore", "CodeInsightReaderUI"]
        ),
    ]
)
