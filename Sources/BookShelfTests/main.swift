import Foundation
import GRDB
import ZIPFoundation
import BookShelfKit

// `swift run bookshelf-tests --seed <dir>` writes a small demo library of
// generated fixture books for manual end-to-end testing, then exits.
if let seedIndex = CommandLine.arguments.firstIndex(of: "--seed"),
   CommandLine.arguments.count > seedIndex + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[seedIndex + 1])
    try Fixtures.seedDemoLibrary(at: dir)
    print("Seeded demo library at \(dir.path)")
    exit(0)
}

let runner = TestRunner.shared

// MARK: - Scaffold smoke tests

await runner.run("dependencies link and SQLite works") {
    let queue = try DatabaseQueue()
    let one = try await queue.read { db in
        try Int.fetchOne(db, sql: "SELECT 1")
    }
    expectEqual(one, 1)
    expectEqual(BookShelfKit.version, "0.1.0")
}

await databaseTests(runner)
await scannerTests(runner)
await groupingTests(runner)
await epubParserTests(runner)
await pdfParserTests(runner)
await mobiParserTests(runner)
await lookupTests(runner)
await renameTests(runner)
await exportTests(runner)
await endToEndTests(runner)

runner.finish()
