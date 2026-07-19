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

// `--doctor-rebuild <library.sqlite>` runs the real Rebuild Auto-Groups
// pipeline against a database copy, printing progress and the result —
// for diagnosing behavior on a user's actual library.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--doctor-rebuild"),
   CommandLine.arguments.count > flagIndex + 1 {
    let dbURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let database = try AppDatabase.open(at: dbURL)
    // Covers go to the app's real cache so a repaired database keeps working.
    let cache = try CoverCache(directory: dbURL.deletingLastPathComponent()
        .appendingPathComponent("Covers"))
    let pipeline = ScanPipeline(database: database, coverCache: cache)

    let before = try await database.writer.read { db in
        (books: try Book.fetchCount(db),
         manual: try Book.filter(sql: "manualGroup = 1").fetchCount(db))
    }
    print("before: \(before.books) books, \(before.manual) manual")

    let start = Date()
    let summary = try await pipeline.rebuildGroups { done, total in
        if done % 100 == 0 || done == total {
            print("  parsing \(done)/\(total)  (\(Int(Date().timeIntervalSince(start)))s)")
        }
    }
    print("summary: kept \(summary.groupsKept), rebuilt \(summary.booksRebuilt), dissolved \(summary.booksDissolved)")

    let after = try await database.writer.read { db -> (Int, Int, [String]) in
        let books = try Book.fetchCount(db)
        let biggest = try Row.fetchAll(db, sql: """
            SELECT b.title, count(f.id) AS n FROM book b
            JOIN bookFile f ON f.bookId = b.id
            GROUP BY b.id ORDER BY n DESC LIMIT 5
            """).map { "\($0["n"] as Int? ?? 0)× \($0["title"] as String? ?? "?")" }
        let multi = try Row.fetchAll(db, sql:
            "SELECT bookId FROM bookFile GROUP BY bookId HAVING count(*) > 5").count
        return (books, multi, biggest)
    }
    print("after: \(after.0) books, groups>5files: \(after.1)")
    print("largest groups now: \(after.2.joined(separator: " | "))")
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
await groupingRegressionTests(runner)
await epubParserTests(runner)
await pdfParserTests(runner)
await mobiParserTests(runner)
await metadataTests(runner)
await lookupTests(runner)
await renameTests(runner)
await exportTests(runner)
await folderWatcherTests(runner)
await endToEndTests(runner)

runner.finish()
