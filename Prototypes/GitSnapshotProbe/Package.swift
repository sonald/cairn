// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GitSnapshotProbe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitSnapshotProbe", targets: ["GitSnapshotProbe"]),
        .executable(name: "gitprobe", targets: ["gitprobe"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .systemLibrary(
            name: "CLibGit2",
            pkgConfig: "libgit2",
            providers: [.brew(["libgit2"])]
        ),
        .target(
            name: "GitSnapshotProbe",
            dependencies: [
                "CLibGit2",
                .product(name: "CodeInsightCore", package: "CodeInsight"),
                .product(name: "CodeInsightRustExtractor", package: "CodeInsight"),
                .product(name: "CodeInsightEngine", package: "CodeInsight"),
            ]
        ),
        .executableTarget(
            name: "gitprobe",
            dependencies: ["GitSnapshotProbe"]
        ),
        .testTarget(
            name: "GitSnapshotProbeTests",
            dependencies: ["GitSnapshotProbe"]
        ),
    ]
)
