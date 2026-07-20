import Foundation
import GRDB

/// The app's SQLite database (§7). Lives in Application Support; the folder on
/// disk stays the source of truth for files, the database is the source of
/// truth for metadata corrections and grouping decisions.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    /// Database in `~/Library/Application Support/Librarian/librarian.sqlite`.
    public static func onDisk() throws -> AppDatabase {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Librarian", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("librarian.sqlite")
        let queue = try DatabaseQueue(path: dbURL.path)
        return try AppDatabase(queue)
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "book") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("titleSort", .text).notNull().indexed()
                t.column("authors", .text).notNull()           // JSON array
                t.column("authorSort", .text).notNull().indexed()
                t.column("series", .text)
                t.column("seriesIndex", .double)
                t.column("publisher", .text)
                t.column("year", .integer)
                t.column("language", .text)
                t.column("isbn10", .text)
                t.column("isbn13", .text).indexed()
                t.column("bookDescription", .text)
                t.column("coverCachePath", .text)
                t.column("metadataStatus", .text).notNull()
                t.column("groupMethod", .text).notNull()
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
                t.column("manualGroupId", .text).indexed()
                t.column("embeddedIsbn", .text)
                t.column("embeddedTitleKey", .text)
                t.column("embeddedAuthorKey", .text)
            }

            try db.create(table: "provenance") { t in
                t.column("bookId", .integer).notNull()
                    .references("book", onDelete: .cascade)
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

        return migrator
    }
}

// MARK: - Settings access

extension AppDatabase {
    public func setting(_ key: String) throws -> String? {
        try writer.read { db in
            if let stored = try Setting.fetchOne(db, key: key)?.value { return stored }
            return SettingKey.defaults[key]
        }
    }

    public func setSetting(_ key: String, to value: String?) throws {
        try writer.write { db in
            if let value {
                try Setting(key: key, value: value).save(db)
            } else {
                _ = try Setting.deleteOne(db, key: key)
            }
        }
    }
}

// MARK: - Common queries

extension AppDatabase {
    /// Books with their files, for library views and export.
    public func fetchLibrary() throws -> [(book: Book, files: [BookFile])] {
        try writer.read { db in
            let books = try Book.order(Column("titleSort")).fetchAll(db)
            let files = try BookFile.fetchAll(db)
            let byBook = Dictionary(grouping: files, by: \.bookId)
            return books.map { ($0, byBook[$0.id ?? -1] ?? []) }
        }
    }

    public func provenance(forBook bookId: Int64) throws -> [String: Provenance] {
        try writer.read { db in
            let rows = try Provenance
                .filter(Column("bookId") == bookId)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.field, $0) })
        }
    }

    /// Records provenance for a set of fields in one write.
    public func recordProvenance(bookId: Int64, fields: [String], source: MetadataSource) throws {
        try writer.write { db in
            for field in fields {
                try Provenance(bookId: bookId, field: field, source: source).save(db)
            }
        }
    }

    /// Deletes books that have no files left (used after purge/ungroup).
    func deleteOrphanBooks(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM book WHERE id NOT IN (SELECT DISTINCT bookId FROM bookFile)
            """)
    }

    /// Purge entries whose files are missing on disk (FR-1.5, explicit).
    public func purgeMissingFiles() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM bookFile WHERE missingFlag = 1")
            try self.deleteOrphanBooks(db)
        }
    }
}
