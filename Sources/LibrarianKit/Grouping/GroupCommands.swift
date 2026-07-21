import Foundation
import GRDB

/// User-driven grouping operations (FR-2.4): merge books, ungroup a book,
/// and pick a book's cover from any file in its group. Manual decisions are
/// stored as `manualGroupId` tokens on files, so they persist across rescans
/// and take precedence over automatic grouping.
public struct GroupCommands: Sendable {
    private let database: AppDatabase
    private let coverCache: CoverCache

    public init(database: AppDatabase, coverCache: CoverCache) {
        self.database = database
        self.coverCache = coverCache
    }

    // MARK: - Merge

    /// Merges the given books into one. The first book (by completeness, then
    /// id) survives; empty fields are filled from the others; all files get a
    /// shared manual token. Returns the surviving book id.
    @discardableResult
    public func merge(bookIds: [Int64]) throws -> Int64 {
        precondition(bookIds.count >= 2, "merge needs at least two books")
        let token = "manual-\(UUID().uuidString)"

        return try database.writer.write { db in
            var books = try Book.filter(keys: bookIds).fetchAll(db)
            guard books.count >= 2 else {
                throw GroupError.booksNotFound
            }
            // Survivor: most complete metadata, then oldest id.
            books.sort { a, b in
                let ra = Self.completeness(a), rb = Self.completeness(b)
                if ra != rb { return ra > rb }
                return (a.id ?? 0) < (b.id ?? 0)
            }
            var survivor = books[0]
            let survivorId = survivor.id!

            for other in books.dropFirst() {
                Self.fillEmpty(&survivor, from: other)
            }
            survivor.groupMethod = .manual
            survivor.refreshMetadataStatus()
            survivor.updatedAt = Date()
            try survivor.save(db)

            try db.execute(
                sql: """
                    UPDATE bookFile SET bookId = ?, manualGroupId = ?
                    WHERE bookId IN (\(bookIds.map { String($0) }.joined(separator: ",")))
                    """,
                arguments: [survivorId, token])

            // Absorbed books lose their files and disappear.
            try self.database.deleteOrphanBooks(db)
            return survivorId
        }
    }

    // MARK: - Ungroup / split

    /// Splits a book so every file becomes its own book (FR-2.4). Each file
    /// receives a unique manual token, so automatic grouping never re-merges
    /// them. The original book keeps its first file and all its metadata;
    /// every new book is seeded from its file's own embedded metadata and
    /// cover, so it shows a proper title and cover immediately.
    /// Returns the ids of all resulting books.
    @discardableResult
    public func ungroup(bookId: Int64) throws -> [Int64] {
        let files = try database.writer.read { db in
            try BookFile
                .filter(Column("bookId") == bookId)
                .order(Column("path"))
                .fetchAll(db)
        }
        guard files.count >= 2 else { return [bookId] }
        // Parse embedded metadata/covers outside the write transaction.
        let seeds = files.map(FileSeed.init(file:))

        var pendingCovers: [(bookId: Int64, data: Data)] = []
        let resultIds: [Int64] = try database.writer.write { db in
            guard var original = try Book.fetchOne(db, key: bookId) else {
                throw GroupError.booksNotFound
            }
            var resultIds: [Int64] = [bookId]

            for (index, file) in files.enumerated() {
                var row = try BookFile.fetchOne(db, key: file.id!) ?? file
                row.manualGroupId = "manual-\(UUID().uuidString)"
                if index == 0 {
                    try row.save(db)
                    continue
                }
                let newId = try Self.insertBook(from: seeds[index], db: db)
                if let cover = seeds[index].extraction?.metadata.coverData {
                    pendingCovers.append((newId, cover))
                }
                row.bookId = newId
                try row.save(db)
                resultIds.append(newId)
            }

            original.groupMethod = .manual
            original.updatedAt = Date()
            try original.save(db)
            return resultIds
        }
        try applyCovers(pendingCovers)
        return resultIds
    }

    /// Splits ONE file out of its group into its own book (FR-2.4): the file
    /// gets a unique manual token so it never re-merges automatically, and
    /// its new book is seeded from the file's embedded metadata and cover.
    /// The rest of the group is untouched. Returns the new book's id.
    @discardableResult
    public func split(fileId: Int64) throws -> Int64 {
        guard let file = try database.writer.read({ db in
            try BookFile.fetchOne(db, key: fileId)
        }) else {
            throw GroupError.booksNotFound
        }
        let siblingCount = try database.writer.read { db in
            try BookFile.filter(Column("bookId") == file.bookId).fetchCount(db)
        }
        guard siblingCount >= 2 else { return file.bookId }

        let seed = FileSeed(file: file)
        var pendingCovers: [(bookId: Int64, data: Data)] = []
        let newId: Int64 = try database.writer.write { db in
            let newId = try Self.insertBook(from: seed, db: db)
            if let cover = seed.extraction?.metadata.coverData {
                pendingCovers.append((newId, cover))
            }
            var row = try BookFile.fetchOne(db, key: fileId) ?? file
            row.bookId = newId
            row.manualGroupId = "manual-\(UUID().uuidString)"
            try row.save(db)
            try self.database.deleteOrphanBooks(db)
            return newId
        }
        try applyCovers(pendingCovers)
        return newId
    }

