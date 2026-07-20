import Foundation
import GRDB

// MARK: - Enums

/// How a book's metadata was resolved, per field (FR-3.3).
public enum MetadataSource: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case embedded
    case googleBooks = "google_books"
    case openLibrary = "open_library"
    case manual
    case filename
}

/// Overall metadata completeness of a book (FR-6.3 filter).
public enum MetadataStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case unresolved   // nothing beyond the filename
    case partial      // some fields resolved
    case complete     // title + author + (year or ISBN) present
}

/// How a group was formed (FR-2.1, FR-2.5).
public enum GroupMethod: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case isbn         // rule 1: identical embedded ISBN
    case metadata     // rule 2: normalized (title, author) match
    case filename     // rule 3: normalized filename stem — "auto-grouped", reviewable
    case manual       // user merged/ungrouped
    case single       // no grouping needed (one file)
}

/// Supported file formats (§4).
public enum BookFormat: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    // Full support: embedded metadata + cover extraction.
    case epub, pdf, mobi, azw3
    // Recognized: grouped + renamable, no embedded parsing.
    case djvu, cbz, cbr, fb2, txt

    public var hasEmbeddedSupport: Bool {
        switch self {
        case .epub, .pdf, .mobi, .azw3: return true
        default: return false
        }
    }

    public var badge: String { rawValue.uppercased() }
}

// MARK: - Book

/// One logical book; may span multiple files/formats (§6.2).
public struct Book: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "book"

    public var id: Int64?
    public var title: String
    public var titleSort: String
    public var authors: [String]
    public var authorSort: String
    public var series: String?
    public var seriesIndex: Double?
    public var publisher: String?
    public var year: Int?
    public var language: String?
    public var isbn10: String?
    public var isbn13: String?
    public var bookDescription: String?
    public var coverCachePath: String?
    public var metadataStatus: MetadataStatus
    public var groupMethod: GroupMethod
    /// Non-fatal parse failure note (§9: corrupt/DRM'd files).
    public var parseErrorNote: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        title: String,
        titleSort: String? = nil,
        authors: [String] = [],
        authorSort: String? = nil,
        series: String? = nil,
        seriesIndex: Double? = nil,
        publisher: String? = nil,
        year: Int? = nil,
        language: String? = nil,
        isbn10: String? = nil,
        isbn13: String? = nil,
        bookDescription: String? = nil,
        coverCachePath: String? = nil,
        metadataStatus: MetadataStatus = .unresolved,
        groupMethod: GroupMethod = .single,
        parseErrorNote: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.titleSort = titleSort ?? Book.sortKey(forTitle: title)
        self.authors = authors
        self.authorSort = authorSort ?? Book.sortKey(forAuthors: authors)
        self.series = series
        self.seriesIndex = seriesIndex
        self.publisher = publisher
        self.year = year
        self.language = language
        self.isbn10 = isbn10
        self.isbn13 = isbn13
        self.bookDescription = bookDescription
        self.coverCachePath = coverCachePath
        self.metadataStatus = metadataStatus
        self.groupMethod = groupMethod
        self.parseErrorNote = parseErrorNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// "The Title" → "title"; used for title ordering.
    public static func sortKey(forTitle title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "a ", "an "] where t.lowercased().hasPrefix(article) {
            t = String(t.dropFirst(article.count))
            break
        }
        return t.lowercased()
    }

    /// "Frank Herbert" → "herbert, frank" (FR-4.1 {author_sort} + FR-6.4 sort).
    public static func sortKey(forAuthors authors: [String]) -> String {
        guard let first = authors.first, !first.isEmpty else { return "" }
        return Self.lastFirst(first).lowercased()
    }

    /// "Frank Herbert" → "Herbert, Frank"; single-word names pass through.
    public static func lastFirst(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count > 1, let last = parts.last else { return name }
        return "\(last), \(parts.dropLast().joined(separator: " "))"
    }

    /// Recomputes status from field completeness (FR-6.3).
    public mutating func refreshMetadataStatus() {
        let hasTitle = !title.trimmingCharacters(in: .whitespaces).isEmpty
        let hasAuthor = !authors.isEmpty
        let hasExtra = year != nil || isbn13 != nil || isbn10 != nil
        if hasTitle && hasAuthor && hasExtra {
            metadataStatus = .complete
        } else if hasTitle && hasAuthor {
            metadataStatus = .partial
        } else {
            metadataStatus = .unresolved
        }
    }
}

