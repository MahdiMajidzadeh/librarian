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
            },
            applyChanged: { db, existing, prepared in
                // A file overwritten in place keeps its book; refresh the
                // book from the re-parsed content (fill-empty semantics).
                try Self.applyEmbedded(db, bookId: existing.bookId, prepared: prepared, coverCache: coverCache)
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
            // Junk embedded titles ("0071501126.pdf", bare ISBNs) stored by
            // older versions: reset to the filename-derived title and drop
            // the stale provenance so re-extract repairs the row. Manual and
            // online titles have a different source and are untouched.
            let titleSource = (try? provenanceSource(db, bookId: bookId, field: "title")) ?? nil
            if titleSource == .embedded, EmbeddedMetadata.isJunkTitle(book.title) {
                let inferred = GroupingEngine.inferTitleAuthors(fromStem: prepared.seed.rawStem)
                book.title = inferred.title
                book.titleSort = Book.sortKey(forTitle: inferred.title)
                try ProvenanceRecord
                    .filter(ProvenanceRecord.Columns.bookId == bookId)
                    .filter(ProvenanceRecord.Columns.field == "title")
                    .deleteAll(db)
            }
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
            // Tags: embedded keyword fields (PDF "Keywords", dc:subject,
            // EXTH 105) are too noisy to trust, so they are never applied —
            // tags come only from online lookup or manual edits. Rows that
            // still carry embedded tags from older versions are cleared here.
            let tagSource = (try? provenanceSource(db, bookId: bookId, field: "tags")) ?? nil
            if tagSource == .embedded {
                book.tags = []
                try ProvenanceRecord
                    .filter(ProvenanceRecord.Columns.bookId == bookId)
                    .filter(ProvenanceRecord.Columns.field == "tags")
                    .deleteAll(db)
            }
            // Cover quality ranking: a real embedded cover (epub/mobi/azw3)
            // replaces a PDF first-page render, never the other way round.
            // Manual and online covers outrank any embedded cover (FR-3.2).
            let coverSource = (try? provenanceSource(db, bookId: bookId, field: "cover")) ?? nil
            if let coverData = meta.coverData,
               coverSource == nil || coverSource == .embedded {
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

    // MARK: - Rebuild auto-groups

    public struct RegroupSummary: Sendable, Equatable {
        public var groupsKept = 0
        public var booksRebuilt = 0
        public var booksDissolved = 0
        public init() {}
    }

    /// Re-partitions all automatically grouped files from scratch with the
    /// current grouping rules — the recovery path after a grouping-rule fix,
    /// since rescans never revisit known files.
    ///
    /// Manual merges/splits are untouched. A group whose file set comes out
    /// identical keeps its existing book row (metadata, edits, provenance).
    /// Only changed groups are rebuilt from embedded metadata.
    public func rebuildGroups(
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RegroupSummary {
        let (allBooks, allFiles) = try await database.writer.read { db in
            (try Book.fetchAll(db), try BookFile.fetchAll(db))
        }
        let manualIds = Set(allBooks.filter(\.manualGroup).compactMap(\.id))
        let autoFiles = allFiles
            .filter { !manualIds.contains($0.bookId) }
            .sorted { $0.path < $1.path }

        // Parse embedded metadata off-transaction.
        var preparedByFile: [Int64: PreparedFile] = [:]
        var processed = 0
        for file in autoFiles {
            let url = URL(fileURLWithPath: file.path)
            var seed = GroupingSeed.fromFilename(url)
            var metadata: EmbeddedMetadata?
            if !file.missingFlag, file.format.supportsEmbeddedMetadata,
               case .success(let meta)? = MetadataExtractor.extract(url: url, format: file.format) {
                seed.isbn = meta.isbn
                if let title = meta.title, !title.isEmpty {
                    seed.title = title
                }
                seed.authors = meta.authors
                metadata = meta
            }
            let scanned = ScannedFile(url: url, format: file.format,
                                      sizeBytes: file.sizeBytes, modifiedAt: file.modifiedAt)
            preparedByFile[file.id!] = PreparedFile(file: scanned, seed: seed, metadata: metadata)
            processed += 1
            onProgress?(processed, autoFiles.count)
        }

        // Partition with a fresh engine over synthetic group ids.
        let engine = GroupingEngine()
        var groups: [Int64: [BookFile]] = [:]
        var groupMethods: [Int64: GroupMethod] = [:]
        var nextGroupId: Int64 = 1
        for file in autoFiles {
            guard let prepared = preparedByFile[file.id!] else { continue }
            let seed = prepared.seed
            let groupId: Int64
            switch engine.decide(seed) {
            case .join(let id, let method):
                groupId = id
                let current = groupMethods[groupId] ?? .single
                if GroupingEngine.methodRank(method) > GroupingEngine.methodRank(current) {
                    groupMethods[groupId] = method
                }
            case .createNew:
                groupId = nextGroupId
                nextGroupId += 1
                groupMethods[groupId] = .single
            }
            engine.register(bookId: groupId, isbn: seed.isbn, title: seed.title,
                            authors: seed.authors, stems: [seed.rawStem])
            groups[groupId, default: []].append(file)
        }

        // Groups identical to an existing book keep that book untouched.
        var oldSets: [Int64: Set<Int64>] = [:]
        for (bookId, files) in Dictionary(grouping: autoFiles, by: \.bookId) {
            oldSets[bookId] = Set(files.compactMap(\.id))
        }
        var keptOldBooks = Set<Int64>()
        var changedGroups: [(files: [BookFile], method: GroupMethod)] = []
        var kept = 0
        for (groupId, group) in groups {
            let ids = Set(group.compactMap(\.id))
            if let match = oldSets.first(where: { $0.value == ids && !keptOldBooks.contains($0.key) }) {
                keptOldBooks.insert(match.key)
                kept += 1
            } else {
                changedGroups.append((group, groupMethods[groupId] ?? .single))
            }
        }

        let coverCache = self.coverCache
        let plan = changedGroups
        let preserved = keptOldBooks
        let prepared = preparedByFile
        let oldAutoBookIds = Set(oldSets.keys)
        let capturedOldSets = oldSets

        var summary = try await database.writer.write { db -> RegroupSummary in
            var result = RegroupSummary()
            // Books holding manual edits or online-resolved metadata must
            // survive a rebuild — "resolved metadata is never discarded".
            let protectedIds = Set(try ProvenanceRecord.fetchAll(db)
                .filter { $0.source == .manual || $0.source == .openLibrary || $0.source == .googleBooks }
                .map(\.bookId))
            var claimed = preserved
            for (group, method) in plan {
                let fileIds = Set(group.compactMap(\.id))
                // Reuse the old book with the largest file overlap when it
                // carries protected metadata; otherwise build fresh.
                let reusable = capturedOldSets
                    .filter { protectedIds.contains($0.key) && !claimed.contains($0.key) }
                    .map { (id: $0.key, overlap: $0.value.intersection(fileIds).count) }
                    .filter { $0.overlap > 0 }
                    .max { ($0.overlap, $1.id) < ($1.overlap, $0.id) }
                let bookId: Int64
                if let reuse = reusable {
                    claimed.insert(reuse.id)
                    bookId = reuse.id
                } else {
                    // Seed the new book from the group's best reading, then
                    // let each file's embedded metadata fill it in as during
                    // a scan.
                    let firstSeed = prepared[group[0].id!]?.seed
                        ?? .fromFilename(URL(fileURLWithPath: group[0].path))
                    bookId = try GroupingEngine().assignBook(db, seed: firstSeed)
                }
                for var file in group {
                    file.bookId = bookId
                    try file.update(db)
                    if let preparedFile = prepared[file.id!] {
                        try Self.applyEmbedded(db, bookId: bookId, prepared: preparedFile,
                                               coverCache: coverCache)
                    }
                }
                if group.count > 1, var book = try Book.fetchOne(db, key: bookId) {
                    book.groupMethod = method
                    try book.update(db)
                }
                result.booksRebuilt += 1
            }
            // Old auto books that lost all their files disappear.
            for bookId in oldAutoBookIds where !preserved.contains(bookId) {
                let remaining = try BookFile
                    .filter(BookFile.Columns.bookId == bookId)
                    .fetchCount(db)
                if remaining == 0 {
                    _ = try Book.deleteOne(db, key: bookId)
                    result.booksDissolved += 1
                }
            }
            return result
        }
        summary.groupsKept = kept
        return summary
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
