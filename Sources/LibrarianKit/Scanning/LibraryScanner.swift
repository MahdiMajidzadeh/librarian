import Foundation
import GRDB

/// Scan progress (FR-1.3): determinate, files processed / total.
public struct ScanProgress: Sendable, Equatable {
    public var processed: Int
    public var total: Int

    public init(processed: Int, total: Int) {
        self.processed = processed
        self.total = total
    }
}

/// Summary of one scan pass.
public struct ScanSummary: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var unchanged = 0
    public var markedMissing = 0
    public var totalFiles = 0
    public var duration: TimeInterval = 0
}

/// Scans the library folder (§6.1): recursive, skips hidden files and ignored
/// extensions, incremental by path + size + modification date. Previously
/// resolved metadata is never discarded by a rescan (FR-1.4); files gone from
/// disk are marked missing, not deleted (FR-1.5).
public final class LibraryScanner: Sendable {
    private let database: AppDatabase
    private let coverCache: CoverCache
    /// Test seam: runs after parsing, right before the reconciliation
    /// transaction — lets tests interleave user actions (merge/ungroup) with
    /// an in-flight scan.
    let beforeReconcileHook: (@Sendable () -> Void)?

    public convenience init(database: AppDatabase, coverCache: CoverCache) {
        self.init(database: database, coverCache: coverCache, beforeReconcileHook: nil)
    }

    init(
        database: AppDatabase,
        coverCache: CoverCache,
        beforeReconcileHook: (@Sendable () -> Void)?
    ) {
        self.database = database
        self.coverCache = coverCache
        self.beforeReconcileHook = beforeReconcileHook
    }

    // MARK: - Disk enumeration

    struct DiskFile: Sendable {
        var path: String
        var format: BookFormat
        var sizeBytes: Int64
        var modifiedAt: Date
    }

