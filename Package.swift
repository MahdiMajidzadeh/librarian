// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Librarian",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Librarian", targets: ["Librarian"]),
        .library(name: "LibrarianKit", targets: ["LibrarianKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", "0.9.16"..<"0.10.0"),
    ],
    targets: [
        .target(
            name: "LibrarianKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Librarian",
            dependencies: ["LibrarianKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Programmatic epub/pdf/mobi builders, shared by the test suite and
        // the librarian-seed demo-library generator.
        .target(
            name: "LibrarianFixtures",
            dependencies: [
                "LibrarianKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "librarian-seed",
            dependencies: ["LibrarianKit", "LibrarianFixtures"],
            path: "Sources/LibrarianSeed",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LibrarianKitTests",
            dependencies: ["LibrarianKit", "LibrarianFixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
