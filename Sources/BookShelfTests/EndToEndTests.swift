import Foundation
import GRDB
import BookShelfKit

extension Fixtures {
    /// Writes the demo library used by both `--seed` and the end-to-end test:
    /// the Dune grouping-acceptance trio, a Persian epub, a distinct second
    /// book, and a metadata-less straggler.
    static func seedDemoLibrary(at dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The acceptance-criteria trio: three formats of Dune that must group.
        try makeEpub(at: dir.appendingPathComponent("dune.epub"))
        try makePDF(at: dir.appendingPathComponent("Dune - Frank Herbert.pdf"),
                    title: nil, author: nil, subject: nil, keywords: nil)
        try makeMobi(at: dir.appendingPathComponent("dune_v2.mobi"))

        var persian = EpubSpec()
        persian.title = "بوف کور"
        persian.authors = ["صادق هدایت"]
        persian.language = "fa"
        persian.isbn = nil
        persian.subjects = ["فارسی"]
        try makeEpub(at: dir.appendingPathComponent("boofe-koor.epub"), spec: persian)

        var hyperion = MobiSpec()
        hyperion.fullName = "Hyperion"
        hyperion.authors = ["Dan Simmons"]
        hyperion.isbn = "9780553283686"
        hyperion.publishDate = "1989"
        try makeMobi(at: dir.appendingPathComponent("hyperion.mobi"), spec: hyperion)

        var bare = EpubSpec()
        bare.title = nil
        bare.authors = []
        bare.isbn = nil
        bare.publisher = nil
        bare.date = nil
        bare.description = nil
        bare.subjects = []
        bare.includeCover = false
        try makeEpub(at: dir.appendingPathComponent("book_final2.epub"), spec: bare)
    }
}

