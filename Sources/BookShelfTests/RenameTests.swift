import Foundation
import GRDB
import BookShelfKit

func renameTests(_ runner: TestRunner) async {
    let dune = Book(id: 1, title: "Dune", authors: ["Frank Herbert"],
                    series: "Dune Chronicles", seriesIndex: 1, publisher: "Ace",
                    year: 1965, language: "en", isbn13: "9780441172719")

    await runner.run("template: default renders author - title.ext") {
        let template = try RenameTemplate.parse(RenameTemplate.defaultRaw)
        let result = template.render(book: dune, fileExtension: "epub")
        expectEqual(result.name, "Frank Herbert - Dune.epub")
    }

    await runner.run("template: all tokens render") {
        let template = try RenameTemplate.parse(
            "{authors} ({author_sort}) {title} {year} {series} {series_index} {isbn} {language} {publisher}.{ext}")
        let result = template.render(book: dune, fileExtension: "pdf")
        expectEqual(result.name,
            "Frank Herbert (Herbert, Frank) Dune 1965 Dune Chronicles 1 9780441172719 en Ace.pdf")
    }

    await runner.run("template: conditional renders only when guard present") {
        let template = try RenameTemplate.parse(
            "{title}{series? ({series} #{series_index})}.{ext}")
        let withSeries = template.render(book: dune, fileExtension: "epub")
        expectEqual(withSeries.name, "Dune (Dune Chronicles #1).epub")

        var standalone = dune
        standalone.series = nil
        standalone.seriesIndex = nil
        let without = template.render(book: standalone, fileExtension: "epub")
        expectEqual(without.name, "Dune.epub", "conditional must collapse cleanly")
    }

    await runner.run("template: missing required token excludes with reason (FR-4.9)") {
        let template = try RenameTemplate.parse("{author} - {title}.{ext}")
        var anonymous = dune
        anonymous.authors = []
        let result = template.render(book: anonymous, fileExtension: "epub")
        expectNil(result.name)
        expectEqual(result.missingTokens, [.author])
    }

    await runner.run("template: empty collapse leaves no dangling separators") {
        let template = try RenameTemplate.parse("{author? {author} - }{title} {year? ({year})}.{ext}")
        var book = dune
        book.authors = []
        book.year = nil
        let result = template.render(book: book, fileExtension: "epub")
        expectEqual(result.name, "Dune.epub")
    }

    await runner.run("template: sanitization strips illegal chars and truncates UTF-8 safely") {
        let template = try RenameTemplate.parse("{title}.{ext}")
        var nasty = dune
        nasty.title = "Dune: The/Sequel"
        let cleaned = template.render(book: nasty, fileExtension: "epub")
        expectEqual(cleaned.name, "Dune The Sequel.epub")

        var persian = dune
        persian.title = String(repeating: "کتابخانه", count: 40) // 8 chars ×2 bytes… way over 255 bytes
        let truncated = template.render(book: persian, fileExtension: "epub")
        guard let name = truncated.name else {
            expect(false, "truncated render must still produce a name")
            return
        }
        expect(name.utf8.count <= 255, "must fit in 255 UTF-8 bytes, got \(name.utf8.count)")
        expect(name.hasSuffix(".epub"), "extension must survive truncation")
        expect(!name.contains("\u{FFFD}"), "no broken characters")
    }

    await runner.run("template: parse errors on unknown token and unbalanced braces") {
        expectThrows("unknown token") { _ = try RenameTemplate.parse("{nope}") }
        expectThrows("unbalanced") { _ = try RenameTemplate.parse("{title") }
        expectThrows("stray close") { _ = try RenameTemplate.parse("title}") }
    }

    await runner.run("planner: multi-format book renames consistently, collisions suffixed") {
        try await withTempDirectory { dir in
            for name in ["dune_scan.epub", "dune_scan.pdf", "Frank Herbert - Dune.mobi"] {
                try "x".data(using: .utf8)!.write(to: dir.appendingPathComponent(name))
            }
            var book = dune
            book.id = 7
            let files = [
                BookFile(id: 1, bookId: 7, path: dir.appendingPathComponent("dune_scan.epub").path,
                         format: .epub, sizeBytes: 1, modifiedAt: Date()),
                BookFile(id: 2, bookId: 7, path: dir.appendingPathComponent("dune_scan.pdf").path,
                         format: .pdf, sizeBytes: 1, modifiedAt: Date()),
                BookFile(id: 3, bookId: 7, path: dir.appendingPathComponent("Frank Herbert - Dune.mobi").path,
                         format: .mobi, sizeBytes: 1, modifiedAt: Date()),
            ]
            let template = try RenameTemplate.parse(RenameTemplate.defaultRaw)
            let plan = RenamePlanner.plan(items: [(book, files)], template: template)

            expectEqual(plan.count, 3)
            expectEqual(plan[0].proposedName, "Frank Herbert - Dune.epub")
            expectEqual(plan[1].proposedName, "Frank Herbert - Dune.pdf")
            expectEqual(plan[2].status, .noOp, "already-correct name is a no-op")
            expectEqual(plan[2].included, false)
        }
    }

    await runner.run("planner: collision with existing disk file gets (2) suffix") {
        try await withTempDirectory { dir in
            try "x".data(using: .utf8)!.write(to: dir.appendingPathComponent("old_name.epub"))
            try "y".data(using: .utf8)!.write(to: dir.appendingPathComponent("Frank Herbert - Dune.epub"))

            var book = dune
            book.id = 7
            let files = [BookFile(id: 1, bookId: 7,
                                  path: dir.appendingPathComponent("old_name.epub").path,
                                  format: .epub, sizeBytes: 1, modifiedAt: Date())]
            let template = try RenameTemplate.parse(RenameTemplate.defaultRaw)
            let plan = RenamePlanner.plan(items: [(book, files)], template: template)

            expectEqual(plan[0].proposedName, "Frank Herbert - Dune (2).epub")
            expectEqual(plan[0].status, .collisionResolved)
        }
    }

    await runner.run("planner: case-only rename is not a collision") {
        try await withTempDirectory { dir in
            // On case-insensitive APFS the target "exists" — it's the file
            // itself, so no "(2)" suffix may be added.
            try "x".data(using: .utf8)!.write(to: dir.appendingPathComponent("frank herbert - dune.epub"))

            var book = dune
            book.id = 7
            let files = [BookFile(id: 1, bookId: 7,
                                  path: dir.appendingPathComponent("frank herbert - dune.epub").path,
                                  format: .epub, sizeBytes: 1, modifiedAt: Date())]
            let template = try RenameTemplate.parse(RenameTemplate.defaultRaw)
            let plan = RenamePlanner.plan(items: [(book, files)], template: template)

            expectEqual(plan[0].proposedName, "Frank Herbert - Dune.epub",
                        "capitalization fix must not get a (2) suffix")
            expectEqual(plan[0].status, .ready)
        }
    }

    await runner.run("executor: renames, updates database, journals, and undoes fully") {
        try await withTempDirectory { dir in
            let database = try AppDatabase.inMemory()
            var bookIds: [Int64] = []
            var allFiles: [(Book, [BookFile])] = []
            for (index, title) in ["Dune", "Hyperion"].enumerated() {
                let oldName = "scan_\(index).epub"
                let url = dir.appendingPathComponent(oldName)
                try "content-\(index)".data(using: .utf8)!.write(to: url)
                let (book, file) = try await database.writer.write { db -> (Book, BookFile) in
                    var b = Book(title: title, authors: ["Author \(index)"])
                    try b.insert(db)
                    var f = BookFile(bookId: b.id!, path: url.path, format: .epub,
                                     sizeBytes: 10, modifiedAt: Date())
                    try f.insert(db)
                    return (b, f)
                }
                bookIds.append(book.id!)
                allFiles.append((book, [file]))
            }

            let template = try RenameTemplate.parse(RenameTemplate.defaultRaw)
            let plan = RenamePlanner.plan(items: allFiles, template: template)
            let result = try await RenameExecutor.execute(plan: plan, database: database)

            expectEqual(result.renamed, 2)
            expect(result.failures.isEmpty, "no failures expected: \(result.failures)")
            expect(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Author 0 - Dune.epub").path))
            expect(!FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("scan_0.epub").path))
            let paths = try await database.writer.read { db in
                try BookFile.fetchAll(db).map(\.path).sorted()
            }
            expect(paths.allSatisfy { $0.contains(" - ") }, "database paths must be updated")

            // Undo restores everything (journal survives "restart" — it's in the DB).
            let undoable = try await RenameExecutor.lastUndoableBatch(database: database)
            expectEqual(undoable?.entries, 2)
            let restored = try await RenameExecutor.undoLastBatch(database: database)
            expectEqual(restored, 2)
            expect(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("scan_0.epub").path))
            expect(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("scan_1.epub").path))
            let restoredPaths = try await database.writer.read { db in
                try BookFile.fetchAll(db).map(\.path).sorted()
            }
            expect(restoredPaths.allSatisfy { $0.contains("scan_") },
                   "database paths must be restored")
            let secondUndo = try await RenameExecutor.undoLastBatch(database: database)
            expectEqual(secondUndo, 0, "reverted batch cannot be undone twice")
        }
    }

    await runner.run("executor: excluded and no-op rows are skipped") {
        try await withTempDirectory { dir in
            let database = try AppDatabase.inMemory()
            let url = dir.appendingPathComponent("keep_me.epub")
            try "x".data(using: .utf8)!.write(to: url)
            let (book, file) = try await database.writer.write { db -> (Book, BookFile) in
                var b = Book(title: "Dune", authors: ["Frank Herbert"])
                try b.insert(db)
                var f = BookFile(bookId: b.id!, path: url.path, format: .epub,
                                 sizeBytes: 1, modifiedAt: Date())
                try f.insert(db)
                return (b, f)
            }
            let template = try RenameTemplate.parse(RenameTemplate.defaultRaw)
            var plan = RenamePlanner.plan(items: [(book, [file])], template: template)
            plan[0].included = false  // user unchecked the row

            let result = try await RenameExecutor.execute(plan: plan, database: database)
            expectEqual(result.renamed, 0)
            expectEqual(result.skipped, 1)
            expect(FileManager.default.fileExists(atPath: url.path), "file untouched")
        }
    }
}