    // MARK: - Seeding new books from a file

    /// Everything needed to give a split-out file a proper book identity:
    /// its embedded metadata (when the file is readable) plus the filename
    /// guess as fallback.
    struct FileSeed {
        var extraction: MetadataExtractor.Result?
        var guess: FilenameInference.Guess

        init(file: BookFile) {
            let stem = (file.filename as NSString).deletingPathExtension
            guess = FilenameInference.guess(fromStem: stem)
            if !file.missingFlag, FileManager.default.fileExists(atPath: file.path) {
                extraction = MetadataExtractor.extract(url: file.url, format: file.format)
            }
        }
    }

    /// Inserts a book built from the seed and records field provenance.
    private static func insertBook(from seed: FileSeed, db: Database) throws -> Int64 {
        let m = seed.extraction?.metadata ?? BookMetadata()
        var book = Book(
            title: m.title ?? seed.guess.title,
            authors: !m.authors.isEmpty
                ? m.authors
                : (seed.guess.author.map { [$0] } ?? []))
        book.series = m.series
        book.seriesIndex = m.seriesIndex
        book.publisher = m.publisher
        book.year = m.year
        book.language = m.language
        book.isbn10 = m.isbn10
        book.isbn13 = m.isbn13
        book.bookDescription = m.description
        book.groupMethod = .manual
        book.parseErrorNote = seed.extraction?.parseErrorNote
        book.refreshMetadataStatus()
        try book.insert(db)
        let bookId = book.id!

        try Provenance(
            bookId: bookId, field: "title",
            source: m.title != nil ? .embedded : .filename).save(db)
        if !book.authors.isEmpty {
            try Provenance(
                bookId: bookId, field: "authors",
                source: !m.authors.isEmpty ? .embedded : .filename).save(db)
        }
        for field in m.populatedFields where !["title", "authors", "cover"].contains(field) {
            try Provenance(bookId: bookId, field: field, source: .embedded).save(db)
        }
        return bookId
    }

    /// Stores extracted covers and points the new books at them.
    private func applyCovers(_ pending: [(bookId: Int64, data: Data)]) throws {
        for (bookId, data) in pending {
            let path = try coverCache.store(data, forBookId: bookId)
            try database.writer.write { db in
                try db.execute(
                    sql: "UPDATE book SET coverCachePath = ? WHERE id = ?",
                    arguments: [path, bookId])
                try Provenance(bookId: bookId, field: "cover", source: .embedded).save(db)
            }
        }
    }

    // MARK: - Covers

    /// Sets the book's cover from one of its files' embedded cover
    /// (user deviation: pick cover from any file in the group).
    /// Returns false when the file has no extractable cover.
    @discardableResult
    public func setCover(bookId: Int64, fromFile file: BookFile) throws -> Bool {
        let extraction = MetadataExtractor.extract(url: file.url, format: file.format)
        guard let data = extraction.metadata.coverData else { return false }
        try setCover(bookId: bookId, imageData: data)
        return true
    }

    /// Sets the book's cover from raw image data (FR-3.7 "replace from file").
    public func setCover(bookId: Int64, imageData: Data) throws {
        let path = try coverCache.store(imageData, forBookId: bookId)
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE book SET coverCachePath = ?, updatedAt = ? WHERE id = ?",
                arguments: [path, Date(), bookId])
            try Provenance(bookId: bookId, field: "cover", source: .manual).save(db)
        }
    }

    // MARK: - Helpers

    static func completeness(_ book: Book) -> Int {
        var score = 0
        if !book.authors.isEmpty { score += 2 }
        if book.year != nil { score += 1 }
        if book.isbn13 != nil || book.isbn10 != nil { score += 2 }
        if book.coverCachePath != nil { score += 1 }
        if book.bookDescription != nil { score += 1 }
        return score
    }

    static func fillEmpty(_ book: inout Book, from other: Book) {
        if book.authors.isEmpty, !other.authors.isEmpty {
            book.authors = other.authors
            book.authorSort = other.authorSort
        }
        if book.series == nil { book.series = other.series }
        if book.seriesIndex == nil { book.seriesIndex = other.seriesIndex }
        if book.publisher == nil { book.publisher = other.publisher }
        if book.year == nil { book.year = other.year }
        if book.language == nil { book.language = other.language }
        if book.isbn10 == nil { book.isbn10 = other.isbn10 }
        if book.isbn13 == nil { book.isbn13 = other.isbn13 }
        if book.bookDescription == nil { book.bookDescription = other.bookDescription }
        if book.coverCachePath == nil { book.coverCachePath = other.coverCachePath }
    }

    public enum GroupError: Error, LocalizedError {
        case booksNotFound

        public var errorDescription: String? { "Book(s) no longer exist" }
    }
}
