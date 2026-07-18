import Foundation
import GRDB
import BookShelfKit

func exportTests(_ runner: TestRunner) async {
    func seedLibrary(_ database: AppDatabase) async throws -> [Int64] {
        try await database.writer.write { db in
            var ids: [Int64] = []
            var dune = Book(title: "Dune", authors: ["Frank Herbert"], series: "Dune",
                            seriesIndex: 1, publisher: "Ace", year: 1965, language: "en",
                            isbn13: "9780441172719", tags: ["sf", "classic"],
                            metadataStatus: .complete)
            try dune.insert(db)
            try ProvenanceRecord(bookId: dune.id!, field: "title", source: .embedded).save(db)
            try ProvenanceRecord(bookId: dune.id!, field: "year", source: .openLibrary).save(db)
            var f1 = BookFile(bookId: dune.id!, path: "/books/dune.epub", format: .epub,
                              sizeBytes: 1000, modifiedAt: Date(timeIntervalSince1970: 1_000_000))
            try f1.insert(db)
            var f2 = BookFile(bookId: dune.id!, path: "/books/dune.pdf", format: .pdf,
                              sizeBytes: 2000, modifiedAt: Date(timeIntervalSince1970: 1_000_000))
            try f2.insert(db)
            ids.append(dune.id!)

            var persian = Book(title: "بوف کور", authors: ["صادق هدایت"], language: "fa",
                               tags: ["فارسی"])
            try persian.insert(db)
            var f3 = BookFile(bookId: persian.id!, path: "/books/بوف کور.epub", format: .epub,
                              sizeBytes: 500, modifiedAt: Date(timeIntervalSince1970: 2_000_000))
            try f3.insert(db)
            ids.append(persian.id!)
            return ids
        }
    }

    await runner.run("json export: schema v1, provenance, files, unicode round-trip") {
        try await withTempDirectory { dir in
            let database = try AppDatabase.inMemory()
            _ = try await seedLibrary(database)
            let records = try await ExportRecord.fetch(from: database)
            let url = dir.appendingPathComponent("library.json")
            try JSONExporter.export(records: records, to: url, includeCovers: false, coverCache: nil)

            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            expectEqual(json["schema_version"] as? Int, 1)
            expectEqual(json["book_count"] as? Int, 2)
            let books = json["books"] as! [[String: Any]]
            expectEqual(books.count, 2)

            let dune = books.first { $0["title"] as? String == "Dune" }!
            expectEqual((dune["files"] as! [[String: Any]]).count, 2)
            let provenance = dune["provenance"] as! [String: String]
            expectEqual(provenance["title"], "embedded")
            expectEqual(provenance["year"], "open_library")
            expectEqual(dune["isbn13"] as? String, "9780441172719")

            let persian = books.first { $0["title"] as? String == "بوف کور" }!
            expectEqual((persian["authors"] as! [String]), ["صادق هدایت"])
        }
    }

    await runner.run("json export: covers folder with relative paths") {
        try await withTempDirectory { dir in
            let database = try AppDatabase.inMemory()
            let cache = try CoverCache(directory: dir.appendingPathComponent("cache"))
            let bookId = try await database.writer.write { db -> Int64 in
                var book = Book(title: "Dune", authors: ["Frank Herbert"])
                try book.insert(db)
                return book.id!
            }
            let gridURL = try cache.store(imageData: Fixtures.jpegData(), bookId: bookId)
            try await database.writer.write { db in
                var book = try Book.fetchOne(db, key: bookId)!
                book.coverCachePath = gridURL.path
                try book.update(db)
            }

            let exportDir = dir.appendingPathComponent("export")
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            let url = exportDir.appendingPathComponent("library.json")
            let records = try await ExportRecord.fetch(from: database)
            try JSONExporter.export(records: records, to: url, includeCovers: true, coverCache: cache)

            let json = try JSONSerialization.jsonObject(
                with: Data(contentsOf: url)) as! [String: Any]
            let book = (json["books"] as! [[String: Any]])[0]
            expectEqual(book["cover_path"] as? String, "covers/\(bookId).jpg")
            expect(FileManager.default.fileExists(
                atPath: exportDir.appendingPathComponent("covers/\(bookId).jpg").path),
                "cover file must resolve via the relative path")
        }
    }

    await runner.run("csv export: BOM, delimiter, escaping, multi-value join") {
        try await withTempDirectory { dir in
            let database = try AppDatabase.inMemory()
            _ = try await database.writer.write { db -> Int64 in
                var book = Book(title: "Hello, World \"Quoted\"",
                                authors: ["A One", "B Two"], year: 2020)
                try book.insert(db)
                var file = BookFile(bookId: book.id!, path: "/x/h.epub", format: .epub,
                                    sizeBytes: 10, modifiedAt: Date())
                try file.insert(db)
                return book.id!
            }
            let url = dir.appendingPathComponent("library.csv")
            let records = try await ExportRecord.fetch(from: database)
            try CSVExporter.export(records: records, to: url)

            let raw = try Data(contentsOf: url)
            expectEqual(raw.prefix(3), Data([0xEF, 0xBB, 0xBF]), "must start with UTF-8 BOM")
            let text = String(data: raw.dropFirst(3), encoding: .utf8)!
            let lines = text.split(separator: "\r\n")
            expectEqual(lines.count, 2)
            expect(lines[0].hasPrefix("title,authors,"), "header row expected")
            expect(lines[1].contains("\"Hello, World \"\"Quoted\"\"\""),
                   "comma+quote field must be escaped, got: \(lines[1])")
            expect(lines[1].contains("A One; B Two"), "multi-value join with '; '")
        }
    }

    await runner.run("csv export: custom delimiter and separator honored") {
        try await withTempDirectory { dir in
            let database = try AppDatabase.inMemory()
            _ = try await database.writer.write { db -> Int64 in
                var book = Book(title: "Dune", authors: ["Frank Herbert", "Someone Else"])
                try book.insert(db)
                return book.id!
            }
            let url = dir.appendingPathComponent("semi.csv")
            let records = try await ExportRecord.fetch(from: database)
            try CSVExporter.export(records: records, to: url,
                                   options: .init(delimiter: ";", multiValueSeparator: " | "))
            let text = String(data: try Data(contentsOf: url).dropFirst(3), encoding: .utf8)!
            expect(text.contains("title;authors;"), "custom delimiter in header")
            expect(text.contains("Frank Herbert | Someone Else"), "custom multi-value separator")
        }
    }

    await runner.run("export scope: selection subset only") {
        let database = try AppDatabase.inMemory()
        let ids = try await seedLibrary(database)
        let subset = try await ExportRecord.fetch(from: database, bookIds: [ids[0]])
        expectEqual(subset.count, 1)
        expectEqual(subset.first?.book.title, "Dune")
    }
}
