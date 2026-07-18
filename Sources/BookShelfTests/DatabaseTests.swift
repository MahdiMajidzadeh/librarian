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
}
