import XCTest
import GRDB
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: REN-01 … REN-20 (test-case.md).
final class RenameTests: XCTestCase {
    private func makeBook(
        title: String = "Dune", authors: [String] = ["Frank Herbert"],
        year: Int? = 1965, series: String? = nil, seriesIndex: Double? = nil
    ) -> Book {
        var book = Book(title: title, authors: authors)
        book.year = year
        book.series = series
        book.seriesIndex = seriesIndex
        return book
    }

    // MARK: Template rendering

    // REN-01
    func testRenderBasicTemplate() throws {
        let result = try RenameTemplate.render(
            template: "{author} - {title}.{ext}", book: makeBook(), fileExtension: "EPUB")
        XCTAssertEqual(result.filename, "Frank Herbert - Dune.epub")
        XCTAssertTrue(result.missingRequiredTokens.isEmpty)
    }

    // REN-02
    func testConditionalSeriesSegment() throws {
        let template = "{title}{series? ({series} #{series_index})}.{ext}"
        let withSeries = try RenameTemplate.render(
            template: template,
            book: makeBook(series: "Dune Chronicles", seriesIndex: 1),
            fileExtension: "epub")
        XCTAssertEqual(withSeries.filename, "Dune (Dune Chronicles #1).epub")

        let withoutSeries = try RenameTemplate.render(
            template: template, book: makeBook(), fileExtension: "epub")
        XCTAssertEqual(withoutSeries.filename, "Dune.epub")
        XCTAssertTrue(withoutSeries.missingRequiredTokens.isEmpty,
                      "tokens inside a skipped conditional are not required")
    }

    // REN-03
    func testMissingRequiredTokenReported() throws {
        let result = try RenameTemplate.render(
            template: "{author} - {title}.{ext}",
            book: makeBook(authors: []),
            fileExtension: "epub")
        XCTAssertEqual(result.missingRequiredTokens, ["author"])
    }

    // REN-04
    func testSanitizeIllegalCharacters() throws {
        let result = try RenameTemplate.render(
            template: "{title}.{ext}",
            book: makeBook(title: "Dune: Part/Two\u{0007}"),
            fileExtension: "pdf")
        XCTAssertFalse(result.filename.contains("/"))
        XCTAssertFalse(result.filename.contains(":"))
        XCTAssertFalse(result.filename.contains("\u{0007}"))
        XCTAssertEqual(result.filename, "Dune- Part-Two.pdf")
    }

    // REN-05
    func testEmptyTokenCollapse() throws {
        let result = try RenameTemplate.render(
            template: "{author} - {title} ({year}).{ext}",
            book: makeBook(year: nil),
            fileExtension: "epub")
        // {year} is required-but-missing → row will be excluded; but the
        // rendered string must still collapse the empty "()".
        XCTAssertFalse(result.filename.contains("()"))
        XCTAssertFalse(result.filename.contains("- -"))
        XCTAssertFalse(result.filename.contains("  "))
    }

    // REN-06
    func testUnicodePreserved() throws {
        let result = try RenameTemplate.render(
            template: "{author} - {title}.{ext}",
            book: makeBook(title: "بوف کور", authors: ["صادق هدایت"]),
            fileExtension: "epub")
        XCTAssertEqual(result.filename, "صادق هدایت - بوف کور.epub")
    }

    // REN-07
    func test255ByteCap() throws {
        let longPersian = String(repeating: "کتابخانه", count: 60) // 8 chars × 2 bytes each
        let result = try RenameTemplate.render(
            template: "{title}.{ext}",
            book: makeBook(title: longPersian),
            fileExtension: "epub")
        XCTAssertLessThanOrEqual(result.filename.utf8.count, 255)
        XCTAssertTrue(result.filename.hasSuffix(".epub"))
        // Truncation never splits a UTF-8 character.
        XCTAssertNotNil(result.filename.data(using: .utf8))
        XCTAssertFalse(result.filename.contains("\u{FFFD}"))
    }

    // REN-08
    func testUnknownTokenValidationError() {
        XCTAssertNotNil(RenameTemplate.validate("{bogus} - {title}.{ext}"))
        XCTAssertNotNil(RenameTemplate.validate("{title.{ext}"))
        XCTAssertNil(RenameTemplate.validate("{author} - {title}.{ext}"))
        XCTAssertNil(RenameTemplate.validate("{series? ({series} #{series_index}) }{title}.{ext}"))
    }

    // MARK: Planning

