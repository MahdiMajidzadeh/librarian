import Foundation
import GRDB
import BookShelfKit

func databaseTests(_ runner: TestRunner) async {
    await runner.run("migrations create all tables") {
        let db = try AppDatabase.inMemory()
        let tables = try await db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        for expected in ["book", "bookFile", "provenance", "renameLog", "setting"] {
            expect(tables.contains(expected), "missing table \(expected)")
        }
    }

    await runner.run("book round-trips with JSON arrays and unicode") {
        let db = try AppDatabase.inMemory()
        var book = Book(
            title: "بوف کور",
            authors: ["صادق هدایت", "Second Author"],
            year: 1936,
            language: "fa",
            tags: ["classic", "فارسی"]
        )
        book = try await db.writer.write { [book] db in
            var b = book
            try b.insert(db)
            return b
        }
        let bookId = book.id
        guard let bookId else {
            expect(false, "insert did not assign an id")
            return
        }
        let fetched = try await db.writer.read { db in
            try Book.fetchOne(db, key: bookId)
        }
        expectEqual(fetched?.title, "بوف کور")
        expectEqual(fetched?.authors ?? [], ["صادق هدایت", "Second Author"])
        expectEqual(fetched?.tags ?? [], ["classic", "فارسی"])
        expectEqual(fetched?.year, 1936)
    }

    await runner.run("bookFile cascade-deletes with its book and enforces unique path") {
        let db = try AppDatabase.inMemory()
        let bookId = try await db.writer.write { db -> Int64 in
            var b = Book(title: "Dune")
            try b.insert(db)
            var f = BookFile(bookId: b.id!, path: "/books/dune.epub", format: .epub,
                             sizeBytes: 1234, modifiedAt: Date(timeIntervalSince1970: 1000))
            try f.insert(db)
            return b.id!
        }
        // Unique path constraint
        let duplicateFailed: Bool = await {
            do {
                try await db.writer.write { db in
                    var dup = BookFile(bookId: bookId, path: "/books/dune.epub", format: .pdf,
                                       sizeBytes: 99, modifiedAt: Date())
                    try dup.insert(db)
                }
                return false
            } catch {
                return true
            }
        }()
        expect(duplicateFailed, "duplicate path insert should fail")

        _ = try await db.writer.write { db in
            try Book.deleteOne(db, key: bookId)
        }
        let remaining = try await db.writer.read { db in
            try BookFile.fetchCount(db)
        }
        expectEqual(remaining, 0, "files should cascade-delete with book")
    }

    await runner.run("provenance upserts per (book, field)") {
        let db = try AppDatabase.inMemory()
        let bookId = try await db.writer.write { db -> Int64 in
            var b = Book(title: "Dune")
            try b.insert(db)
            try ProvenanceRecord(bookId: b.id!, field: "title", source: .embedded).save(db)
            try ProvenanceRecord(bookId: b.id!, field: "title", source: .openLibrary).save(db)
            try ProvenanceRecord(bookId: b.id!, field: "year", source: .manual).save(db)
            return b.id!
        }
        let map = try db.provenance(forBook: bookId)
        expectEqual(map["title"], .openLibrary, "second save should overwrite")
        expectEqual(map["year"], .manual)
        expectEqual(map.count, 2)
    }

    await runner.run("repair junk embedded titles: re-derive from filename, keep manual and online") {
        let db = try AppDatabase.inMemory()
        // A book cataloged by an older version: junk embedded title, ISBN
        // waiting to be salvaged from it, real title in the filename.
        let junkId = try await db.writer.write { db -> Int64 in
            var b = Book(title: "0071501126.pdf")
            b.titleSort = Book.sortKey(forTitle: b.title)
            try b.insert(db)
            var f = BookFile(bookId: b.id!,
                             path: "/books/What_Customers_Want_Using_Outcome_Driven_Innovation.pdf",
                             format: .pdf, sizeBytes: 10, modifiedAt: Date())
            try f.insert(db)
            try ProvenanceRecord(bookId: b.id!, field: "title", source: .embedded).save(db)
            return b.id!
        }
        // A manual title that happens to look junk must never be touched.
        let manualId = try await db.writer.write { db -> Int64 in
            var b = Book(title: "untitled.pdf")
            try b.insert(db)
            var f = BookFile(bookId: b.id!, path: "/books/real.pdf",
                             format: .pdf, sizeBytes: 10, modifiedAt: Date())
            try f.insert(db)
            try ProvenanceRecord(bookId: b.id!, field: "title", source: .manual).save(db)
            return b.id!
        }
        // A genuine embedded title must survive.
        let goodId = try await db.writer.write { db -> Int64 in
            var b = Book(title: "Dune")
            try b.insert(db)
            var f = BookFile(bookId: b.id!, path: "/books/dune.pdf",
                             format: .pdf, sizeBytes: 10, modifiedAt: Date())
            try f.insert(db)
            try ProvenanceRecord(bookId: b.id!, field: "title", source: .embedded).save(db)
            return b.id!
        }

        let repaired = try await db.writer.write { try AppDatabase.repairJunkEmbeddedTitles($0) }
        expectEqual(repaired, 1, "only the junk embedded row is repaired")

        let junk = try await db.writer.read { try Book.fetchOne($0, key: junkId)! }
        expectEqual(junk.title, "What Customers Want Using Outcome Driven Innovation",
                    "title re-derived from the filename")
        expectEqual(junk.isbn10, "0071501126", "ISBN salvaged from the junk title")
        expectNil(try db.provenance(forBook: junkId)["title"],
                  "stale embedded-title provenance is dropped")

        let manual = try await db.writer.read { try Book.fetchOne($0, key: manualId)! }
        expectEqual(manual.title, "untitled.pdf", "manual titles are never repaired")

        let good = try await db.writer.read { try Book.fetchOne($0, key: goodId)! }
        expectEqual(good.title, "Dune", "real embedded titles survive")

        // Idempotent: a second pass changes nothing.
        let again = try await db.writer.write { try AppDatabase.repairJunkEmbeddedTitles($0) }
        expectEqual(again, 0, "repair is idempotent")
    }

    await runner.run("settings store and delete") {
        let db = try AppDatabase.inMemory()
        try db.setSetting("renameTemplate", "{author} - {title}.{ext}")
        expectEqual(try db.setting("renameTemplate"), "{author} - {title}.{ext}")
        try db.setSetting("renameTemplate", nil)
        expectNil(try db.setting("renameTemplate"))
    }

    await runner.run("sort keys strip articles and invert author names") {
        expectEqual(Book.sortKey(forTitle: "The Left Hand of Darkness"), "left hand of darkness")
        expectEqual(Book.sortKey(forTitle: "A Wizard of Earthsea"), "wizard of earthsea")
        expectEqual(Book.sortKey(forAuthors: ["Frank Herbert"]), "herbert, frank")
        expectEqual(Book.sortKey(forAuthors: ["Ursula K. Le Guin"]), "guin, ursula k. le")
        expectNil(Book.sortKey(forAuthors: []))
    }

    await runner.run("recordProvenance upserts and replaces the source per (book, field)") {
        let db = try AppDatabase.inMemory()
        let bookId = try await db.writer.write { database -> Int64 in
            var book = Book(title: "Dune", authors: [])
            try book.insert(database)
            try db.recordProvenance(bookId: book.id!, field: "title", source: .embedded, in: database)
            return book.id!
        }
        expectEqual(try db.provenance(forBook: bookId)["title"], .embedded)

        try await db.writer.write { database in
            try db.recordProvenance(bookId: bookId, field: "title", source: .manual, in: database)
        }
        let after = try db.provenance(forBook: bookId)
        expectEqual(after["title"], .manual, "re-recording replaces, never duplicates")
        expectEqual(after.count, 1)
    }

    await runner.run("contentKey is size|mtime-seconds") {
        expectEqual(BookFile.contentKey(sizeBytes: 100, modifiedAt: Date(timeIntervalSince1970: 5)),
                    "100|5")
        expectEqual(BookFile.contentKey(sizeBytes: 100, modifiedAt: Date(timeIntervalSince1970: 5.9)),
                    "100|5", "sub-second mtime jitter must not look like a change")
        let file = BookFile(bookId: 1, path: "/x/a.epub", format: .epub,
                            sizeBytes: 42, modifiedAt: Date(timeIntervalSince1970: 1_000))
        expectEqual(file.contentKey, "42|1000", "initializer derives the same key")
    }

    await runner.run("format catalog: extensions and embedded-metadata support") {
        expectEqual(BookFormat.allExtensions.count, BookFormat.allCases.count)
        for ext in ["epub", "pdf", "mobi", "azw3", "djvu", "cbz", "cbr", "fb2", "txt"] {
            expect(BookFormat.allExtensions.contains(ext), "\(ext) missing from catalog")
        }
        for format in [BookFormat.epub, .pdf, .mobi, .azw3] {
            expect(format.supportsEmbeddedMetadata, "\(format) has a parser")
        }
        for format in [BookFormat.djvu, .cbz, .cbr, .fb2, .txt] {
            expect(!format.supportsEmbeddedMetadata, "\(format) has no parser")
        }
    }
}
