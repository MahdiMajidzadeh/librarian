import Foundation
import GRDB
import BookShelfKit

func groupingRegressionTests(_ runner: TestRunner) async {
    await runner.run("collection files sharing ' - 2007)' suffix never group") {
        let engine = GroupingEngine()
        let a = GroupingSeed(rawStem: "The 5 Paths to Persuasion (Robert B. Miller, Gary A. Williams etc. - 2007)")
        let bookA = try await inMemoryAssign(engine, a)
        _ = bookA

        let b = GroupingSeed(rawStem: "The 4-Hour Workweek (Timothy Ferriss, Michael Porter etc. - 2007)")
        expectEqual(engine.decide(b), .createNew,
                    "a shared year token must not glue different titles together")

        let c = GroupingSeed(rawStem: "On Writing Well (William Zinsser - 2007)")
        expectEqual(engine.decide(c), .createNew)

        // The legitimate case still works: same title, author agreement.
        let d = GroupingSeed(rawStem: "The 5 Paths to Persuasion (Robert B. Miller, Gary A. Williams etc. - 2007)")
        if case .join = engine.decide(d) {} else {
            expect(false, "identical stem must still join")
        }
    }

    await runner.run("ungroup dissolves a book into manual per-file books that never re-join") {
        let database = try AppDatabase.inMemory()
        let bookId = try await database.writer.write { db -> Int64 in
            var book = Book(title: "Dune", authors: ["Frank Herbert"], groupMethod: .filename)
            try book.insert(db)
            for name in ["dune.epub", "dune_v2.pdf", "dune (ocr).mobi"] {
                var file = BookFile(bookId: book.id!, path: "/b/\(name)",
                                    format: BookFormat(rawValue: String(name.split(separator: ".").last!))!,
                                    sizeBytes: 10, modifiedAt: Date())
                try file.insert(db)
            }
            return book.id!
        }

        let newIds = try await database.writer.write { db in
            try GroupingOperations.ungroup(db, bookId: bookId)
        }
        expectEqual(newIds.count, 2, "two files split out, first stays")

        let books = try await database.writer.read { try Book.fetchAll($0) }
        let files = try await database.writer.read { try BookFile.fetchAll($0) }
        expectEqual(books.count, 3, "one book per file")
        expect(books.allSatisfy(\.manualGroup), "all pieces flagged manual: \(books.map(\.manualGroup))")
        expectEqual(Set(files.map(\.bookId)).count, 3, "each file owns its book")

        // The manual flag must keep the engine from re-joining them.
        let engine = try await database.writer.read { try GroupingEngine.load($0) }
        expectEqual(engine.decide(GroupingSeed(rawStem: "dune")), .createNew,
                    "manual books are invisible to auto-grouping")

        // Ungrouping a single-file book is a no-op.
        let noop = try await database.writer.write { db in
            try GroupingOperations.ungroup(db, bookId: bookId)
        }
        expect(noop.isEmpty, "single-file book cannot be ungrouped further")
    }

    await runner.run("different works by one author never merge via authored filenames") {
        let engine = GroupingEngine()
        _ = try await inMemoryAssign(engine, GroupingSeed(rawStem: "Frank Herbert - Dune"))
        expectEqual(engine.decide(GroupingSeed(rawStem: "Frank Herbert - Dune Messiah")), .createNew,
                    "flipped Author-Title reading must not merge series works on a shared token")
        // The same work with the split order swapped still joins.
        if case .join = engine.decide(GroupingSeed(rawStem: "Dune - Frank Herbert")) {} else {
            expect(false, "Title - Author order of the same work must still join")
        }
    }

    await runner.run("volume numbers are significant; (n) copy markers are not") {
        let engine = GroupingEngine()
        _ = try await inMemoryAssign(engine, GroupingSeed(rawStem: "Foundation 1"))
        expectEqual(engine.decide(GroupingSeed(rawStem: "Foundation 2")), .createNew,
                    "volume numbers distinguish works")

        let engine2 = GroupingEngine()
        _ = try await inMemoryAssign(engine2, GroupingSeed(rawStem: "dune"))
        if case .join = engine2.decide(GroupingSeed(rawStem: "dune (1)")) {} else {
            expect(false, "a duplicate-copy (1) marker must still group with the original")
        }
    }

    await runner.run("numeric and stopword-only title keys are not viable") {
        expect(!GroupingEngine.isViableTitleKey("2007"), "bare year")
        expect(!GroupingEngine.isViableTitleKey("the"), "stopword")
        expect(!GroupingEngine.isViableTitleKey("1 2 3"), "numbers only")
        expect(GroupingEngine.isViableTitleKey("dune"), "real word")
        expect(GroupingEngine.isViableTitleKey("1984 orwell"), "year plus word ok")
        expectEqual(GroupingEngine.meaningfulTokens("the 2007 etc herbert"), ["herbert"])
    }
}

