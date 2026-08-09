// swift-tools-version: 6.0
//
// The Linux-port package: builds the server-facing subset of StacksCore with
// plain `swift build` (macOS + Linux arm64/x86_64). Apple-only components —
// MTP devices (Devices), ImageIO cover thumbnailing (CoverThumbnailer.swift),
// Vendored, and macOS sandbox bookmarking (Security) — are EXCLUDED from the
// core target. Calibre, Enrichment, Import, MobiImport, and the server
// compile on both platforms; the remaining Apple-only code (e.g. Bonjour)
// stays in via `canImport` guards, and BonjourTests is excluded from the test
// target. The macOS app keeps building the full core via XcodeGen; this
// package is the headless `stacks` surface.
import PackageDescription

let package = Package(
    name: "StacksCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StacksCore", targets: ["StacksCore"]),
        .executable(name: "stacks", targets: ["StacksServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/awxkee/libmobi-swift.git", exact: "1.0.2"),
    ],
    targets: [
        // Minimal module map exposing the system zlib: the Linux cover decoder
        // (CoverDecoder.swift) inflates/deflates PNG IDAT streams through it.
        // libmobi already links zlib, so no extra system dependency on either
        // platform (macOS: SDK libz; Linux: the zlib dev package the server
        // build already requires).
        .systemLibrary(
            name: "Clibz",
            path: "StacksCore/Clibz",
            pkgConfig: "zlib",
            providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]
        ),
        .target(
            name: "StacksCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "libmobi", package: "libmobi-swift"),
                .target(name: "Clibz"),
            ],
            path: "StacksCore",
            // Apple-only / client-only code the headless server never runs.
            exclude: [
                "Devices",
                "Vendored",
                "Library/CoverThumbnailer.swift",
                // macOS sandbox bookmarking (security-scoped URLs); the
                // headless server opens libraries by path argument.
                "Security",
                // The Clibz system library target's module map + shim header.
                "Clibz",
            ]
        ),
        .executableTarget(
            name: "StacksServer",
            dependencies: [
                "StacksCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "StacksServer"
        ),
        .testTarget(
            name: "StacksCoreTests",
            dependencies: [
                "StacksCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "libmobi", package: "libmobi-swift"),
            ],
            path: "StacksCoreTests",
            // Mirrors the core target's excludes: tests referencing excluded
            // client features (Devices) and macOS-only surfaces (BonjourTests
            // uses Network.framework).
            exclude: [
                "Devices",
                "Security",
                "Selection",
                "Library/LibraryRepositoryTests.swift",
                "Library/CoverThumbnailerTests.swift",
                "Library/BookFolderTests.swift",
                "Server/BonjourTests.swift",
            ],
            // The MOBI reader tests exercise libmobi against a real fixture
            // file. SwiftPM flattens a processed directory into the bundle
            // root, matching the flat copy layout XcodeGen produces and the
            // tests' `Bundle(for:)` lookups expect.
            resources: [
                .process("MobiImport/Fixtures"),
            ]
        ),
    ]
)