    private func plannerFixture(
        books: [(Book, [String])] // book + on-disk relative filenames
    ) throws -> (root: URL, selection: [(book: Book, files: [BookFile])]) {
        let root = try makeTempDir()
        var selection: [(book: Book, files: [BookFile])] = []
        var nextId: Int64 = 1
        for (index, (var book, names)) in books.enumerated() {
            book.id = Int64(index + 1)
            var files: [BookFile] = []
            for name in names {
                let url = root.appendingPathComponent(name)
                try Data("content".utf8).write(to: url)
                var file = BookFile(
                    bookId: book.id!,
                    path: url.path,
                    format: BookFormat(rawValue: url.pathExtension.lowercased()) ?? .epub,
                    sizeBytes: 7,
                    modifiedAt: Date())
                file.id = nextId
                nextId += 1
                files.append(file)
            }
            selection.append((book, files))
        }
        return (root, selection)
    }

    // REN-09
    func testPlanNoOpDetection() throws {
        let (_, selection) = try plannerFixture(
            books: [(makeBook(), ["Frank Herbert - Dune.epub"])])
        let rows = try RenamePlanner.plan(
            template: "{author} - {title}.{ext}", selection: selection)
        XCTAssertEqual(rows[0].status, .noOp)
        XCTAssertFalse(rows[0].included)
    }

    // REN-10
    func testPlanCollisionSuffix() throws {
        let (root, selection) = try plannerFixture(
            books: [(makeBook(), ["dune-old.epub"])])
        // The target name already exists on disk (not part of the batch).
        try Data("other".utf8).write(
            to: root.appendingPathComponent("Frank Herbert - Dune.epub"))
        let rows = try RenamePlanner.plan(
            template: "{author} - {title}.{ext}", selection: selection)
        XCTAssertEqual(rows[0].status, .collision)
        XCTAssertEqual(rows[0].proposedName, "Frank Herbert - Dune (2).epub")
    }

    // REN-11
    func testPlanBatchInternalCollision() throws {
        let (_, selection) = try plannerFixture(books: [
            (makeBook(), ["dune-a.epub"]),
            (makeBook(), ["dune-b.epub"]),
        ])
        let rows = try RenamePlanner.plan(
            template: "{author} - {title}.{ext}", selection: selection)
        let names = rows.map(\.proposedName).sorted()
        XCTAssertEqual(names, ["Frank Herbert - Dune (2).epub", "Frank Herbert - Dune.epub"])
        XCTAssertTrue(rows.contains { $0.status == .collision })
    }

    // REN-12
    func testPlanExcludesMissingToken() throws {
        let (_, selection) = try plannerFixture(
            books: [(makeBook(authors: []), ["mystery.epub"])])
        let rows = try RenamePlanner.plan(
            template: "{author} - {title}.{ext}", selection: selection)
        guard case .excluded(let reason) = rows[0].status else {
            return XCTFail("expected excluded row")
        }
        XCTAssertTrue(reason.contains("{author}"))
        XCTAssertFalse(rows[0].included)
    }

    // REN-13
    func testPlanExcludesMissingFile() throws {
        let (_, selectionBase) = try plannerFixture(
            books: [(makeBook(), ["dune.epub"])])
        var selection = selectionBase
        selection[0].files[0].missingFlag = true
        let rows = try RenamePlanner.plan(
            template: "{author} - {title}.{ext}", selection: selection)
        guard case .excluded = rows[0].status else {
            return XCTFail("expected excluded row for a missing file")
        }
    }

    // REN-14
    func testPlanCaseOnlyRename() throws {
        let (_, selection) = try plannerFixture(
            books: [(makeBook(), ["frank herbert - dune.epub"])])
        let rows = try RenamePlanner.plan(
            template: "{author} - {title}.{ext}", selection: selection)
        XCTAssertEqual(rows[0].status, .ready, "case-only rename is not a self-collision")
        XCTAssertEqual(rows[0].proposedName, "Frank Herbert - Dune.epub")
    }

    // REN-15
    func testSuffixRespects255Bytes() {
        let longStem = String(repeating: "x", count: 251) // 251 + ".pdf" = 255
        let name = "\(longStem).pdf"
        let suffixed = RenamePlanner.suffixed(name, avoiding: [name.lowercased()])
        XCTAssertLessThanOrEqual(suffixed.utf8.count, 255)
        XCTAssertTrue(suffixed.contains("(2)"), "the counter survives the byte cap")
        XCTAssertTrue(suffixed.hasSuffix(".pdf"))
    }

    // MARK: Execution & undo

    private func executorFixture() throws -> (
        root: URL, database: AppDatabase, executor: RenameExecutor, scanner: LibraryScanner
    ) {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        return (root, database, RenameExecutor(database: database), scanner)
    }

    private func plan(_ database: AppDatabase, template: String) throws -> [RenamePlanRow] {
        let selection = try database.fetchLibrary()
        return try RenamePlanner.plan(template: template, selection: selection)
    }

