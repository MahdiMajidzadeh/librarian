import Foundation
import GRDB
import BookShelfKit

private func makeFile(_ dir: URL, _ name: String, _ contents: String = "data") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.data(using: .utf8)!.write(to: url)
    return url
}

func scannerTests(_ runner: TestRunner) async {
    await runner.run("scan discovers nested files, skips hidden and unknown extensions") {
        try await withTempDirectory { dir in
            _ = try makeFile(dir, "dune.epub")
            _ = try makeFile(dir, "sub/deep/hobbit.pdf")
            _ = try makeFile(dir, ".hidden.epub")
            _ = try makeFile(dir, "notes.docx")
            _ = try makeFile(dir, "ignore-me.txt")

            let db = try AppDatabase.inMemory()
            let scanner = LibraryScanner(database: db)
            let result = try await scanner.scan(root: dir, ignoredExtensions: ["txt"])

            expectEqual(result.added, 2)
            let paths = try await db.writer.read { db in
                try BookFile.fetchAll(db).map(\.path).sorted()
            }
            expect(paths.contains(where: { $0.hasSuffix("dune.epub") }), "epub missing")
            expect(paths.contains(where: { $0.hasSuffix("hobbit.pdf") }), "nested pdf missing")
            expectEqual(paths.count, 2)
        }
    }

    await runner.run("rescan with no changes touches nothing") {
        try await withTempDirectory { dir in
            _ = try makeFile(dir, "a.epub")
            _ = try makeFile(dir, "b.pdf")

            let db = try AppDatabase.inMemory()
            let scanner = LibraryScanner(database: db)
            _ = try await scanner.scan(root: dir)
            let second = try await scanner.scan(root: dir)

            expectEqual(second.added, 0)
            expectEqual(second.updated, 0)
            expectEqual(second.unchanged, 2)
            expectEqual(second.missing, 0)
            let bookCount = try await db.writer.read { try Book.fetchCount($0) }
            expectEqual(bookCount, 2, "rescan must not duplicate books")
        }
    }

    await runner.run("changed file is updated, not duplicated") {
        try await withTempDirectory { dir in
            let url = try makeFile(dir, "a.epub", "v1")
            let db = try AppDatabase.inMemory()
            let scanner = LibraryScanner(database: db)
            _ = try await scanner.scan(root: dir)

            try "version two, longer".data(using: .utf8)!.write(to: url)
            // Ensure mtime moves even on coarse filesystems.
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)

            let second = try await scanner.scan(root: dir)
            expectEqual(second.updated, 1)
            expectEqual(second.added, 0)
            let files = try await db.writer.read { try BookFile.fetchAll($0) }
            expectEqual(files.count, 1)
            expectEqual(files.first?.sizeBytes, Int64("version two, longer".utf8.count))
        }
    }

    await runner.run("deleted file is marked missing, rediscovered on return, purge removes it") {
        try await withTempDirectory { dir in
            let url = try makeFile(dir, "gone.epub")
            let db = try AppDatabase.inMemory()
            let scanner = LibraryScanner(database: db)
            _ = try await scanner.scan(root: dir)

            let contents = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            let afterDelete = try await scanner.scan(root: dir)
            expectEqual(afterDelete.missing, 1)
            var file = try await db.writer.read { try BookFile.fetchOne($0) }
            expectEqual(file?.missingFlag, true, "should be flagged, not removed")

            // File comes back with identical content → flag clears.
            try contents.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: file!.modifiedAt], ofItemAtPath: url.path)
            let afterReturn = try await scanner.scan(root: dir)
            expectEqual(afterReturn.rediscovered, 1)
            file = try await db.writer.read { try BookFile.fetchOne($0) }
            expectEqual(file?.missingFlag, false)

            // Delete again and purge explicitly.
            try FileManager.default.removeItem(at: url)
            _ = try await scanner.scan(root: dir)
            let purged = try await scanner.purgeMissing()
            expectEqual(purged, 1)
            let books = try await db.writer.read { try Book.fetchCount($0) }
            expectEqual(books, 0, "orphaned book should be removed by purge")
        }
    }

    await runner.run("progress reports enumerating, processing, finished") {
        try await withTempDirectory { dir in
            for i in 0..<5 {
                _ = try makeFile(dir, "book\(i).epub")
            }
            let db = try AppDatabase.inMemory()
            let scanner = LibraryScanner(database: db)

            final class Box: @unchecked Sendable {
                var events: [ScanProgress] = []
                let lock = NSLock()
                func add(_ p: ScanProgress) { lock.lock(); events.append(p); lock.unlock() }
            }
            let box = Box()
            _ = try await scanner.scan(root: dir) { box.add($0) }

            expectEqual(box.events.first?.phase, .enumerating)
            expectEqual(box.events.last?.phase, .finished)
            expectEqual(box.events.last?.processed, 5)
            expectEqual(box.events.last?.total, 5)
        }
    }

    await runner.run("default assigner: one book per filename stem when grouping is off") {
        try await withTempDirectory { dir in
            _ = try makeFile(dir, "Frank Herbert - Dune.epub")
            _ = try makeFile(dir, "hyperion.pdf")

            let db = try AppDatabase.inMemory()
            let scanner = LibraryScanner(database: db)   // no assignBook injected
            _ = try await scanner.scan(root: dir)

            let books = try await db.writer.read { try Book.fetchAll($0) }
            expectEqual(books.count, 2, "every file gets its own book")
            expect(books.contains { $0.title == "Frank Herbert - Dune" },
                   "fallback title is the raw stem, got \(books.map(\.title))")
            expect(books.allSatisfy { $0.groupMethod == .single })
        }
    }

    await runner.run("folder access: persist/restore round-trip, nil when the folder vanishes") {
        try await withTempDirectory { dir in
            let db = try AppDatabase.inMemory()
            let folder = dir.appendingPathComponent("library", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            try FolderAccess.persist(url: folder, in: db)
            let restored = try FolderAccess.restore(from: db)
            expectEqual(restored?.standardizedFileURL.path, folder.standardizedFileURL.path)

            // Folder gone → nil so the UI can re-prompt (§9).
            try FileManager.default.removeItem(at: folder)
            expectNil(try FolderAccess.restore(from: db), "missing folder must not restore")

            // Nothing persisted at all → nil.
            let fresh = try AppDatabase.inMemory()
            expectNil(try FolderAccess.restore(from: fresh))
        }
    }

    await runner.run("metadata status thresholds: complete needs title+author+year+cover") {
        var book = Book(title: "Dune", authors: ["Frank Herbert"], year: 1965)
        book.coverCachePath = "/covers/1.jpg"
        expectEqual(ScanPipeline.status(for: book), .complete)

        book.coverCachePath = nil
        expectEqual(ScanPipeline.status(for: book), .partial, "missing cover downgrades")

        let coreOnly = Book(title: "Dune", authors: ["Frank Herbert"])
        expectEqual(ScanPipeline.status(for: coreOnly), .partial)

        var yearOnly = Book(title: "", authors: [])
        yearOnly.year = 1965
        expectEqual(ScanPipeline.status(for: yearOnly), .partial, "any single field is partial")

        expectEqual(ScanPipeline.status(for: Book(title: "", authors: [])), .unresolved)
    }
}
