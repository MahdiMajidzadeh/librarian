import Foundation
import GRDB

/// The full scan flow: enumerate → parse embedded metadata (off-transaction)
/// → group → apply metadata with provenance → cache covers.
public final class ScanPipeline: Sendable {
    private let database: AppDatabase
    private let coverCache: CoverCache

    public init(database: AppDatabase, coverCache: CoverCache) {
        self.database = database
        self.coverCache = coverCache
    }

    @discardableResult
    public func scan(
        root: URL,
        ignoredExtensions: Set<String> = [],
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        let engine = try await database.writer.read { try GroupingEngine.load($0) }
        let coverCache = self.coverCache

        let scanner = LibraryScanner(
            database: database,
            prepare: { file in
                var seed = GroupingSeed.fromFilename(file.url)
                switch MetadataExtractor.extract(url: file.url, format: file.format) {
                case .success(let meta)?:
                    seed.isbn = meta.isbn
                    if let title = meta.title, !title.isEmpty {
                        seed.title = title
                    }
                    seed.authors = meta.authors
                    return PreparedFile(file: file, seed: seed, metadata: meta)
                case .failure(let error)?:
                    return PreparedFile(file: file, seed: seed, parseErrorNote: error.note)
                case nil:
                    return PreparedFile(file: file, seed: seed)
                }
            },
            assignBook: { db, prepared in
                let bookId = try engine.assignBook(db, seed: prepared.seed)
                try Self.applyEmbedded(db, bookId: bookId, prepared: prepared, coverCache: coverCache)
                return bookId
            }
        )
        return try await scanner.scan(
            root: root, ignoredExtensions: ignoredExtensions, onProgress: onProgress)
    }

    /// Fills empty fields from embedded metadata (embedded never overwrites
    /// existing values — FR-3.2 default), records provenance, stores the
    /// cover, and refreshes the book's status.
    static func applyEmbedded(
        _ db: Database, bookId: Int64, prepared: PreparedFile, coverCache: CoverCache
    ) throws {
        guard var book = try Book.fetchOne(db, key: bookId) else { return }
        var touchedFields: [String] = []

        if let meta = prepared.metadata {
            if let title = meta.title, !title.isEmpty, isFilenamePlaceholder(book, db: db) {
                book.title = title
                book.titleSort = Book.sortKey(forTitle: title)
                touchedFields.append("title")
            }
            if book.authors.isEmpty, !meta.authors.isEmpty {
                book.authors = meta.authors
                book.authorSort = Book.sortKey(forAuthors: meta.authors)
                touchedFields.append("authors")
            }
            if book.publisher == nil, let publisher = meta.publisher {
                book.publisher = publisher
                touchedFields.append("publisher")
            }
            if book.language == nil, let language = meta.language {
                book.language = language
                touchedFields.append("language")
            }
            if book.year == nil, let year = meta.year {
                book.year = year
                touchedFields.append("year")
            }
            if book.bookDescription == nil, let description = meta.description {
                book.bookDescription = description
                touchedFields.append("description")
            }
            if book.isbn13 == nil, book.isbn10 == nil,
               let raw = meta.isbn, let isbn = Normalizer.extractISBN(raw) {
                if isbn.count == 13 { book.isbn13 = isbn } else { book.isbn10 = isbn }
                touchedFields.append("isbn")
            }
            // Tags: sanitize incoming keywords, and also repair previously
            // stored prose-tags (unless the user set them manually).
            let incomingTags = TagSanitizer.sanitize(meta.subjects)
            let tagsAreManual = (try? provenanceSource(db, bookId: bookId, field: "tags")) == .manual
            if !tagsAreManual {
                if !incomingTags.isEmpty, book.tags.isEmpty || !TagSanitizer.isValid(book.tags) {
                    book.tags = incomingTags
                    touchedFields.append("tags")
                } else if !TagSanitizer.isValid(book.tags) {
                    book.tags = TagSanitizer.sanitize(book.tags)
                }
            }
            // Cover quality ranking: a real embedded cover (epub/mobi/azw3)
            // replaces a PDF first-page render, never the other way round.
            if let coverData = meta.coverData {
                let incoming = coverRank(prepared.file.format)
                let existing = book.coverCachePath == nil ? 0 : coverRank(book.coverSourceFormat)
                if incoming > existing,
                   let gridURL = try? coverCache.store(imageData: coverData, bookId: bookId) {
                    book.coverCachePath = gridURL.path
                    book.coverSourceFormat = prepared.file.format
                    touchedFields.append("cover")
                }
            }
        }

        if let note = prepared.parseErrorNote, book.parseErrorNote == nil {
            book.parseErrorNote = note
        }

        book.metadataStatus = status(for: book)
        book.updatedAt = Date()
        try book.update(db)

        for field in touchedFields {
            try ProvenanceRecord(bookId: bookId, field: field, source: .embedded).save(db)
        }
    }