    /// Enumerates candidate book files under `root` (FR-1.2).
    static func enumerateFiles(root: URL, ignoredExtensions: Set<String>) -> [DiskFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var files: [DiskFile] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty,
                  !ignoredExtensions.contains(ext),
                  let format = BookFormat(rawValue: ext)
            else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            files.append(DiskFile(
                path: url.path,
                format: format,
                sizeBytes: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Scan

    public func scan(
        root: URL,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) throws -> ScanSummary {
        let start = Date()
        var summary = ScanSummary()

        let ignored = Set(
            (try database.setting(SettingKey.ignoreExtensions) ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty })

        let diskFiles = Self.enumerateFiles(root: root, ignoredExtensions: ignored)
        summary.totalFiles = diskFiles.count
        progress?(ScanProgress(processed: 0, total: diskFiles.count))

        let existing = try database.writer.read { db in
            try BookFile.fetchAll(db)
        }
        let existingByPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.path, $0) })
        let diskPaths = Set(diskFiles.map(\.path))

        // Classify: which disk files need a (re-)parse?
        struct ParsedFile {
            var disk: LibraryScanner.DiskFile
            var existing: BookFile?
            var extraction: MetadataExtractor.Result?   // nil → unchanged, keys reused
        }
        var parsedFiles: [ParsedFile] = []
        parsedFiles.reserveCapacity(diskFiles.count)

        var processed = 0
        for disk in diskFiles {
            let known = existingByPath[disk.path]
            let unchanged = known.map {
                $0.sizeBytes == disk.sizeBytes
                    && abs($0.modifiedAt.timeIntervalSince(disk.modifiedAt)) < 1
            } ?? false

            if unchanged {
                summary.unchanged += 1
                parsedFiles.append(ParsedFile(disk: disk, existing: known, extraction: nil))
            } else {
                let result = MetadataExtractor.extract(
                    url: URL(fileURLWithPath: disk.path), format: disk.format)
                if known == nil { summary.added += 1 } else { summary.updated += 1 }
                parsedFiles.append(ParsedFile(disk: disk, existing: known, extraction: result))
            }
            processed += 1
            progress?(ScanProgress(processed: processed, total: diskFiles.count))
        }

        var metadataByPath: [String: MetadataExtractor.Result] = [:]
        for parsed in parsedFiles {
            if let extraction = parsed.extraction {
                metadataByPath[parsed.disk.path] = extraction
            }
        }

        beforeReconcileHook?()

        // Identity building, grouping, and reconciliation all happen inside
        // ONE write transaction over freshly read rows. Grouping must see the
        // manual merge/ungroup tokens as they are NOW — parsing can take a
        // while, and a user decision committed mid-scan used to be reconciled
        // against the pre-scan snapshot, shuffling files into wrong books.
        struct PendingCover {
            var bookId: Int64
            var data: Data
        }
        var pendingCovers: [PendingCover] = []
        var markedMissing = 0

        try database.writer.write { db in
            let freshFiles = try BookFile.fetchAll(db)
            let freshByPath = Dictionary(uniqueKeysWithValues: freshFiles.map { ($0.path, $0) })

            // Identities for grouping: every on-disk file plus known missing
            // files (their book assignment must stay stable across rescans).
            var identities: [FileIdentity] = []
            for parsed in parsedFiles {
                let filename = (parsed.disk.path as NSString).lastPathComponent
                let stemNoExt = (filename as NSString).deletingPathExtension
                let fresh = freshByPath[parsed.disk.path] ?? parsed.existing
                if let extraction = parsed.extraction {
                    let m = extraction.metadata
                    identities.append(FileIdentity(
                        path: parsed.disk.path,
                        format: parsed.disk.format,
                        stem: stemNoExt,
                        isbn: m.isbn13 ?? m.isbn10,
                        titleKey: m.title.map(Normalizer.key),
                        authorKey: m.authors.isEmpty ? nil : Normalizer.authorSetKey(m.authors),
                        manualGroupId: fresh?.manualGroupId))
                } else if let known = fresh {
                    identities.append(FileIdentity(
                        path: parsed.disk.path,
                        format: parsed.disk.format,
                        stem: stemNoExt,
                        isbn: known.embeddedIsbn,
                        titleKey: known.embeddedTitleKey,
                        authorKey: known.embeddedAuthorKey,
                        manualGroupId: known.manualGroupId))
                }
            }
            let missingFiles = freshFiles.filter { !diskPaths.contains($0.path) }
            for file in missingFiles {
                let stemNoExt = ((file.path as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                identities.append(FileIdentity(
                    path: file.path,
                    format: file.format,
                    stem: stemNoExt,
                    isbn: file.embeddedIsbn,
                    titleKey: file.embeddedTitleKey,
                    authorKey: file.embeddedAuthorKey,
                    manualGroupId: file.manualGroupId))
            }
            markedMissing = missingFiles.filter { !$0.missingFlag }.count

            let groups = GroupingEngine.propose(identities)

            let books = try Book.fetchAll(db)
            let booksById = Dictionary(uniqueKeysWithValues: books.compactMap { book in
                book.id.map { ($0, book) }
            })
            var filesByPath = freshByPath
            let diskByPath = Dictionary(
                uniqueKeysWithValues: parsedFiles.map { ($0.disk.path, $0.disk) })

            for group in groups {
                // Merge embedded metadata from freshly parsed member files.
                var mergedMetadata = BookMetadata()
                var parseNotes: [String] = []
                for member in group.files {
                    guard let extraction = metadataByPath[member.path] else { continue }
                    mergedMetadata = Self.merge(mergedMetadata, extraction.metadata)
                    if let note = extraction.parseErrorNote { parseNotes.append(note) }
                }

                // Pick the target book: the existing book owning the most
                // member files (stable across rescans); otherwise create one.
                var memberBookIds: [Int64: Int] = [:]
                for member in group.files {
                    if let owner = filesByPath[member.path]?.bookId {
                        memberBookIds[owner, default: 0] += 1
                    }
                }
                let targetBookId = memberBookIds
                    .sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }
                    .first?.key

                var isNewBook = false
                var book: Book
                if let id = targetBookId, let known = booksById[id] {
                    book = known
                } else {
                    // New book: identity from embedded metadata, else filename.
                    isNewBook = true
                    let stem = group.files.first?.stem ?? "Unknown"
                    let guess = FilenameInference.guess(fromStem: stem)
                    book = Book(
                        title: mergedMetadata.title ?? guess.title,
                        authors: !mergedMetadata.authors.isEmpty
                            ? mergedMetadata.authors
                            : (guess.author.map { [$0] } ?? []))
                }

                // Fill empty fields from embedded data — never overwrite
                // resolved/manual values (FR-1.4, FR-3.2).
                let filled = Self.fillEmptyFields(of: &book, from: mergedMetadata)
                book.groupMethod = group.method
                book.parseErrorNote = parseNotes.isEmpty ? nil : parseNotes.joined(separator: "; ")
                book.refreshMetadataStatus()
                book.updatedAt = Date()
                try book.save(db)
                guard let bookId = book.id else { continue }

                // Provenance for newly filled fields.
                for field in filled {
                    let existing = try Provenance
                        .filter(Column("bookId") == bookId && Column("field") == field)
                        .fetchOne(db)
                    if existing == nil {
                        try Provenance(bookId: bookId, field: field, source: .embedded).save(db)
                    }
                }
                // Title/author provenance for new books (FR-3.3).
                if isNewBook {
                    let titleSource: MetadataSource =
                        mergedMetadata.title != nil ? .embedded : .filename
                    try Provenance(bookId: bookId, field: "title", source: titleSource).save(db)
                    if !book.authors.isEmpty {
                        let authorSource: MetadataSource =
                            !mergedMetadata.authors.isEmpty ? .embedded : .filename
                        try Provenance(bookId: bookId, field: "authors", source: authorSource).save(db)
                    }
                }

                // Upsert file rows for this group.
                for member in group.files {
                    let onDisk = diskByPath[member.path]
                    var row = filesByPath[member.path] ?? BookFile(
                        bookId: bookId,
                        path: member.path,
                        format: member.format,
                        sizeBytes: onDisk?.sizeBytes ?? 0,
                        modifiedAt: onDisk?.modifiedAt ?? .distantPast)
                    row.bookId = bookId
                    if let onDisk {
                        row.sizeBytes = onDisk.sizeBytes
                        row.modifiedAt = onDisk.modifiedAt
                        row.missingFlag = false
                    } else {
                        row.missingFlag = true
                    }
                    if let extraction = metadataByPath[member.path] {
                        let m = extraction.metadata
                        row.embeddedIsbn = m.isbn13 ?? m.isbn10
                        row.embeddedTitleKey = m.title.map(Normalizer.key)
                        row.embeddedAuthorKey = m.authors.isEmpty
                            ? nil : Normalizer.authorSetKey(m.authors)
                    }
                    try row.save(db)
                    filesByPath[member.path] = row
                }

                // Queue a cover when the book has none and a member provided
                // one. Manual/online covers are never replaced (FR-3.2 spirit).
                if book.coverCachePath == nil, let coverData = mergedMetadata.coverData {
                    pendingCovers.append(PendingCover(bookId: bookId, data: coverData))
                }
            }

            try self.database.deleteOrphanBooks(db)
        }
        summary.markedMissing = markedMissing

        // Store covers and point books at them.
        for pending in pendingCovers {
            if let path = try? coverCache.store(pending.data, forBookId: pending.bookId) {
                try database.writer.write { db in
                    try db.execute(
                        sql: "UPDATE book SET coverCachePath = ? WHERE id = ? AND coverCachePath IS NULL",
                        arguments: [path, pending.bookId])
                }
            }
        }

        summary.duration = Date().timeIntervalSince(start)
        return summary
    }

    // MARK: - Metadata merging

    /// First-non-nil merge of two embedded metadata sets.
    static func merge(_ a: BookMetadata, _ b: BookMetadata) -> BookMetadata {
        var m = a
        m.title = a.title ?? b.title
        m.authors = a.authors.isEmpty ? b.authors : a.authors
        m.series = a.series ?? b.series
        m.seriesIndex = a.seriesIndex ?? b.seriesIndex
        m.publisher = a.publisher ?? b.publisher
        m.year = a.year ?? b.year
        m.language = a.language ?? b.language
        m.isbn10 = a.isbn10 ?? b.isbn10
        m.isbn13 = a.isbn13 ?? b.isbn13
        m.description = a.description ?? b.description
        m.coverData = a.coverData ?? b.coverData
        return m
    }

    /// Fills only-empty fields of a book; returns the fields that were filled.
    static func fillEmptyFields(of book: inout Book, from metadata: BookMetadata) -> [String] {
        var filled: [String] = []
        if book.authors.isEmpty, !metadata.authors.isEmpty {
            book.authors = metadata.authors
            book.authorSort = Book.sortKey(forAuthors: metadata.authors)
            filled.append("authors")
        }
        if book.series == nil, let v = metadata.series { book.series = v; filled.append("series") }
        if book.seriesIndex == nil, let v = metadata.seriesIndex {
            book.seriesIndex = v; filled.append("series_index")
        }
        if book.publisher == nil, let v = metadata.publisher {
            book.publisher = v; filled.append("publisher")
        }
        if book.year == nil, let v = metadata.year { book.year = v; filled.append("year") }
        if book.language == nil, let v = metadata.language {
            book.language = v; filled.append("language")
        }
        if book.isbn10 == nil, let v = metadata.isbn10 { book.isbn10 = v; filled.append("isbn10") }
        if book.isbn13 == nil, let v = metadata.isbn13 { book.isbn13 = v; filled.append("isbn13") }
        if book.bookDescription == nil, let v = metadata.description {
            book.bookDescription = v; filled.append("description")
        }
        return filled
    }
}
