import Foundation
import GRDB

/// Owns the SQLite database: connection, migrations, and shared access.
///
/// The folder on disk is the source of truth for files; this database is the
/// source of truth for metadata corrections and grouping decisions.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (creating if needed) the database at the given URL.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try AppDatabase(try DatabasePool(path: url.path))
    }

    /// An in-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    /// Default location: ~/Library/Application Support/BookShelf/library.sqlite
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("BookShelf/library.sqlite")
    }

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "book") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("titleSort", .text).notNull().indexed()
                t.column("authors", .text).notNull().defaults(to: "[]") // JSON array
                t.column("authorSort", .text)
                t.column("series", .text)
                t.column("seriesIndex", .double)
                t.column("publisher", .text)
                t.column("year", .integer)
                t.column("language", .text)
                t.column("isbn10", .text)
                t.column("isbn13", .text).indexed()
                t.column("bookDescription", .text)
                t.column("tags", .text).notNull().defaults(to: "[]") // JSON array
                t.column("coverCachePath", .text)
                t.column("metadataStatus", .text).notNull()
                t.column("groupMethod", .text).notNull()
                t.column("groupKey", .text).indexed()
                t.column("manualGroup", .boolean).notNull().defaults(to: false)
                t.column("parseErrorNote", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "bookFile") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("book", onDelete: .cascade).notNull()
                t.column("path", .text).notNull().unique()
                t.column("format", .text).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("missingFlag", .boolean).notNull().defaults(to: false)
                t.column("contentKey", .text).notNull()
            }

            try db.create(table: "provenance") { t in
                t.belongsTo("book", onDelete: .cascade).notNull()
                t.column("field", .text).notNull()
                t.column("source", .text).notNull()
                t.column("fetchedAt", .datetime).notNull()
                t.primaryKey(["bookId", "field"])
            }

            try db.create(table: "renameLog") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("batchId", .text).notNull().indexed()
                t.column("fileId", .integer).notNull()
                t.column("oldPath", .text).notNull()
                t.column("newPath", .text).notNull()
                t.column("executedAt", .datetime).notNull()
                t.column("revertedFlag", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "book") { t in
                t.add(column: "coverSourceFormat", .text)
            }
        }

        return migrator
    }
}

// MARK: - Convenience accessors

extension AppDatabase {
    public func setting(_ key: String) throws -> String? {
        try writer.read { db in
            try SettingRow.fetchOne(db, key: key)?.value
        }
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        try writer.write { db in
            if let value {
                try SettingRow(key: key, value: value).save(db)
            } else {
                _ = try SettingRow.deleteOne(db, key: key)
            }
        }
    }

    /// Upserts the provenance for a single (book, field) pair.
    public func recordProvenance(bookId: Int64, field: String, source: ProvenanceSource, in db: Database) throws {
        try ProvenanceRecord(bookId: bookId, field: field, source: source).save(db)
    }

    public func provenance(forBook bookId: Int64) throws -> [String: ProvenanceSource] {
        try writer.read { db in
            let rows = try ProvenanceRecord
                .filter(ProvenanceRecord.Columns.bookId == bookId)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.field, $0.source) })
        }
    }
}