    /// Higher = better cover source. PDF covers are first-page renders, so
    /// any true embedded cover outranks them. Unknown (pre-v2 rows) ranks
    /// with PDF so a real embedded cover can still take over.
    private static func coverRank(_ format: BookFormat?) -> Int {
        switch format {
        case .epub, .mobi, .azw3: return 2
        case .pdf, nil: return 1
        default: return 1
        }
    }

    /// Re-runs embedded metadata extraction over every known, present file —
    /// used after parser/ranking improvements, since incremental rescans skip
    /// unchanged files. Fill-empty semantics: manual and online data survive;
    /// only empty fields and lower-ranked covers change.
    @discardableResult
    public func reextractEmbedded(
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Int {
        let files = try await database.writer.read { db in
            try BookFile
                .filter(BookFile.Columns.missingFlag == false)
                .fetchAll(db)
        }
        let parseable = files.filter { $0.format.supportsEmbeddedMetadata }
        let coverCache = self.coverCache

        var processed = 0
        for file in parseable {
            let url = URL(fileURLWithPath: file.path)
            guard case .success(let meta)? = MetadataExtractor.extract(url: url, format: file.format) else {
                processed += 1
                onProgress?(processed, parseable.count)
                continue
            }
            let prepared = PreparedFile(
                file: ScannedFile(url: url, format: file.format,
                                  sizeBytes: file.sizeBytes, modifiedAt: file.modifiedAt),
                seed: .fromFilename(url),
                metadata: meta)
            let bookId = file.bookId
            try await database.writer.write { db in
                try Self.applyEmbedded(db, bookId: bookId, prepared: prepared, coverCache: coverCache)
            }
            processed += 1
            onProgress?(processed, parseable.count)
        }
        return parseable.count
    }

    private static func provenanceSource(
        _ db: Database, bookId: Int64, field: String
    ) throws -> ProvenanceSource? {
        try ProvenanceRecord
            .filter(ProvenanceRecord.Columns.bookId == bookId)
            .filter(ProvenanceRecord.Columns.field == field)
            .fetchOne(db)?
            .source
    }

    /// True when the book's title still looks like it came from a filename
    /// (no provenance recorded for "title" yet).
    private static func isFilenamePlaceholder(_ book: Book, db: Database) -> Bool {
        guard let bookId = book.id else { return true }
        let existing = try? ProvenanceRecord
            .filter(ProvenanceRecord.Columns.bookId == bookId)
            .filter(ProvenanceRecord.Columns.field == "title")
            .fetchOne(db)
        return existing == nil
    }

    public static func status(for book: Book) -> MetadataStatus {
        let hasCore = !book.title.isEmpty && !book.authors.isEmpty
        let hasRich = book.year != nil && book.coverCachePath != nil
        if hasCore && hasRich { return .complete }
        if hasCore || book.year != nil || book.coverCachePath != nil { return .partial }
        return .unresolved
    }
}
