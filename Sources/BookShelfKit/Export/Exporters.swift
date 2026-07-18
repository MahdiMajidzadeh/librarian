import Foundation
import GRDB

/// Everything needed to export one book.
public struct ExportRecord: Sendable {
    public let book: Book
    public let files: [BookFile]
    public let provenance: [String: ProvenanceSource]

    public init(book: Book, files: [BookFile], provenance: [String: ProvenanceSource]) {
        self.book = book
        self.files = files
        self.provenance = provenance
    }

    /// Loads export records for the given books (or the whole library).
    public static func fetch(from database: AppDatabase, bookIds: [Int64]? = nil) async throws -> [ExportRecord] {
        try await database.writer.read { db in
            var request = Book.order(Book.Columns.titleSort)
            if let bookIds {
                request = request.filter(keys: bookIds)
            }
            let books = try request.fetchAll(db)
            let files = try BookFile.fetchAll(db)
            let provenance = try ProvenanceRecord.fetchAll(db)
            let filesByBook = Dictionary(grouping: files, by: \.bookId)
            let provenanceByBook = Dictionary(grouping: provenance, by: \.bookId)
            return books.map { book in
                let rows = provenanceByBook[book.id ?? -1] ?? []
                return ExportRecord(
                    book: book,
                    files: filesByBook[book.id ?? -1] ?? [],
                    provenance: Dictionary(uniqueKeysWithValues: rows.map { ($0.field, $0.source) }))
            }
        }
    }
}

// MARK: - JSON (FR-5.2)

public enum JSONExporter {
    public static let schemaVersion = 1

    struct Document: Encodable {
        let schema_version: Int
        let exported_at: String
        let book_count: Int
        let books: [BookObject]
    }

    struct BookObject: Encodable {
        let title: String
        let title_sort: String
        let authors: [String]
        let author_sort: String?
        let series: String?
        let series_index: Double?
        let publisher: String?
        let year: Int?
        let language: String?
        let isbn10: String?
        let isbn13: String?
        let description: String?
        let tags: [String]
        let metadata_status: String
        let group_method: String
        let provenance: [String: String]
        let cover_path: String?
        let files: [FileObject]
    }

    struct FileObject: Encodable {
        let path: String
        let format: String
        let size_bytes: Int64
        let modified_at: String
        let missing: Bool
    }

    /// Writes the JSON export; with `includeCovers`, original covers are
    /// copied to a sibling `covers/` folder and referenced by relative path
    /// (FR-5.4).
    public static func export(
        records: [ExportRecord],
        to url: URL,
        includeCovers: Bool,
        coverCache: CoverCache?,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws {
        let iso = ISO8601DateFormatter()
        var coversDir: URL?
        if includeCovers {
            let dir = url.deletingLastPathComponent().appendingPathComponent("covers")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            coversDir = dir
        }

        var books: [BookObject] = []
        for (index, record) in records.enumerated() {
            var coverPath: String?
            if let coversDir, let coverCache, let bookId = record.book.id,
               record.book.coverCachePath != nil {
                let original = coverCache.originalURL(bookId: bookId)
                let source = FileManager.default.fileExists(atPath: original.path)
                    ? original
                    : URL(fileURLWithPath: record.book.coverCachePath!)
                if FileManager.default.fileExists(atPath: source.path) {
                    let destination = coversDir.appendingPathComponent("\(bookId).jpg")
                    try? FileManager.default.removeItem(at: destination)
                    try? FileManager.default.copyItem(at: source, to: destination)
                    coverPath = "covers/\(bookId).jpg"
                }
            }

            books.append(BookObject(
                title: record.book.title,
                title_sort: record.book.titleSort,
                authors: record.book.authors,
                author_sort: record.book.authorSort,
                series: record.book.series,
                series_index: record.book.seriesIndex,
                publisher: record.book.publisher,
                year: record.book.year,
                language: record.book.language,
                isbn10: record.book.isbn10,
                isbn13: record.book.isbn13,
                description: record.book.bookDescription,
                tags: record.book.tags,
                metadata_status: record.book.metadataStatus.rawValue,
                group_method: record.book.groupMethod.rawValue,
                provenance: record.provenance.mapValues(\.rawValue),
                cover_path: coverPath,
                files: record.files.map { file in
                    FileObject(
                        path: file.path,
                        format: file.format.rawValue,
                        size_bytes: file.sizeBytes,
                        modified_at: iso.string(from: file.modifiedAt),
                        missing: file.missingFlag)
                }))
            onProgress?(index + 1, records.count)
        }

        let document = Document(
            schema_version: schemaVersion,
            exported_at: iso.string(from: Date()),
            book_count: books.count,
            books: books)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - CSV (FR-5.3)

public enum CSVExporter {
    public struct Options: Sendable {
        public var delimiter: String
        public var multiValueSeparator: String

        public init(delimiter: String = ",", multiValueSeparator: String = "; ") {
            self.delimiter = delimiter
            self.multiValueSeparator = multiValueSeparator
        }
    }

    static let header = [
        "title", "authors", "series", "series_index", "publisher", "year",
        "language", "isbn13", "isbn10", "tags", "formats", "file_count",
        "total_size_bytes", "metadata_status", "files",
    ]

    /// One row per book; multi-value fields joined; UTF-8 **with BOM** so
    /// Excel renders Persian/Unicode correctly (NFR-4).
    public static func export(
        records: [ExportRecord],
        to url: URL,
        options: Options = Options(),
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws {
        var out = header.map { escape($0, options) }.joined(separator: options.delimiter) + "\r\n"

        for (index, record) in records.enumerated() {
            let book = record.book
            let formats = record.files
                .map(\.format.rawValue)
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: ";")
            let fields: [String] = [
                book.title,
                book.authors.joined(separator: options.multiValueSeparator),
                book.series ?? "",
                book.seriesIndex.map {
                    $0.truncatingRemainder(dividingBy: 1) == 0 ? String(Int($0)) : String($0)
                } ?? "",
                book.publisher ?? "",
                book.year.map(String.init) ?? "",
                book.language ?? "",
                book.isbn13 ?? "",
                book.isbn10 ?? "",
                book.tags.joined(separator: options.multiValueSeparator),
                formats,
                String(record.files.count),
                String(record.files.reduce(0) { $0 + $1.sizeBytes }),
                book.metadataStatus.rawValue,
                record.files.map(\.path).joined(separator: options.multiValueSeparator),
            ]
            out += fields.map { escape($0, options) }.joined(separator: options.delimiter) + "\r\n"
            onProgress?(index + 1, records.count)
        }

        var data = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM
        data.append(Data(out.utf8))
        try data.write(to: url, options: .atomic)
    }

    static func escape(_ field: String, _ options: Options) -> String {
        if field.contains(options.delimiter) || field.contains("\"")
            || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
