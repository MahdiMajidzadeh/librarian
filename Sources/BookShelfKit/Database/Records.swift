import Foundation
import GRDB

// MARK: - Enums

public enum BookFormat: String, Codable, CaseIterable, Sendable {
    case epub, pdf, mobi, azw3
    case djvu, cbz, cbr, fb2, txt

    /// Formats with embedded metadata/cover parsing support.
    public var supportsEmbeddedMetadata: Bool {
        switch self {
        case .epub, .pdf, .mobi, .azw3: return true
        default: return false
        }
    }

    public static var allExtensions: Set<String> {
        Set(allCases.map(\.rawValue))
    }
}

public enum MetadataStatus: String, Codable, Sendable {
    case unresolved   // nothing beyond the filename
    case partial      // some fields present
    case complete     // title + author + year + cover present
}

public enum GroupMethod: String, Codable, Sendable {
    case isbn         // rule 1: identical embedded ISBN
    case metadata     // rule 2: normalized (title, author set)
    case filename     // rule 3: normalized filename stem — "auto-grouped"
    case manual       // user merge/split decision
    case single       // only one file, no grouping applied
}

public enum ProvenanceSource: String, Codable, Sendable {
    case embedded
    case googleBooks = "google_books"
    case openLibrary = "open_library"
    case manual
    case filename
}

// MARK: - Book

public struct Book: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var title: String
    public var titleSort: String
    public var authors: [String]
    public var authorSort: String?
    public var series: String?
    public var seriesIndex: Double?
    public var publisher: String?
    public var year: Int?
    public var language: String?
    public var isbn10: String?
    public var isbn13: String?
    public var bookDescription: String?
    public var tags: [String]
    public var coverCachePath: String?
    public var metadataStatus: MetadataStatus
    public var groupMethod: GroupMethod
    public var groupKey: String?
    public var manualGroup: Bool
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
        tags: [String] = [],
        coverCachePath: String? = nil,
        metadataStatus: MetadataStatus = .unresolved,
        groupMethod: GroupMethod = .single,
        groupKey: String? = nil,
        manualGroup: Bool = false,
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
        self.tags = tags
        self.coverCachePath = coverCachePath
        self.metadataStatus = metadataStatus
        self.groupMethod = groupMethod
        self.groupKey = groupKey
        self.manualGroup = manualGroup
        self.parseErrorNote = parseErrorNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// "The Left Hand of Darkness" → "left hand of darkness"
    public static func sortKey(forTitle title: String) -> String {
        var lowered = title.lowercased().trimmingCharacters(in: .whitespaces)
        for article in ["the ", "a ", "an "] where lowered.hasPrefix(article) {
            lowered.removeFirst(article.count)
            break
        }
        return lowered
    }

    /// ["Frank Herbert"] → "herbert, frank"
    public static func sortKey(forAuthors authors: [String]) -> String? {
        guard let first = authors.first, !first.isEmpty else { return nil }
        let parts = first.split(separator: " ").map(String.init)
        guard parts.count > 1, let last = parts.last else { return first.lowercased() }
        return "\(last), \(parts.dropLast().joined(separator: " "))".lowercased()
    }
}

extension Book: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "book"

    public enum Columns {
        public static let title = Column(CodingKeys.title)
        public static let titleSort = Column(CodingKeys.titleSort)
        public static let year = Column(CodingKeys.year)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let groupKey = Column(CodingKeys.groupKey)
        public static let metadataStatus = Column(CodingKeys.metadataStatus)
    }

    public static let files = hasMany(BookFile.self)
    public static let provenance = hasMany(ProvenanceRecord.self)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - BookFile

public struct BookFile: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var bookId: Int64
    public var path: String
    public var format: BookFormat
    public var sizeBytes: Int64
    public var modifiedAt: Date
    public var missingFlag: Bool
    /// Incremental-rescan key: "size|mtime-epoch". Unchanged files are skipped.
    public var contentKey: String

    public init(
        id: Int64? = nil,
        bookId: Int64,
        path: String,
        format: BookFormat,
        sizeBytes: Int64,
        modifiedAt: Date,
        missingFlag: Bool = false
    ) {
        self.id = id
        self.bookId = bookId
        self.path = path
        self.format = format
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.missingFlag = missingFlag
        self.contentKey = BookFile.contentKey(sizeBytes: sizeBytes, modifiedAt: modifiedAt)
    }

    public static func contentKey(sizeBytes: Int64, modifiedAt: Date) -> String {
        "\(sizeBytes)|\(Int(modifiedAt.timeIntervalSince1970))"
    }
}

extension BookFile: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "bookFile"

    public enum Columns {
        public static let bookId = Column(CodingKeys.bookId)
        public static let path = Column(CodingKeys.path)
        public static let missingFlag = Column(CodingKeys.missingFlag)
    }

    public static let book = belongsTo(Book.self)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Provenance

public struct ProvenanceRecord: Codable, Equatable, Sendable {
    public var bookId: Int64
    public var field: String
    public var source: ProvenanceSource
    public var fetchedAt: Date

    public init(bookId: Int64, field: String, source: ProvenanceSource, fetchedAt: Date = Date()) {
        self.bookId = bookId
        self.field = field
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

extension ProvenanceRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "provenance"

    public enum Columns {
        public static let bookId = Column(CodingKeys.bookId)
        public static let field = Column(CodingKeys.field)
    }
}

// MARK: - RenameLog

public struct RenameLogEntry: Codable, Identifiable, Equatable, Sendable {
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
}

extension RenameLogEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "renameLog"

    public enum Columns {
        public static let batchId = Column(CodingKeys.batchId)
        public static let executedAt = Column(CodingKeys.executedAt)
        public static let revertedFlag = Column(CodingKeys.revertedFlag)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Settings

public struct SettingRow: Codable, Equatable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

extension SettingRow: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "setting"
}
