// swift-tools-version: 6.0
//
// Single build definition for the portable Stacks code.
//
// Module map:
//   StacksKit        — portable domain + persistence (journal, catalog, library,
//                      import, metadata, calibre, mobi, enrichment, images).
//   StacksSync       — sync wire models + the RemoteLibrary client.
//   StacksServerKit  — Hummingbird server, OPDS, basic auth, Bonjour/Avahi.
//   stacks           — the headless CLI.
//
// The macOS-only device layer (`StacksCore/Devices` + `StacksCore/Vendored`)
// is NOT here: it is a XcodeGen framework target consumed only by the macOS
// app, because it is built on IOUSBHost/IOKit and never runs on Linux or iOS.
import PackageDescription

let package = Package(
    name: "Stacks",
    // iOS is declared so availability checks resolve against a realistic
    // minimum (the iOS client links StacksKit/StacksSync); the app targets
    // themselves deploy to iOS 26.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "StacksKit", targets: ["StacksKit"]),
        .library(name: "StacksSync", targets: ["StacksSync"]),
        .library(name: "StacksServerKit", targets: ["StacksServerKit"]),
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
        // (Images/CoverDecoder.swift) inflates/deflates PNG IDAT streams
        // through it. libmobi already links zlib, so no extra system
        // dependency on either platform.
        .systemLibrary(
            name: "Clibz",
            path: "StacksCore/Clibz",
            pkgConfig: "zlib",
            providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]
        ),
        .target(
            name: "StacksKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "libmobi", package: "libmobi-swift"),
                // SHA-256 content hashing uses CryptoKit on Apple platforms and
                // swift-crypto's `Crypto` module elsewhere.
                .product(name: "Crypto", package: "swift-crypto"),
                .target(name: "Clibz"),
            ],
            path: "StacksCore",
            // Clibz is the system-library target above; Devices/Vendored are the
            // macOS-only device layer; Server/Sync are their own targets.
            exclude: ["Clibz", "Devices", "Vendored", "Server", "Sync"]
        ),
        .target(
            name: "StacksSync",
            dependencies: ["StacksKit"],
            path: "StacksCore/Sync"
        ),
        .target(
            name: "StacksServerKit",
            dependencies: [
                "StacksKit",
                "StacksSync",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "StacksCore/Server"
        ),
        .executableTarget(
            name: "StacksServer",
            dependencies: [
                "StacksKit",
                "StacksServerKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "StacksServer"
        ),
        .testTarget(
            name: "StacksCoreTests",
            dependencies: [
                "StacksKit",
                "StacksSync",
                "StacksServerKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "libmobi", package: "libmobi-swift"),
            ],
            path: "StacksCoreTests",
            // Tests for the macOS-only device layer and Apple-only surfaces
            // stay in the Xcode target only.
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
