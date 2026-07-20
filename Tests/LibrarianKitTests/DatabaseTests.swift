import XCTest
import GRDB
@testable import LibrarianKit

/// Catalog: DB-01 … DB-09 (test-case.md).
final class DatabaseTests: XCTestCase {
    // DB-01
    func testMigrationCreatesTables() throws {
        let database = try makeDatabase()
        let tables = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        for expected in ["book", "bookFile", "provenance", "renameLog", "setting"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
    }

    // DB-02
    func testBookRoundTrip() throws {
        let database = try makeDatabase()
        var book = Book(
            title: "بوف کور",
            authors: ["صادق هدایت", "Second Author"],
            series: "Classics",
            seriesIndex: 1.5,
            publisher: "امیرکبیر",
            year: 1937,
            language: "fa",
            isbn10: "0802131808",
            isbn13: "9780802131805",
            bookDescription: "The Blind Owl")
        book.metadataStatus = .complete
        book.groupMethod = .isbn
        try database.writer.write { db in try book.insert(db) }

        let fetched = try database.writer.read { db in
            try Book.fetchOne(db, key: book.id!)
        }
        XCTAssertEqual(fetched?.title, "بوف کور")
        XCTAssertEqual(fetched?.authors, ["صادق هدایت", "Second Author"])
        XCTAssertEqual(fetched?.seriesIndex, 1.5)
        XCTAssertEqual(fetched?.year, 1937)
        XCTAssertEqual(fetched?.isbn13, "9780802131805")
        XCTAssertEqual(fetched?.metadataStatus, .complete)
        XCTAssertEqual(fetched?.groupMethod, .isbn)
    }

    // DB-03
    func testBookFileCascadeDelete() throws {
        let database = try makeDatabase()
        let book = try insertBook(database, title: "T", filePaths: ["/tmp/a.epub", "/tmp/b.pdf"])
        try database.writer.write { db in
            _ = try Book.deleteOne(db, key: book.id!)
        }
        let fileCount = try database.writer.read { db in try BookFile.fetchCount(db) }
        XCTAssertEqual(fileCount, 0)
    }

    // DB-04
    func testProvenanceUpsert() throws {
        let database = try makeDatabase()
        let book = try insertBook(database, title: "T")
        try database.recordProvenance(bookId: book.id!, fields: ["title"], source: .embedded)
        try database.recordProvenance(bookId: book.id!, fields: ["title"], source: .manual)
        let map = try database.provenance(forBook: book.id!)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map["title"]?.source, .manual)
    }

    // DB-05
    func testSettingsDefaults() throws {
        let database = try makeDatabase()
        XCTAssertEqual(
            try database.setting(SettingKey.renameTemplate), "{author} - {title}.{ext}")
        XCTAssertNil(try database.setting("nonexistent.key"))
        try database.setSetting(SettingKey.csvDelimiter, to: ";")
        XCTAssertEqual(try database.setting(SettingKey.csvDelimiter), ";")
        try database.setSetting(SettingKey.csvDelimiter, to: nil)
        XCTAssertEqual(try database.setting(SettingKey.csvDelimiter), ",") // back to default
    }

    // DB-06
    func testPurgeMissingFiles() throws {
        let database = try makeDatabase()
        let gone = try insertBook(database, title: "Gone", filePaths: ["/tmp/gone.epub"])
        let kept = try insertBook(
            database, title: "Kept", filePaths: ["/tmp/kept.epub", "/tmp/kept-missing.pdf"])
        try database.writer.write { db in
            try db.execute(sql: "UPDATE bookFile SET missingFlag = 1 WHERE path LIKE '%gone%' OR path LIKE '%kept-missing%'")
        }
        try database.purgeMissingFiles()

        let books = try database.writer.read { db in try Book.fetchAll(db) }
        XCTAssertEqual(books.map(\.id), [kept.id])
        let files = try database.writer.read { db in try BookFile.fetchAll(db) }
        XCTAssertEqual(files.map(\.path), ["/tmp/kept.epub"])
        _ = gone
    }

    // DB-07
    func testFetchLibraryGroupsFiles() throws {
        let database = try makeDatabase()
        let a = try insertBook(database, title: "A", filePaths: ["/tmp/a.epub", "/tmp/a.pdf"])
        let b = try insertBook(database, title: "B", filePaths: ["/tmp/b.mobi"])
        let library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: library.map { ($0.book.id!, $0.files) })
        XCTAssertEqual(byId[a.id!]?.count, 2)
        XCTAssertEqual(byId[b.id!]?.map(\.path), ["/tmp/b.mobi"])
    }

    // DB-08
    func testSortKeyGeneration() {
        XCTAssertEqual(Book.sortKey(forTitle: "The Blind Owl"), "blind owl")
        XCTAssertEqual(Book.sortKey(forTitle: "A Tale"), "tale")
        XCTAssertEqual(Book.sortKey(forTitle: "Dune"), "dune")
        XCTAssertEqual(Book.sortKey(forAuthors: ["Frank Herbert"]), "herbert, frank")
        XCTAssertEqual(Book.lastFirst("Frank Herbert"), "Herbert, Frank")
        XCTAssertEqual(Book.lastFirst("Ursula K. Le Guin"), "Guin, Ursula K. Le")
        XCTAssertEqual(Book.lastFirst("Homer"), "Homer")
        XCTAssertEqual(Book.sortKey(forAuthors: []), "")
    }

    // DB-09
    func testRefreshMetadataStatus() {
        var book = Book(title: "T")
        book.refreshMetadataStatus()
        XCTAssertEqual(book.metadataStatus, .unresolved)

        book.authors = ["Someone"]
        book.refreshMetadataStatus()
        XCTAssertEqual(book.metadataStatus, .partial)

        book.year = 2001
        book.refreshMetadataStatus()
        XCTAssertEqual(book.metadataStatus, .complete)

        book.year = nil
        book.isbn13 = "9780441172719"
        book.refreshMetadataStatus()
        XCTAssertEqual(book.metadataStatus, .complete)
    }
}