/// Full-pipeline test over real generated files: scan → parse → group →
/// covers → rescan → export, mirroring the §6.2 acceptance criteria.
func endToEndTests(_ runner: TestRunner) async {
    await runner.run("cover ranking: embedded epub cover replaces pdf page render") {
        try await withTempDirectory { dir in
            let library = dir.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let database = try AppDatabase.inMemory()
            let coverCache = try CoverCache(directory: dir.appendingPathComponent("covers"))
            let pipeline = ScanPipeline(database: database, coverCache: coverCache)

            // PDF arrives first and claims the cover with its page render.
            try Fixtures.makePDF(at: library.appendingPathComponent("Dune - Frank Herbert.pdf"))
            _ = try await pipeline.scan(root: library)
            var book = try await database.writer.read { try Book.fetchOne($0) }
            expectEqual(book?.coverSourceFormat, .pdf)
            expectNotNil(book?.coverCachePath).map { _ in }

            // The epub joins the same book; its real cover must win.
            try Fixtures.makeEpub(at: library.appendingPathComponent("dune.epub"))
            _ = try await pipeline.scan(root: library)
            let bookCount = try await database.writer.read { try Book.fetchCount($0) }
            expectEqual(bookCount, 1, "pdf and epub must group into one book")
            book = try await database.writer.read { try Book.fetchOne($0) }
            expectEqual(book?.coverSourceFormat, .epub, "embedded cover should replace pdf render")

            // Re-extract keeps the epub cover (pdf never downgrades it).
            _ = try await pipeline.reextractEmbedded()
            book = try await database.writer.read { try Book.fetchOne($0) }
            expectEqual(book?.coverSourceFormat, .epub)
        }
    }

    await runner.run("re-extract upgrades covers on an already-scanned library") {
        try await withTempDirectory { dir in
            let library = dir.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let database = try AppDatabase.inMemory()
            let coverCache = try CoverCache(directory: dir.appendingPathComponent("covers"))
            let pipeline = ScanPipeline(database: database, coverCache: coverCache)

            try Fixtures.makePDF(at: library.appendingPathComponent("Dune - Frank Herbert.pdf"))
            try Fixtures.makeEpub(at: library.appendingPathComponent("dune.epub"))
            _ = try await pipeline.scan(root: library)

            // Simulate a pre-ranking database: force the cover back to the pdf.
            try await database.writer.write { db in
                var book = try Book.fetchOne(db)!
                book.coverSourceFormat = nil   // unknown provenance, as after migration
                try book.update(db)
            }

            let processed = try await pipeline.reextractEmbedded()
            expectEqual(processed, 2)
            let book = try await database.writer.read { try Book.fetchOne($0) }
            expectEqual(book?.coverSourceFormat, .epub,
                        "re-extract must upgrade an unknown-provenance cover to the epub one")
        }
    }

    await runner.run("e2e: scan groups Dune trio, parses Persian epub, exports valid JSON") {
        try await withTempDirectory { dir in
            let library = dir.appendingPathComponent("library")
            try Fixtures.seedDemoLibrary(at: library)

            let database = try AppDatabase.inMemory()
            let coverCache = try CoverCache(directory: dir.appendingPathComponent("covers"))
            let pipeline = ScanPipeline(database: database, coverCache: coverCache)

            let result = try await pipeline.scan(root: library)
            expectEqual(result.added, 6, "six files on disk")

            let books = try await database.writer.read { try Book.fetchAll($0) }
            let files = try await database.writer.read { try BookFile.fetchAll($0) }
            expectEqual(books.count, 4, "dune trio must collapse into one book: \(books.map(\.title))")

            // §6.2 acceptance: one Dune entry with three format badges.
            let dune = books.first { $0.title == "Dune" }
            if let dune {
                let duneFormats = Set(files.filter { $0.bookId == dune.id }.map(\.format))
                expectEqual(duneFormats, [.epub, .pdf, .mobi])
                expectEqual(dune.authors, ["Frank Herbert"])
                expectEqual(dune.year, 1965)
                expectEqual(dune.isbn13, "9780441172719")
                expectNotNil(dune.coverCachePath, "embedded cover should be cached") .map { path in
                    expect(FileManager.default.fileExists(atPath: path), "cover file on disk")
                }
            } else {
                expect(false, "no book titled Dune")
            }

            // Persian metadata survives end-to-end (NFR-4).
            let persian = books.first { $0.title == "بوف کور" }
            expectEqual(persian?.authors ?? [], ["صادق هدایت"])
            expectEqual(persian?.language, "fa")

            // The metadata-less file stays visible as unresolved.
            let straggler = books.first { $0.title.contains("book final2") || $0.title.contains("book_final2") }
            expectEqual(straggler?.metadataStatus, .unresolved)

            // Incremental rescan: nothing re-added, grouping stable (FR-1.4).
            let second = try await pipeline.scan(root: library)
            expectEqual(second.added, 0)
            expectEqual(second.unchanged, 6)
            let bookCountAfter = try await database.writer.read { try Book.fetchCount($0) }
            expectEqual(bookCountAfter, 4)

            // Export: every files[] entry matches disk reality (§6.5 acceptance).
            let records = try await ExportRecord.fetch(from: database)
            let jsonURL = dir.appendingPathComponent("library.json")
            try JSONExporter.export(records: records, to: jsonURL,
                                    includeCovers: true, coverCache: coverCache)
            let json = try JSONSerialization.jsonObject(
                with: Data(contentsOf: jsonURL)) as! [String: Any]
            expectEqual(json["schema_version"] as? Int, 1)
            let exported = json["books"] as! [[String: Any]]
            expectEqual(exported.count, 4)
            for book in exported {
                for file in book["files"] as! [[String: Any]] {
                    let path = file["path"] as! String
                    expect(FileManager.default.fileExists(atPath: path),
                           "exported path missing on disk: \(path)")
                }
                if let cover = book["cover_path"] as? String {
                    let coverURL = jsonURL.deletingLastPathComponent()
                        .appendingPathComponent(cover)
                    expect(FileManager.default.fileExists(atPath: coverURL.path),
                           "cover_path must resolve relative to the export: \(cover)")
                }
            }
        }
    }
}
