import XCTest
import GRDB
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: SCAN-01 … SCAN-16 (test-case.md).
final class ScannerTests: XCTestCase {
    // SCAN-01
    func testInitialScanAddsFiles() throws {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(at: root.appendingPathComponent("a.epub"),
                                    spec: .init(title: "Alpha", authors: ["Ann"]))
        try FixtureFactory.makePdf(at: root.appendingPathComponent("b.pdf"), title: "Beta")
        try Data("x".utf8).write(to: root.appendingPathComponent("c.txt"))

        let summary = try scanner.scan(root: root)
        XCTAssertEqual(summary.added, 3)
        XCTAssertEqual(summary.totalFiles, 3)
        let files = try database.writer.read { db in try BookFile.fetchAll(db) }
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files.allSatisfy { !$0.missingFlag })
    }

    // SCAN-02
    func testScanSkipsHiddenFiles() throws {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(at: root.appendingPathComponent(".hidden.epub"),
                                    spec: .init(title: "Hidden"))
        try FixtureFactory.makeEpub(at: root.appendingPathComponent("visible.epub"),
                                    spec: .init(title: "Visible"))
        _ = try scanner.scan(root: root)
        let paths = try database.writer.read { db in try BookFile.fetchAll(db) }.map(\.path)
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(paths[0].hasSuffix("visible.epub"))
    }

    // SCAN-03
    func testScanSkipsIgnoredExtensions() throws {
        let (scanner, database, _) = try makeScanner()
        try database.setSetting(SettingKey.ignoreExtensions, to: "pdf, txt")
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(at: root.appendingPathComponent("keep.epub"),
                                    spec: .init(title: "Keep"))
        try FixtureFactory.makePdf(at: root.appendingPathComponent("skip.pdf"))
        try Data("x".utf8).write(to: root.appendingPathComponent("skip.txt"))
        let summary = try scanner.scan(root: root)
        XCTAssertEqual(summary.totalFiles, 1)
    }

    // SCAN-04
    func testScanSkipsUnknownExtensions() throws {
        let (scanner, _, _) = try makeScanner()
        let root = try makeTempDir()
        try Data("x".utf8).write(to: root.appendingPathComponent("archive.xyz"))
        try Data("x".utf8).write(to: root.appendingPathComponent("noext"))
        let summary = try scanner.scan(root: root)
        XCTAssertEqual(summary.totalFiles, 0)
    }

    // SCAN-05
    func testRescanUnchangedIsIncremental() throws {
        let (scanner, _, _) = try makeScanner()
        let root = try makeTempDir()
        for i in 0..<4 {
            try FixtureFactory.makeEpub(at: root.appendingPathComponent("book\(i).epub"),
                                        spec: .init(title: "Book \(i)", authors: ["A"]))
        }
        _ = try scanner.scan(root: root)
        let second = try scanner.scan(root: root)
        XCTAssertEqual(second.unchanged, 4)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.updated, 0)
    }

    // SCAN-06
    func testRescanPreservesResolvedMetadata() throws {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(at: root.appendingPathComponent("book.epub"),
                                    spec: .init(title: "Original", authors: ["A"]))
        _ = try scanner.scan(root: root)

        // Simulate a manual correction.
        try database.writer.write { db in
            try db.execute(sql: "UPDATE book SET title = 'Corrected'")
        }
        let bookId = try database.writer.read { db in try Book.fetchOne(db)!.id! }
        try database.recordProvenance(bookId: bookId, fields: ["title"], source: .manual)

        _ = try scanner.scan(root: root)
        let title = try database.writer.read { db in try Book.fetchOne(db)!.title }
        XCTAssertEqual(title, "Corrected")
        XCTAssertEqual(try database.provenance(forBook: bookId)["title"]?.source, .manual)
    }

    // SCAN-07
    func testDeletedFileMarkedMissing() throws {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        let path = root.appendingPathComponent("book.epub")
        try FixtureFactory.makeEpub(at: path, spec: .init(title: "Book", authors: ["A"]))
        _ = try scanner.scan(root: root)

        try FileManager.default.removeItem(at: path)
        let summary = try scanner.scan(root: root)
        XCTAssertEqual(summary.markedMissing, 1)
        let file = try database.writer.read { db in try BookFile.fetchOne(db)! }
        XCTAssertTrue(file.missingFlag)
        let bookCount = try database.writer.read { db in try Book.fetchCount(db) }
        XCTAssertEqual(bookCount, 1, "missing books are kept, not silently removed")
    }

    // SCAN-08
    func testReappearedFileClearsMissing() throws {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        let path = root.appendingPathComponent("book.epub")
        try FixtureFactory.makeEpub(at: path, spec: .init(title: "Book", authors: ["A"]))
        _ = try scanner.scan(root: root)
        try FileManager.default.removeItem(at: path)
        _ = try scanner.scan(root: root)
        try FixtureFactory.makeEpub(at: path, spec: .init(title: "Book", authors: ["A"]))
        _ = try scanner.scan(root: root)
        let file = try database.writer.read { db in try BookFile.fetchOne(db)! }
        XCTAssertFalse(file.missingFlag)
    }

    // SCAN-09
    func testChangedFileReparsed() throws {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        let path = root.appendingPathComponent("book.epub")
        try FixtureFactory.makeEpub(at: path, spec: .init(title: "First Title", authors: ["A"]))
        _ = try scanner.scan(root: root)

        try FixtureFactory.makeEpub(
            at: path,
            spec: .init(title: "A Completely Different And Much Longer Title", authors: ["A"]))
        let summary = try scanner.scan(root: root)
        XCTAssertEqual(summary.updated, 1)
        let file = try database.writer.read { db in try BookFile.fetchOne(db)! }
        XCTAssertEqual(
            file.embeddedTitleKey,
            Normalizer.key("A Completely Different And Much Longer Title"))
    }

    // SCAN-10
    func testScanProgressReported() throws {
        let (scanner, _, _) = try makeScanner()
        let root = try makeTempDir()
        for i in 0..<5 {
            try FixtureFactory.makeEpub(at: root.appendingPathComponent("b\(i).epub"),
                                        spec: .init(title: "B\(i)"))
        }
        let recorder = CallRecorder()
        _ = try scanner.scan(root: root) { progress in
            recorder.record("\(progress.processed)/\(progress.total)")
        }
        let events = recorder.events
        XCTAssertEqual(events.first, "0/5")
        XCTAssertEqual(events.last, "5/5")
        XCTAssertEqual(events.count, 6)
    }

    // SCAN-11
    func testRecursiveScan() throws {
        let (scanner, _, _) = try makeScanner()
        let root = try makeTempDir()
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FixtureFactory.makeEpub(at: nested.appendingPathComponent("deep.epub"),
                                    spec: .init(title: "Deep"))
        let summary = try scanner.scan(root: root)
        XCTAssertEqual(summary.totalFiles, 1)
    }

    // SCAN-12
    func testParseFailureNonFatal() throws {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        try Data("not really an epub".utf8)
            .write(to: root.appendingPathComponent("corrupt.epub"))
        let summary = try scanner.scan(root: root)
        XCTAssertEqual(summary.added, 1)
        let book = try database.writer.read { db in try Book.fetchOne(db)! }
        XCTAssertNotNil(book.parseErrorNote)
        XCTAssertEqual(book.metadataStatus, .unresolved)
        XCTAssertEqual(book.title, "corrupt") // filename fallback identity
    }

    // SCAN-13
    func testScanExtractsCover() throws {
        let (scanner, database, coverCache) = try makeScanner()
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("book.epub"),
            spec: .init(title: "Covered", authors: ["A"], coverData: FixtureFactory.tinyJPEG()))
        _ = try scanner.scan(root: root)
        let book = try database.writer.read { db in try Book.fetchOne(db)! }
        let coverPath = try XCTUnwrap(book.coverCachePath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: coverCache.gridURL(forPath: coverPath).path))
        XCTAssertNotNil(coverCache.originalURL(forBookId: book.id!))
    }

    // SCAN-14
    func testManualCoverSurvivesRescan() throws {
        let (scanner, database, coverCache) = try makeScanner()
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("book.epub"),
            spec: .init(title: "Book", authors: ["A"], coverData: FixtureFactory.tinyJPEG()))
        _ = try scanner.scan(root: root)
        let bookId = try database.writer.read { db in try Book.fetchOne(db)!.id! }

        // Replace the cover manually.
        let commands = GroupCommands(database: database, coverCache: coverCache)
        try commands.setCover(bookId: bookId, imageData: FixtureFactory.tinyJPEG(width: 90, height: 120))
        let manualPath = try database.writer.read { db in try Book.fetchOne(db)!.coverCachePath }

        _ = try scanner.scan(root: root)
        let afterRescan = try database.writer.read { db in try Book.fetchOne(db)!.coverCachePath }
        XCTAssertEqual(afterRescan, manualPath)
        XCTAssertEqual(try database.provenance(forBook: bookId)["cover"]?.source, .manual)
    }

    // SCAN-15
    func testMergeDuringScanIsNotClobbered() throws {
        let database = try makeDatabase()
        let coverCache = try makeCoverCache()
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(at: root.appendingPathComponent("alpha.epub"),
                                    spec: .init(title: "Alpha", authors: ["Ann"]))
        try FixtureFactory.makeEpub(at: root.appendingPathComponent("beta.epub"),
                                    spec: .init(title: "Beta", authors: ["Bob"]))
        _ = try LibraryScanner(database: database, coverCache: coverCache).scan(root: root)
        let ids = try database.fetchLibrary().compactMap(\.book.id)
        XCTAssertEqual(ids.count, 2)

        // A user merge commits while the next scan is between parsing and
        // reconciliation (e.g. a watcher-triggered scan is in flight).
        let commands = GroupCommands(database: database, coverCache: coverCache)
        let racyScanner = LibraryScanner(
            database: database, coverCache: coverCache,
            beforeReconcileHook: { try? commands.merge(bookIds: ids) })
        _ = try racyScanner.scan(root: root)

        let library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 1, "the mid-scan merge must survive the scan")
        XCTAssertEqual(library[0].files.count, 2)
        XCTAssertEqual(library[0].book.groupMethod, .manual)
        XCTAssertEqual(Set(library[0].files.compactMap(\.manualGroupId)).count, 1)
    }

    // SCAN-16
    func testUngroupDuringScanIsNotClobbered() throws {
        let database = try makeDatabase()
        let coverCache = try makeCoverCache()
        let root = try makeTempDir()
        // Two files that group automatically by stem into one book.
        try FixtureFactory.makeEpub(at: root.appendingPathComponent("dune.epub"),
                                    spec: .init(title: "Dune", authors: ["Frank Herbert"]))
        try FixtureFactory.makeMobi(at: root.appendingPathComponent("dune_v2.mobi"),
                                    spec: .init(headerTitle: "Dune"))
        _ = try LibraryScanner(database: database, coverCache: coverCache).scan(root: root)
        let bookId = try XCTUnwrap(database.fetchLibrary().first?.book.id)

        let commands = GroupCommands(database: database, coverCache: coverCache)
        let racyScanner = LibraryScanner(
            database: database, coverCache: coverCache,
            beforeReconcileHook: { _ = try? commands.ungroup(bookId: bookId) })
        _ = try racyScanner.scan(root: root)

        let library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 2, "the mid-scan ungroup must survive the scan")
        XCTAssertTrue(library.allSatisfy { $0.files.count == 1 })
    }
}