/// Runs assignBook against a throwaway database so decide/register state
/// mirrors a real scan.
private func inMemoryAssign(_ engine: GroupingEngine, _ seed: GroupingSeed) async throws -> Int64 {
    let db = try AppDatabase.inMemory()
    return try await db.writer.write { db in
        try engine.assignBook(db, seed: seed)
    }
}

private func touch(_ dir: URL, _ name: String) throws {
    let url = dir.appendingPathComponent(name)
    try "x".data(using: .utf8)!.write(to: url)
}

private func scanGrouped(_ db: AppDatabase, root: URL) async throws {
    let engine = try await db.writer.read { try GroupingEngine.load($0) }
    let scanner = LibraryScanner(database: db, assignBook: engine.makeAssigner())
    _ = try await scanner.scan(root: root)
}

func groupingTests(_ runner: TestRunner) async {
    await runner.run("normalizer: casefold, diacritics, punctuation, noise words") {
        expectEqual(Normalizer.normalize("Café — Été!"), "cafe ete")
        expectEqual(Normalizer.normalizeTitle("The Left Hand of Darkness"), "left hand of darkness")
        expectEqual(Normalizer.normalizeFilenameStem("Dune_v2.final(1)"), "dune")
        expectEqual(Normalizer.normalizeFilenameStem("brave-new-world OCR"), "brave new world")
        expectEqual(
            Normalizer.authorTokenSet(["Frank Herbert"]),
            Normalizer.authorTokenSet(["Herbert, Frank"]),
            "author sets must be order-independent")
    }

    await runner.run("normalizer: ISBN validation") {
        expectEqual(Normalizer.extractISBN("urn:isbn:978-0-441-17271-9"), "9780441172719")
        expectEqual(Normalizer.extractISBN("0-441-17271-7"), "0441172717")
        expectNil(Normalizer.extractISBN("978-0-441-17271-0"), "bad check digit must fail")
        expectNil(Normalizer.extractISBN("12345"))
    }

    await runner.run("acceptance: dune.epub + Dune - Frank Herbert.pdf + dune_v2.mobi group as one") {
        try await withTempDirectory { dir in
            try touch(dir, "dune.epub")
            try touch(dir, "Dune - Frank Herbert.pdf")
            try touch(dir, "dune_v2.mobi")

            let db = try AppDatabase.inMemory()
            try await scanGrouped(db, root: dir)

            let books = try await db.writer.read { try Book.fetchAll($0) }
            expectEqual(books.count, 1, "expected one grouped book, got \(books.map(\.title))")
            let files = try await db.writer.read { try BookFile.fetchAll($0) }
            expectEqual(Set(files.map(\.format)), [.epub, .pdf, .mobi])
            expectEqual(books.first?.groupMethod, .filename, "stem-only grouping → auto-grouped flag")
        }
    }

    await runner.run("same title, different authors stay separate (Rework case)") {
        try await withTempDirectory { dir in
            try touch(dir, "Rework - Jason Fried.epub")
            try touch(dir, "Rework - Peter Smith.pdf")

            let db = try AppDatabase.inMemory()
            try await scanGrouped(db, root: dir)

            let count = try await db.writer.read { try Book.fetchCount($0) }
            expectEqual(count, 2, "conflicting author tokens must not group")
        }
    }

    await runner.run("Dune Messiah does not join Dune") {
        try await withTempDirectory { dir in
            try touch(dir, "dune.epub")
            try touch(dir, "dune messiah.epub")

            let db = try AppDatabase.inMemory()
            try await scanGrouped(db, root: dir)

            let count = try await db.writer.read { try Book.fetchCount($0) }
            expectEqual(count, 2)
        }
    }

    await runner.run("embedded ISBN outranks differing filenames") {
        let db = try AppDatabase.inMemory()
        let isbn = "9780441172719"
        try await db.writer.write { db in
            let engine = try GroupingEngine.load(db)
            let first = try engine.assignBook(db, seed: GroupingSeed(
                isbn: isbn, title: "Dune", authors: ["Frank Herbert"], rawStem: "book_final2"))
            let second = try engine.assignBook(db, seed: GroupingSeed(
                isbn: isbn, rawStem: "completely_unrelated_name"))
            expectEqual(first, second, "same ISBN must join regardless of names")
            let book = try Book.fetchOne(db, key: first)
            expectEqual(book?.groupMethod, .isbn)
        }
    }

    await runner.run("embedded title+authors group across different stems") {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { db in
            let engine = try GroupingEngine.load(db)
            let a = try engine.assignBook(db, seed: GroupingSeed(
                title: "The Dispossessed", authors: ["Ursula K. Le Guin"], rawStem: "dispossessed_scan"))
            let b = try engine.assignBook(db, seed: GroupingSeed(
                title: "Dispossessed", authors: ["Le Guin, Ursula K."], rawStem: "ulg-01"))
            expectEqual(a, b, "normalized title + author set must match")
        }
    }

    await runner.run("manual split persists across rescans") {
        try await withTempDirectory { dir in
            try touch(dir, "dune.epub")
            try touch(dir, "dune.pdf")

            let db = try AppDatabase.inMemory()
            try await scanGrouped(db, root: dir)
            var books = try await db.writer.read { try Book.fetchAll($0) }
            expectEqual(books.count, 1)

            // User splits the pdf out.
            let pdfFile = try await db.writer.read { db in
                try BookFile.fetchAll(db).first { $0.path.hasSuffix(".pdf") }
            }
            _ = try await db.writer.write { db in
                try GroupingOperations.split(db, fileId: pdfFile!.id!)
            }
            books = try await db.writer.read { try Book.fetchAll($0) }
            expectEqual(books.count, 2)

            // Rescan: existing files untouched, and a NEW dune file must not
            // join the manually-split book.
            try touch(dir, "dune.mobi")
            try await scanGrouped(db, root: dir)
            let after = try await db.writer.read { try Book.fetchAll($0) }
            let manualBook = after.first { $0.manualGroup }
            let fileCounts = try await db.writer.read { db in
                try Dictionary(grouping: BookFile.fetchAll(db), by: \.bookId).mapValues(\.count)
            }
            expectEqual(after.count, 2, "mobi should join the automatic group, not create a third")
            expectEqual(fileCounts[manualBook!.id!], 1, "manual book must not attract new files")
        }
    }

    await runner.run("manual merge keeps target metadata and deletes empty sources") {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { db in
            var a = Book(title: "Dune", authors: ["Frank Herbert"], metadataStatus: .complete)
            try a.insert(db)
            var b = Book(title: "dune (scan)")
            try b.insert(db)
            var f1 = BookFile(bookId: a.id!, path: "/x/dune.epub", format: .epub, sizeBytes: 1, modifiedAt: Date())
            try f1.insert(db)
            var f2 = BookFile(bookId: b.id!, path: "/x/dune-scan.pdf", format: .pdf, sizeBytes: 1, modifiedAt: Date())
            try f2.insert(db)

            try GroupingOperations.merge(db, sourceIds: [b.id!], into: a.id!)

            expectEqual(try Book.fetchCount(db), 1)
            let target = try Book.fetchOne(db, key: a.id!)
            expectEqual(target?.title, "Dune")
            expectEqual(target?.manualGroup, true)
            expectEqual(try BookFile.filter(BookFile.Columns.bookId == a.id!).fetchCount(db), 2)
        }
    }

    await runner.run("filename inference: Author - Title orientation") {
        let r1 = GroupingEngine.inferTitleAuthors(fromStem: "Frank Herbert - Dune Messiah and Other Stories")
        expectEqual(r1.title, "Dune Messiah and Other Stories")
        expectEqual(r1.authors, ["Frank Herbert"])
        let r2 = GroupingEngine.inferTitleAuthors(fromStem: "A Very Long Book Title Here - Jane Doe")
        expectEqual(r2.title, "A Very Long Book Title Here")
        expectEqual(r2.authors, ["Jane Doe"])
        let r3 = GroupingEngine.inferTitleAuthors(fromStem: "plain_filename")
        expectEqual(r3.title, "plain filename")
        expectEqual(r3.authors, [])
    }
}
