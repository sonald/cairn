// swift-tools-version: 6.0

import PackageDescription
import Foundation

let libgit2Mode = ProcessInfo.processInfo.environment["CAIRN_LIBGIT2"] ?? "brew"
if libgit2Mode != "brew" && libgit2Mode != "vendored" {
    fatalError("CAIRN_LIBGIT2 must be 'brew' or 'vendored'")
}

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let vendoredLibGit2 = packageRoot.appendingPathComponent("Vendor/libgit2")
let vendoredLibGit2Headers = packageRoot.appendingPathComponent("Sources/CLibGit2Vendored/include")
if libgit2Mode == "vendored" {
    if !FileManager.default.fileExists(
        atPath: vendoredLibGit2.appendingPathComponent("lib/libgit2.a").path
    ) {
        fatalError("Run scripts/vendor-libgit2.sh before using CAIRN_LIBGIT2=vendored")
    }
    if !FileManager.default.fileExists(
        atPath: vendoredLibGit2Headers.appendingPathComponent("git2.h").path
    ) {
        fatalError(
            "Vendored libgit2 headers are not staged into Sources/CLibGit2Vendored/include; "
                + "re-run scripts/vendor-libgit2.sh (scripts/make-app.sh also refreshes them)"
        )
    }
}

// Vendored mode builds CLibGit2 as a regular C target whose public headers are
// part of the package graph, so every build engine resolves them without
// target-local -I flags (swiftbuild's explicit module builds do not propagate
// unsafeFlags to transitive dependents). Brew mode keeps the pkg-config
// systemLibrary.
let clibGit2Target: Target = if libgit2Mode == "vendored" {
    .target(
        name: "CLibGit2",
        path: "Sources/CLibGit2Vendored",
        publicHeadersPath: "include",
        linkerSettings: [
            .unsafeFlags(["-L" + vendoredLibGit2.appendingPathComponent("lib").path]),
            .linkedLibrary("git2"),
            .linkedFramework("CoreFoundation"),
            .linkedFramework("Security"),
            .linkedLibrary("iconv"),
            .linkedLibrary("z"),
        ]
    )
} else {
    .systemLibrary(
        name: "CLibGit2",
        pkgConfig: "libgit2",
        providers: [.brew(["libgit2"])]
    )
}

let libgit2SwiftSettings: [SwiftSetting] = libgit2Mode == "brew"
    ? [.unsafeFlags(["-Xcc", "-I/opt/homebrew/opt/libgit2/include"])]
    : []
let libgit2LinkerSettings: [LinkerSetting] = libgit2Mode == "brew"
    ? [.unsafeFlags(["-L/opt/homebrew/opt/libgit2/lib"])]
    : []

let package = Package(
    name: "CodeInsight",
    defaultLocalization: "en",
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
        clibGit2Target,
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
            name: "CTreeSitterPython",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterPython",
            exclude: ["src/node-types.json"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CTreeSitterTypeScript",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterTypeScript",
            exclude: [
                "typescript/src/node-types.json",
                "tsx/src/node-types.json",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("typescript/src"),
                .headerSearchPath("tsx/src"),
            ]
        ),
        .target(
            name: "CProcessGuard",
            path: "Sources/CProcessGuard",
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
            swiftSettings: libgit2SwiftSettings,
            linkerSettings: libgit2LinkerSettings
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
            name: "CodeInsightPythonExtractor",
            dependencies: [
                "CodeInsightCore",
                "TreeSitterKit",
                "CTreeSitterPython",
            ]
        ),
        .target(
            name: "CodeInsightTypeScriptExtractor",
            dependencies: [
                "CodeInsightCore",
                "TreeSitterKit",
                "CTreeSitterTypeScript",
            ]
        ),
        .target(
            name: "CodeInsightExact",
            dependencies: [
                "CProcessGuard",
                "CodeInsightCore",
                "CodeInsightGit",
            ]
        ),
        .target(
            name: "CodeInsightEngine",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightGit",
                "CodeInsightPythonExtractor",
                "CodeInsightRustExtractor",
                "CodeInsightTypeScriptExtractor",
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
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
                "CodeInsightExact",
                "CodeInsightGit",
                "CodeInsightReaderCore",
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "CodeInsightReaderCore",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightPythonExtractor",
                "CodeInsightRustExtractor",
                "CodeInsightTypeScriptExtractor",
                "TreeSitterKit",
                "CTreeSitterRust",
                "CTreeSitterPython",
                "CTreeSitterTypeScript",
            ]
        ),
        .target(
            name: "CodeInsightReaderUI",
            dependencies: ["CodeInsightCore", "CodeInsightReaderCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CodeInsightApp",
            dependencies: [
                "CodeInsightAppModel",
                "CodeInsightCore",
                "CodeInsightEngine",
                "CodeInsightExact",
                "CodeInsightGit",
                "CodeInsightReaderCore",
                "CodeInsightReaderUI",
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TreeSitterKitTests",
            dependencies: [
                "TreeSitterKit",
                "CTreeSitterRust",
                "CTreeSitterPython",
                "CTreeSitterTypeScript",
            ]
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
                "CProcessGuard",
                "CProcessGuardTestSupport",
                "CodeInsightCore",
                "CodeInsightExact",
                "CodeInsightGit",
            ],
            exclude: ["Fixtures"]
        ),
        .target(
            name: "CProcessGuardTestSupport",
            dependencies: ["CProcessGuard"],
            path: "Tests/CProcessGuardTestSupport",
            publicHeadersPath: "include"
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
            name: "PythonExtractorTests",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightPythonExtractor",
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "TypeScriptExtractorTests",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightTypeScriptExtractor",
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "CodeInsightEngineTests",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightEngine",
                "CodeInsightGit",
                "CodeInsightPythonExtractor",
                "CodeInsightTypeScriptExtractor",
            ]
        ),
        .testTarget(
            name: "CodeInsightAppModelTests",
            dependencies: [
                "CodeInsightAppModel",
                "CodeInsightEngine",
                "CodeInsightExact",
                "CodeInsightGit",
                "CodeInsightReaderCore",
            ]
        ),
        .testTarget(
            name: "CodeInsightReaderCoreTests",
            dependencies: [
                "CodeInsightReaderCore",
                "CodeInsightReaderUI",
                "CodeInsightTypeScriptExtractor",
            ]
        ),
        .testTarget(
            name: "CodeInsightReaderUITests",
            dependencies: [
                "CodeInsightCore",
                "CodeInsightReaderCore",
                "CodeInsightReaderUI",
            ]
        ),
        .testTarget(
            name: "CodeInsightAppTests",
            dependencies: ["CodeInsightApp"]
        ),
    ]
)
