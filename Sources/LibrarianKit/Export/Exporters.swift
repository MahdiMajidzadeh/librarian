import Foundation

/// Library export (§6.5): versioned JSON with provenance and files[], and
/// CSV (one row per book) with UTF-8 BOM so Excel renders Unicode/Persian
/// correctly. Scope is whatever selection the caller passes (FR-5.1).
public enum Exporters {
    public typealias Entry = (book: Book, files: [BookFile])

    // MARK: - JSON (FR-5.2, FR-5.4)

    public struct JSONOptions: Sendable {
        /// Copies cover images to a sibling `covers/` folder and references
        /// them via relative paths (FR-5.4).
        public var includeCovers: Bool

        public init(includeCovers: Bool = false) {
            self.includeCovers = includeCovers
        }
    }

    public static func exportJSON(
        entries: [Entry],
        provenance: [Int64: [String: Provenance]],
        to destination: URL,
        options: JSONOptions = JSONOptions(),
        coverCache: CoverCache? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws {
        let coversDir = destination.deletingLastPathComponent()
            .appendingPathComponent("covers", isDirectory: true)
        if options.includeCovers {
            try FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
        }

        var books: [[String: Any]] = []
        for (index, entry) in entries.enumerated() {
            let (book, files) = entry
            var object: [String: Any] = [
                "title": book.title,
                "title_sort": book.titleSort,
                "authors": book.authors,
                "author_sort": book.authorSort,
                "metadata_status": book.metadataStatus.rawValue,
                "group_method": book.groupMethod.rawValue,
            ]
            object["series"] = book.series
            object["series_index"] = book.seriesIndex
            object["publisher"] = book.publisher
            object["year"] = book.year
            object["language"] = book.language
            object["isbn10"] = book.isbn10
            object["isbn13"] = book.isbn13
            object["description"] = book.bookDescription

            if let bookId = book.id, let map = provenance[bookId], !map.isEmpty {
                var provenanceObject: [String: Any] = [:]
                for (field, record) in map {
                    provenanceObject[field] = [
                        "source": record.source.rawValue,
                        "fetched_at": iso8601.string(from: record.fetchedAt),
                    ]
                }
                object["provenance"] = provenanceObject
            }

            object["files"] = files.map { file -> [String: Any] in
                [
                    "path": file.path,
                    "format": file.format.rawValue,
                    "size_bytes": file.sizeBytes,
                    "modified_date": iso8601.string(from: file.modifiedAt),
                    "missing": file.missingFlag,
                ]
            }

            if options.includeCovers, let bookId = book.id,
               let cache = coverCache,
               let sourceURL = cache.originalURL(forBookId: bookId) {
                let name = "book-\(bookId).jpg"
                let target = coversDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: sourceURL, to: target)
                object["cover_path"] = "covers/\(name)"
            }

            books.append(object)
            progress?(index + 1, entries.count)
        }

        let payload: [String: Any] = [
            "schema_version": 1,
            "exported_at": iso8601.string(from: Date()),
            "book_count": books.count,
            "books": books,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - CSV (FR-5.3)

    public struct CSVOptions: Sendable {
        public var delimiter: String
        public var multiValueSeparator: String

        public init(delimiter: String = ",", multiValueSeparator: String = "; ") {
            self.delimiter = delimiter
            self.multiValueSeparator = multiValueSeparator
        }
    }

    public static let csvColumns = [
        "title", "authors", "series", "series_index", "publisher", "year",
        "language", "isbn10", "isbn13", "formats", "files", "total_size_bytes",
        "metadata_status", "group_method",
    ]

    public static func exportCSV(
        entries: [Entry],
        to destination: URL,
        options: CSVOptions = CSVOptions(),
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws {
        let text = csvText(entries: entries, options: options, progress: progress)
        // UTF-8 BOM so Excel detects the encoding (Persian titles, FR-5.3).
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(text.data(using: .utf8)!)
        try data.write(to: destination, options: .atomic)
    }

    static func csvText(
        entries: [Entry],
        options: CSVOptions,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> String {
        var lines: [String] = [csvColumns.joined(separator: options.delimiter)]
        for (index, entry) in entries.enumerated() {
            let (book, files) = entry
            let formats = files.map(\.format.rawValue).sorted().joined(separator: ";")
            let fields: [String] = [
                book.title,
                book.authors.joined(separator: options.multiValueSeparator),
                book.series ?? "",
                book.seriesIndex.map { seriesIndexString($0) } ?? "",
                book.publisher ?? "",
                book.year.map(String.init) ?? "",
                book.language ?? "",
                book.isbn10 ?? "",
                book.isbn13 ?? "",
                formats,
                files.map(\.path).joined(separator: options.multiValueSeparator),
                String(files.reduce(0) { $0 + $1.sizeBytes }),
                book.metadataStatus.rawValue,
                book.groupMethod.rawValue,
            ]
            lines.append(
                fields.map { escapeCSV($0, delimiter: options.delimiter) }
                    .joined(separator: options.delimiter))
            progress?(index + 1, entries.count)
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting: fields containing the delimiter, quotes, or
    /// newlines are wrapped in quotes with inner quotes doubled.
    static func escapeCSV(_ field: String, delimiter: String) -> String {
        if field.contains(delimiter) || field.contains("\"")
            || field.contains("\n") || field.contains("\r") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }

    public static func seriesIndexString(_ index: Double) -> String {
        index.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(index)) : String(index)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
