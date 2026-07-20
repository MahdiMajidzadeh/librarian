import Foundation
import LibrarianFixtures

// Generates a demo ebook library for manual testing:
//   swift run librarian-seed <directory>

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("Usage: librarian-seed <directory>")
    print("Creates a demo ebook library (epub/pdf/mobi fixtures) in <directory>.")
    exit(1)
}

let root = URL(fileURLWithPath: arguments[1])
do {
    try FixtureFactory.seedDemoLibrary(into: root)
    print("Seeded demo library at \(root.path)")
    print("Point Librarian at this folder and scan.")
} catch {
    print("Seeding failed: \(error)")
    exit(1)
}