// MARK: - BookFile

/// One file on disk belonging to a book (§7).
public struct BookFile: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "bookFile"

    public var id: Int64?
    public var bookId: Int64
    public var path: String
    public var format: BookFormat
    public var sizeBytes: Int64
    public var modifiedAt: Date
    /// File no longer on disk; kept, not deleted (FR-1.5).
    public var missingFlag: Bool
    /// Manual grouping token (FR-2.4): files sharing a token are forced into one
    /// book; a unique token pins a file alone. Nil → automatic grouping applies.
    public var manualGroupId: String?
    /// Grouping keys cached from the last embedded-metadata parse, so rescans
    /// can regroup without re-parsing unchanged files (FR-1.4).
    public var embeddedIsbn: String?
    public var embeddedTitleKey: String?
    public var embeddedAuthorKey: String?

    public init(
        id: Int64? = nil,
        bookId: Int64,
        path: String,
        format: BookFormat,
        sizeBytes: Int64,
        modifiedAt: Date,
        missingFlag: Bool = false,
        manualGroupId: String? = nil,
        embeddedIsbn: String? = nil,
        embeddedTitleKey: String? = nil,
        embeddedAuthorKey: String? = nil
    ) {
        self.id = id
        self.bookId = bookId
        self.path = path
        self.format = format
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.missingFlag = missingFlag
        self.manualGroupId = manualGroupId
        self.embeddedIsbn = embeddedIsbn
        self.embeddedTitleKey = embeddedTitleKey
        self.embeddedAuthorKey = embeddedAuthorKey
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var filename: String { (path as NSString).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path) }
}

// MARK: - Provenance

/// Field-level source record (FR-3.3): where each metadata field came from.
public struct Provenance: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "provenance"

    public var bookId: Int64
    public var field: String
    public var source: MetadataSource
    public var fetchedAt: Date

    public init(bookId: Int64, field: String, source: MetadataSource, fetchedAt: Date = Date()) {
        self.bookId = bookId
        self.field = field
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

// MARK: - RenameLog

/// One renamed file in a batch; the undo journal (FR-4.8).
public struct RenameLog: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "renameLog"

    public var id: Int64?
    public var batchId: String
    public var fileId: Int64
    public var oldPath: String
    public var newPath: String
    public var executedAt: Date
    public var revertedFlag: Bool

    public init(
        id: Int64? = nil,
        batchId: String,
        fileId: Int64,
        oldPath: String,
        newPath: String,
        executedAt: Date = Date(),
        revertedFlag: Bool = false
    ) {
        self.id = id
        self.batchId = batchId
        self.fileId = fileId
        self.oldPath = oldPath
        self.newPath = newPath
        self.executedAt = executedAt
        self.revertedFlag = revertedFlag
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Setting

/// Key/value app settings (§6.7).
public struct Setting: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "setting"

    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Well-known setting keys with defaults.
public enum SettingKey {
    public static let libraryBookmark = "library.bookmark"          // base64 bookmark data
    public static let libraryPath = "library.path"                  // display path
    public static let renameTemplate = "rename.template"
    public static let metadataOverwrite = "metadata.overwrite"      // "fill_empty" | "overwrite"
    public static let providerOrder = "lookup.providerOrder"        // "google_books,open_library"
    public static let ignoreExtensions = "scan.ignoreExtensions"    // comma-separated
    public static let csvDelimiter = "export.csvDelimiter"          // "," | ";" | "\t"
    public static let csvMultiValueSeparator = "export.csvMultiValueSeparator"

    public static let defaults: [String: String] = [
        renameTemplate: "{author} - {title}.{ext}",
        metadataOverwrite: "fill_empty",
        providerOrder: "google_books,open_library",
        ignoreExtensions: "",
        csvDelimiter: ",",
        csvMultiValueSeparator: "; ",
    ]
}
