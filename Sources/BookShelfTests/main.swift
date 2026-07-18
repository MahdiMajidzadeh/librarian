import Foundation
import GRDB
import ZIPFoundation
import BookShelfKit

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

runner.finish()
