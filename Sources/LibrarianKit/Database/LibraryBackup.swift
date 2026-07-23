import Foundation
import GRDB

/// Keeps a self-contained copy of the catalog *inside* the library folder
/// (hidden `.librarian.sqlite` at the root), so metadata corrections,
/// grouping decisions, and the rename journal travel with the books and
/// survive a lost Application Support directory or a move to another Mac.
///
/// - `write` refreshes the copy via SQLite's online backup API (consistent
///   even while the live database is in use) and replaces the previous copy
///   atomically. The file is hidden, so scans never catalog it (SCAN-02).
/// - `restoreIfNeeded` seeds an *empty* live catalog from the folder copy;
///   it never overwrites existing data. Absolute paths are rebased when the
///   folder now lives somewhere else (renamed, or a different machine), and
///   cover-cache paths that don't resolve locally are cleared so the next
///   scan re-extracts covers.
public enum LibraryBackup {
    /// Hidden so `LibraryScanner` skips it (FR-1.2) and Finder doesn't show it.
    public static let fileName = ".librarian.sqlite"

    /// The root path at the time the backup was written, stored inside the
    /// backup itself so a restore can detect a moved folder and rebase paths.
    static let rootKey = "backup.libraryRoot"

    public static func url(forRoot root: URL) -> URL {
        root.appendingPathComponent(fileName)
    }

    public static func exists(atRoot root: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(forRoot: root).path)
    }

    /// Copies the live database into `<root>/.librarian.sqlite`.
    /// Written to a temp file first, then swapped in atomically, so a crash
    /// mid-write never corrupts the previous good copy.
    public static func write(from database: AppDatabase, toRoot root: URL) throws {
        let destination = url(forRoot: root)
        let temp = root.appendingPathComponent(fileName + ".tmp")
        try? FileManager.default.removeItem(at: temp)

        let copy = try DatabaseQueue(path: temp.path)
        do {
            try database.writer.backup(to: copy)
            try copy.write { db in
                try Setting(key: rootKey, value: root.path).save(db)
            }
            try copy.close()
        } catch {
            try? copy.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
    }

    /// Seeds the live database from the folder copy when — and only when —
    /// the live catalog is empty (a fresh install, a wiped Application
    /// Support, a new Mac). Returns true when a restore happened.
    @discardableResult
    public static func restoreIfNeeded(
        into database: AppDatabase,
        root: URL,
        coverCache: CoverCache? = nil
    ) throws -> Bool {
        let backupURL = url(forRoot: root)
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return false }

        // Never clobber an existing catalog (same spirit as fill-empty).
        let isEmpty = try database.writer.read { db in
            try Book.fetchCount(db) == 0 && BookFile.fetchCount(db) == 0
        }
        guard isEmpty else { return false }

        var config = Configuration()
        config.readonly = true
        let source = try DatabaseQueue(path: backupURL.path, configuration: config)
        defer { try? source.close() }
        try source.backup(to: database.writer)

        try database.writer.write { db in
            // Rebase absolute paths when the folder moved since the backup.
            let oldRoot = try Setting.fetchOne(db, key: rootKey)?.value
            _ = try Setting.deleteOne(db, key: rootKey)
            if let oldRoot, oldRoot != root.path {
                try rebasePaths(db, from: oldRoot, to: root.path)
            }

            // Settings in the copy describe the old environment: point the
            // library at the folder we restored from, and drop the bookmark
            // (stale on another machine; the app re-persists a fresh one).
            try Setting(key: SettingKey.libraryPath, value: root.path).save(db)
            _ = try Setting.deleteOne(db, key: SettingKey.libraryBookmark)

            // Cached covers live in Application Support, not in the backup.
            // Clear dangling references so the next scan re-extracts covers
            // (scan only queues covers for books with a nil coverCachePath).
            if let coverCache {
                let covered = try Book.filter(Column("coverCachePath") != nil).fetchAll(db)
                for var book in covered {
                    guard let path = book.coverCachePath else { continue }
                    let local = coverCache.gridURL(forPath: path)
                    if !FileManager.default.fileExists(atPath: local.path) {
                        book.coverCachePath = nil
                        try book.update(db)
                    }
                }
            }
        }
        return true
    }

    /// Rewrites the old root prefix to the new one on every stored absolute
    /// path (book files and the rename-undo journal).
    private static func rebasePaths(_ db: Database, from oldRoot: String, to newRoot: String) throws {
        let oldPrefix = oldRoot.hasSuffix("/") ? oldRoot : oldRoot + "/"
        let newPrefix = newRoot.hasSuffix("/") ? newRoot : newRoot + "/"
        func rebase(_ path: String) -> String {
            path.hasPrefix(oldPrefix)
                ? newPrefix + path.dropFirst(oldPrefix.count)
                : path
        }

        for var file in try BookFile.fetchAll(db) where file.path.hasPrefix(oldPrefix) {
            file.path = rebase(file.path)
            try file.update(db)
        }
        for var entry in try RenameLog.fetchAll(db) {
            let old = rebase(entry.oldPath)
            let new = rebase(entry.newPath)
            guard old != entry.oldPath || new != entry.newPath else { continue }
            entry.oldPath = old
            entry.newPath = new
            try entry.update(db)
        }
    }
}
