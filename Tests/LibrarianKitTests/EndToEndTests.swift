import XCTest
import GRDB
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: E2E-01 … E2E-03 (test-case.md).
final class EndToEndTests: XCTestCase {
    // E2E-01
    func testSeedScanRenameExportRoundTrip() throws {
        let (scanner, database, coverCache) = try makeScanner()
        let root = try makeTempDir()
        try FixtureFactory.seedDemoLibrary(into: root)

        // --- Scan ---
        let summary = try scanner.scan(root: root)
        XCTAssertEqual(summary.totalFiles, 15)
        var library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 11, "titles: \(library.map(\.book.title))")

        func entry(_ title: String) -> (book: Book, files: [BookFile])? {
            library.first { $0.book.title == title }
        }

        // Dune trio grouped into one book with three formats (§6.2).
        let dune = try XCTUnwrap(entry("Dune"), "titles: \(library.map(\.book.title))")
        XCTAssertEqual(Set(dune.files.map(\.format)), [.epub, .pdf, .mobi])
        XCTAssertNotNil(dune.book.coverCachePath)

        // Same-format duplicates land in one book (duplicate-format filter).
        let nineteen84 = try XCTUnwrap(entry("1984"))
        XCTAssertEqual(nineteen84.files.map(\.format), [.epub, .epub])

        // Same title, different authors stays separate (§9).
        let reworks = library.filter { $0.book.title == "Rework" }
        XCTAssertEqual(reworks.count, 2)

        // Persian book intact (NFR-4).
        XCTAssertNotNil(entry("بوف کور"))

        // Corrupt epub is present but marked (§9).
        let corrupt = try XCTUnwrap(entry("corrupt-book"))
        XCTAssertNotNil(corrupt.book.parseErrorNote)

        // --- No-change rescan: all unchanged, < 3 s (§6.1 acceptance) ---
        let rescan = try scanner.scan(root: root)
        XCTAssertEqual(rescan.unchanged, 15)
        XCTAssertEqual(rescan.added + rescan.updated, 0)
        XCTAssertLessThan(rescan.duration, 3.0)

        // --- Rename the Foundation series with a series-aware template ---
        let foundationIds = library
            .filter { $0.book.series == "Foundation" }
            .compactMap(\.book.id)
        XCTAssertEqual(foundationIds.count, 3)
        let selection = library.filter { foundationIds.contains($0.book.id ?? -1) }
        let rows = try RenamePlanner.plan(
            template: "{author} - {title}{series? ({series} #{series_index})}.{ext}",
            selection: selection)
        XCTAssertTrue(rows.allSatisfy { $0.status == .ready })

        let executor = RenameExecutor(database: database)
        let renameResult = try executor.execute(rows: rows)
        XCTAssertEqual(renameResult.renamed, 3)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "SciFi/Isaac Asimov - Foundation (Foundation #1).epub").path))

        // --- Undo restores every original name (FR-4.8) ---
        let undo = try executor.undoLastBatch()
        XCTAssertEqual(undo.reverted, 3)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("SciFi/Foundation.epub").path))

        // --- Exports ---
        library = try database.fetchLibrary()
        var provenance: [Int64: [String: Provenance]] = [:]
        for pair in library {
            if let id = pair.book.id {
                provenance[id] = try database.provenance(forBook: id)
            }
        }
        let jsonOut = try makeTempDir().appendingPathComponent("library.json")
        try Exporters.exportJSON(
            entries: library, provenance: provenance, to: jsonOut,
            options: .init(includeCovers: true), coverCache: coverCache)
        let payload = try JSONSerialization.jsonObject(
            with: Data(contentsOf: jsonOut)) as! [String: Any]
        XCTAssertEqual(payload["book_count"] as? Int, 11)
        let books = payload["books"] as! [[String: Any]]
        let totalFiles = books.reduce(0) { $0 + (($1["files"] as! [[String: Any]]).count) }
        XCTAssertEqual(totalFiles, 15, "every file on disk appears in the export (FR-5.2)")
        // Exported cover paths resolve relative to the JSON (§6.5 acceptance).
        for book in books {
            if let coverPath = book["cover_path"] as? String {
                let coverURL = jsonOut.deletingLastPathComponent()
                    .appendingPathComponent(coverPath)
                XCTAssertTrue(FileManager.default.fileExists(atPath: coverURL.path))
            }
        }

        let csvOut = jsonOut.deletingLastPathComponent().appendingPathComponent("library.csv")
        try Exporters.exportCSV(entries: library, to: csvOut)
        let csvText = String(data: try Data(contentsOf: csvOut), encoding: .utf8)!
        XCTAssertEqual(csvText.split(separator: "\r\n").count, 12) // header + 11 books
        XCTAssertTrue(csvText.contains("بوف کور"))
    }

    // E2E-02
    func testRescanAfterExternalRename() throws {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("dune.epub"),
            spec: .init(title: "Dune", authors: ["Frank Herbert"], isbn: "9780441172719"))
        _ = try scanner.scan(root: root)

        // The user renames the file in Finder.
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("dune.epub"),
            to: root.appendingPathComponent("dune (1).epub"))
        _ = try scanner.scan(root: root)

        let library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 1, "the renamed file joins the same logical book")
        let files = library[0].files.sorted { $0.path < $1.path }
        XCTAssertEqual(files.count, 2)
        let missing = files.first { $0.missingFlag }
        let present = files.first { !$0.missingFlag }
        XCTAssertTrue(missing!.path.hasSuffix("dune.epub"))
        XCTAssertTrue(present!.path.hasSuffix("dune (1).epub"))

        // Purging clears the stale entry.
        try database.purgeMissingFiles()
        XCTAssertEqual(try database.fetchLibrary()[0].files.count, 1)
    }

    // E2E-03
    func testMergeUngroupPersistAcrossRescan() throws {
        let (scanner, database, coverCache) = try makeScanner()
        let root = try makeTempDir()
        // Two books that would never group automatically.
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("Rework - Jason Fried.epub"),
            spec: .init(title: "Rework", authors: ["Jason Fried"]))
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("Rework - Unrelated Author.epub"),
            spec: .init(title: "Rework", authors: ["Unrelated Author"]))
        _ = try scanner.scan(root: root)
        XCTAssertEqual(try database.fetchLibrary().count, 2)

        // Merge, then rescan: still one book (FR-2.4).
        let commands = GroupCommands(database: database, coverCache: coverCache)
        let ids = try database.fetchLibrary().compactMap(\.book.id)
        let survivor = try commands.merge(bookIds: ids)
        _ = try scanner.scan(root: root)
        var library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library[0].book.id, survivor)

        // Ungroup, then rescan: split persists even though the files would
        // still merge by the old manual token if tokens were shared.
        _ = try commands.ungroup(bookId: survivor)
        _ = try scanner.scan(root: root)
        library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 2)
        XCTAssertTrue(library.allSatisfy { $0.files.count == 1 })
    }
}
