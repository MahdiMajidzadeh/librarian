import Foundation
import GRDB

/// Executes rename batches (FR-4.7) and undoes the most recent one (FR-4.8).
/// Every executed rename is journaled to `renameLog`; the journal lives in
/// SQLite so undo survives app restarts.
public enum RenameExecutor {
    public struct BatchResult: Sendable, Equatable {
        public let batchId: String
        public var renamed = 0
        public var skipped = 0
        public var failures: [Int64: String] = [:]  // fileId → reason
    }

    /// Renames all included, ready rows. File move + database path update
    /// happen in one transaction per file; a failed move leaves the database
    /// untouched for that file.
    public static func execute(
        plan: [RenamePlanItem],
        database: AppDatabase
    ) async throws -> BatchResult {
        let batchId = UUID().uuidString
        var result = BatchResult(batchId: batchId)

        for item in plan {
            guard item.included,
                  item.status == .ready || item.status == .collisionResolved,
                  let newPath = item.newPath else {
                result.skipped += 1
                continue
            }
            do {
                try await database.writer.write { db in
                    guard var file = try BookFile.fetchOne(db, key: item.id) else {
                        throw ParseError("file record \(item.id) vanished")
                    }
                    // Move on disk first; if it throws, the transaction rolls
                    // back with no journal entry.
                    try FileManager.default.moveItem(
                        atPath: item.currentPath, toPath: newPath)
                    do {
                        file.path = newPath
                        try file.update(db)
                        var entry = RenameLogEntry(
                            batchId: batchId, fileId: item.id,
                            oldPath: item.currentPath, newPath: newPath)
                        try entry.insert(db)
                    } catch {
                        // The DB write failed after the move succeeded: the
                        // transaction rolls back with no journal entry, so
                        // put the file back to keep disk and DB consistent.
                        try? FileManager.default.moveItem(
                            atPath: newPath, toPath: item.currentPath)
                        throw error
                    }
                }
                result.renamed += 1
            } catch {
                result.failures[item.id] = "\(error)"
            }
        }
        return result
    }

    /// The most recent batch that has not been reverted, if any.
    public static func lastUndoableBatch(database: AppDatabase) async throws -> (batchId: String, entries: Int)? {
        try await database.writer.read { db in
            let latest = try RenameLogEntry
                .filter(RenameLogEntry.Columns.revertedFlag == false)
                .order(RenameLogEntry.Columns.executedAt.desc, Column("id").desc)
                .fetchOne(db)
            guard let latest else { return nil }
            let count = try RenameLogEntry
                .filter(RenameLogEntry.Columns.batchId == latest.batchId)
                .filter(RenameLogEntry.Columns.revertedFlag == false)
                .fetchCount(db)
            return (latest.batchId, count)
        }
    }

    /// Reverts the most recent non-reverted batch, newest entries first.
    /// Returns the number of files restored.
    @discardableResult
    public static func undoLastBatch(database: AppDatabase) async throws -> Int {
        guard let (batchId, _) = try await lastUndoableBatch(database: database) else {
            return 0
        }
        let entries = try await database.writer.read { db in
            try RenameLogEntry
                .filter(RenameLogEntry.Columns.batchId == batchId)
                .filter(RenameLogEntry.Columns.revertedFlag == false)
                .order(Column("id").desc)
                .fetchAll(db)
        }

        var restored = 0
        for entry in entries {
            do {
                try await database.writer.write { db in
                    var entry = entry
                    try FileManager.default.moveItem(
                        atPath: entry.newPath, toPath: entry.oldPath)
                    do {
                        if var file = try BookFile.fetchOne(db, key: entry.fileId) {
                            file.path = entry.oldPath
                            try file.update(db)
                        }
                        entry.revertedFlag = true
                        try entry.update(db)
                    } catch {
                        // Roll the disk back too, so a retried undo still
                        // finds the file at newPath.
                        try? FileManager.default.moveItem(
                            atPath: entry.oldPath, toPath: entry.newPath)
                        throw error
                    }
                }
                restored += 1
            } catch {
                // Leave the entry un-reverted; a later undo can retry once
                // the user resolves whatever blocks the move.
                continue
            }
        }
        return restored
    }
}