    // REN-16
    func testExecuteRenames() throws {
        let (root, database, executor, scanner) = try executorFixture()
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("dune-old-name.epub"),
            spec: .init(title: "Dune", authors: ["Frank Herbert"], date: "1965"))
        _ = try scanner.scan(root: root)

        let rows = try plan(database, template: "{author} - {title} ({year}).{ext}")
        let result = try executor.execute(rows: rows)

        XCTAssertEqual(result.renamed, 1)
        XCTAssertTrue(result.failed.isEmpty)
        let expected = root.appendingPathComponent("Frank Herbert - Dune (1965).epub")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("dune-old-name.epub").path))
        let dbPath = try database.writer.read { db in try BookFile.fetchOne(db)!.path }
        XCTAssertEqual(dbPath, expected.path, "database path updates with the file move (FR-4.7)")
        let journalCount = try database.writer.read { db in try RenameLog.fetchCount(db) }
        XCTAssertEqual(journalCount, 1)
    }

    // REN-17
    func testExecuteNeverOverwrites() throws {
        let (root, database, executor, scanner) = try executorFixture()
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("dune-old.epub"),
            spec: .init(title: "Dune", authors: ["Frank Herbert"]))
        _ = try scanner.scan(root: root)
        let rows = try plan(database, template: "{author} - {title}.{ext}")

        // A file appears at the target path after planning (stale plan).
        let obstacle = root.appendingPathComponent("Frank Herbert - Dune.epub")
        try Data("precious data".utf8).write(to: obstacle)

        let result = try executor.execute(rows: rows)
        XCTAssertEqual(result.renamed, 1)
        XCTAssertEqual(try Data(contentsOf: obstacle), Data("precious data".utf8),
                       "the obstacle file is never overwritten (FR-4.5)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Frank Herbert - Dune (2).epub").path))
    }

    // REN-18
    func testUndoLastBatch() throws {
        let (root, database, executor, scanner) = try executorFixture()
        for name in ["dune-x.epub", "dune-y.pdf"] {
            if name.hasSuffix("epub") {
                try FixtureFactory.makeEpub(
                    at: root.appendingPathComponent(name),
                    spec: .init(title: "Dune", authors: ["Frank Herbert"]))
            } else {
                try FixtureFactory.makePdf(
                    at: root.appendingPathComponent(name),
                    title: "Dune", author: "Frank Herbert")
            }
        }
        _ = try scanner.scan(root: root)
        let rows = try plan(database, template: "{author} - {title}.{ext}")
        _ = try executor.execute(rows: rows)
        XCTAssertNotNil(try executor.lastBatch())

        let undo = try executor.undoLastBatch()
        XCTAssertEqual(undo.reverted, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("dune-x.epub").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("dune-y.pdf").path))
        XCTAssertNil(try executor.lastBatch(), "a reverted batch is no longer undoable")
        let paths = try database.writer.read { db in try BookFile.fetchAll(db) }.map(\.path)
        XCTAssertTrue(paths.allSatisfy { $0.contains("dune-") })
    }

    // REN-19
    func testUndoSurvivesRestart() throws {
        let (root, database, executor, scanner) = try executorFixture()
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("dune-old.epub"),
            spec: .init(title: "Dune", authors: ["Frank Herbert"]))
        _ = try scanner.scan(root: root)
        _ = try executor.execute(rows: try plan(database, template: "{author} - {title}.{ext}"))

        // "Restart": a brand-new executor over the same database.
        let fresh = RenameExecutor(database: database)
        let undo = try fresh.undoLastBatch()
        XCTAssertEqual(undo.reverted, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("dune-old.epub").path))
    }

    // REN-20
    func testMultiFormatConsistentRename() throws {
        let (root, database, executor, scanner) = try executorFixture()
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("dune.epub"),
            spec: .init(title: "Dune", authors: ["Frank Herbert"], isbn: "9780441172719"))
        try FixtureFactory.makeMobi(
            at: root.appendingPathComponent("dune_v2.mobi"),
            spec: .init(headerTitle: "Dune", author: "Frank Herbert", isbn: "9780441172719"))
        try FixtureFactory.makePdf(
            at: root.appendingPathComponent("dune (1).pdf"),
            title: "Dune", author: "Frank Herbert")
        _ = try scanner.scan(root: root)
        XCTAssertEqual(try database.fetchLibrary().count, 1, "one logical book")

        let rows = try plan(database, template: "{author} - {title}.{ext}")
        let result = try executor.execute(rows: rows)
        XCTAssertEqual(result.renamed, 3, "all formats rename in one batch")
        for ext in ["epub", "mobi", "pdf"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Frank Herbert - Dune.\(ext)").path))
        }
    }
}
