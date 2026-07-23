import XCTest
import GRDB
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: BAK-01 … BAK-07 (test-case.md). The in-folder catalog copy:
/// `.librarian.sqlite` written at the library root, restored only into an
/// empty live database, with path rebasing when the folder moved.
final class BackupTests: XCTestCase {
    // BAK-01
    func testBackupWritesHiddenFileAtRoot() throws {
        let database = try makeDatabase()
        let root = try makeTempDir()
        let book = try insertBook(
            database, title: "Dune", authors: ["Frank Herbert"], year: 1965,
            isbn13: "9780441172719", filePaths: [root.appendingPathComponent("dune.epub").path])
        try database.recordProvenance(bookId: book.id!, fields: ["title"], source: .manual)

        try LibraryBackup.write(from: database, toRoot: root)

        let url = LibraryBackup.url(forRoot: root)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("."), "backup must be hidden")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(LibraryBackup.exists(atRoot: root))

        let copy = try DatabaseQueue(path: url.path)
        try copy.read { db in
            XCTAssertEqual(try Book.fetchCount(db), 1)
            XCTAssertEqual(try BookFile.fetchCount(db), 1)
            XCTAssertEqual(try Provenance.fetchCount(db), 1)
            let restored = try XCTUnwrap(Book.fetchOne(db))
            XCTAssertEqual(restored.title, "Dune")
            XCTAssertEqual(restored.isbn13, "9780441172719")
        }
    }

    // BAK-02
    func testBackupRefreshReplacesCopy() throws {
        let database = try makeDatabase()
        let root = try makeTempDir()
        try insertBook(database, title: "First")
        try LibraryBackup.write(from: database, toRoot: root)
        try insertBook(database, title: "Second")
        try LibraryBackup.write(from: database, toRoot: root)

        let copy = try DatabaseQueue(path: LibraryBackup.url(forRoot: root).path)
        try copy.read { db in
            XCTAssertEqual(try Book.fetchCount(db), 2)
        }
        let temp = root.appendingPathComponent(LibraryBackup.fileName + ".tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "temp file must be swapped away")
    }

    // BAK-03
    func testRestoreSkipsNonEmptyCatalog() throws {
        let source = try makeDatabase()
        let root = try makeTempDir()
        try insertBook(source, title: "From Backup")
        try LibraryBackup.write(from: source, toRoot: root)

        let live = try makeDatabase()
        try insertBook(live, title: "Already Here")

        let restored = try LibraryBackup.restoreIfNeeded(into: live, root: root)
        XCTAssertFalse(restored)
        let titles = try live.writer.read { db in try Book.fetchAll(db).map(\.title) }
        XCTAssertEqual(titles, ["Already Here"], "existing catalog must never be clobbered")
    }

    // BAK-04
    func testRestoreIntoEmptyCatalog() throws {
        let source = try makeDatabase()
        let root = try makeTempDir()
        let filePath = root.appendingPathComponent("dune.epub").path
        let book = try insertBook(
            source, title: "Dune", authors: ["Frank Herbert"], year: 1965,
            filePaths: [filePath])
        try source.recordProvenance(bookId: book.id!, fields: ["title", "year"], source: .manual)
        try source.setSetting(SettingKey.renameTemplate, to: "{title}.{ext}")
        try source.writer.write { db in
            var log = RenameLog(
                batchId: "batch-1", fileId: 1,
                oldPath: root.appendingPathComponent("old.epub").path, newPath: filePath)
            try log.insert(db)
        }
        try LibraryBackup.write(from: source, toRoot: root)

        let live = try makeDatabase()
        let restored = try LibraryBackup.restoreIfNeeded(into: live, root: root)
        XCTAssertTrue(restored)
        try live.writer.read { db in
            let book = try XCTUnwrap(Book.fetchOne(db))
            XCTAssertEqual(book.title, "Dune")
            XCTAssertEqual(book.authors, ["Frank Herbert"])
            XCTAssertEqual(try BookFile.fetchOne(db)?.path, filePath)
            XCTAssertEqual(try Provenance.fetchCount(db), 2)
            XCTAssertEqual(try RenameLog.fetchCount(db), 1)
        }
        XCTAssertEqual(try live.setting(SettingKey.renameTemplate), "{title}.{ext}")
        XCTAssertEqual(try live.setting(SettingKey.libraryPath), root.path)
    }

    // BAK-05
    func testRestoreRebasesMovedRoot() throws {
        let source = try makeDatabase()
        let rootA = try makeTempDir()
        let rootB = try makeTempDir()
        try insertBook(
            source, title: "Dune",
            filePaths: [rootA.appendingPathComponent("shelf/dune.epub").path])
        try source.writer.write { db in
            var log = RenameLog(
                batchId: "batch-1", fileId: 1,
                oldPath: rootA.appendingPathComponent("shelf/old name.epub").path,
                newPath: rootA.appendingPathComponent("shelf/dune.epub").path)
            try log.insert(db)
        }
        try source.setSetting(SettingKey.libraryBookmark, to: "c3RhbGU=")
        try LibraryBackup.write(from: source, toRoot: rootA)

        // Simulate the folder moving: copy the backup into a different root.
        try FileManager.default.copyItem(
            at: LibraryBackup.url(forRoot: rootA), to: LibraryBackup.url(forRoot: rootB))

        let live = try makeDatabase()
        XCTAssertTrue(try LibraryBackup.restoreIfNeeded(into: live, root: rootB))
        try live.writer.read { db in
            let file = try XCTUnwrap(BookFile.fetchOne(db))
            XCTAssertEqual(file.path, rootB.appendingPathComponent("shelf/dune.epub").path)
            let log = try XCTUnwrap(RenameLog.fetchOne(db))
            XCTAssertEqual(log.oldPath, rootB.appendingPathComponent("shelf/old name.epub").path)
            XCTAssertEqual(log.newPath, rootB.appendingPathComponent("shelf/dune.epub").path)
        }
        XCTAssertEqual(try live.setting(SettingKey.libraryPath), rootB.path)
        XCTAssertNil(try live.setting(SettingKey.libraryBookmark), "stale bookmark must be cleared")
    }

    // BAK-06
    func testRestoreClearsDanglingCoverPaths() throws {
        let source = try makeDatabase()
        let root = try makeTempDir()
        let coverCache = try makeCoverCache()

        let kept = try insertBook(source, title: "Has Cover")
        let dangling = try insertBook(source, title: "Lost Cover")
        let keptPath = try coverCache.store(FixtureFactory.tinyJPEG(), forBookId: kept.id!)
        try source.writer.write { db in
            var keptBook = kept
            keptBook.coverCachePath = keptPath
            try keptBook.update(db)
            var danglingBook = dangling
            danglingBook.coverCachePath = "book-999-grid.jpg" // not in this cache
            try danglingBook.update(db)
        }
        try LibraryBackup.write(from: source, toRoot: root)

        let live = try makeDatabase()
        XCTAssertTrue(try LibraryBackup.restoreIfNeeded(into: live, root: root, coverCache: coverCache))
        try live.writer.read { db in
            let books = try Book.order(Column("titleSort")).fetchAll(db)
            XCTAssertEqual(books.first?.coverCachePath, keptPath, "existing cover kept")
            XCTAssertNil(books.last?.coverCachePath, "dangling cover cleared so scan re-extracts")
        }
    }

    // BAK-07
    func testBackupFileNotScanned() throws {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(at: root.appendingPathComponent("book.epub"),
                                    spec: .init(title: "Real Book"))
        let backupSource = try makeDatabase()
        try LibraryBackup.write(from: backupSource, toRoot: root)

        let summary = try scanner.scan(root: root)
        XCTAssertEqual(summary.added, 1)
        let paths = try database.writer.read { db in try BookFile.fetchAll(db) }.map(\.path)
        XCTAssertEqual(paths.count, 1)
        XCTAssertFalse(paths.contains { $0.contains(LibraryBackup.fileName) })
    }
}
