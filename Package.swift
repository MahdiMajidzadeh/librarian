// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BookShelf",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BookShelf", targets: ["BookShelf"]),
        .library(name: "BookShelfKit", targets: ["BookShelfKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", "6.29.0"..<"7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", "0.9.16"..<"0.10.0"),
    ],
    targets: [
        .target(
            name: "BookShelfKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "BookShelf",
            dependencies: ["BookShelfKit"]
        ),
        // Command Line Tools installs don't ship XCTest, so tests run as a
        // plain executable: `swift run bookshelf-tests`.
        .executableTarget(
            name: "bookshelf-tests",
            dependencies: ["BookShelfKit"],
            path: "Sources/BookShelfTests"
        ),
    ]
)
