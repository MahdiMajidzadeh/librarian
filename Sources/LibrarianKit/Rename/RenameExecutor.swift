import Foundation
import GRDB

/// Executes a rename batch and provides undo of the last batch (FR-4.7,
/// FR-4.8). Files move in place (same directory) via `FileManager.moveItem`;
/// the database updates paths in the same pass; every executed rename lands
/// in the persistent journal (`renameLog`), which survives app restarts.
public final class RenameExecutor: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public struct BatchResult: Sendable, Equatable {
        public var batchId: String
        public var renamed: Int
        public var failed: [(fileId: Int64, error: String)]

        public static func == (lhs: BatchResult, rhs: BatchResult) -> Bool {
            lhs.batchId == rhs.batchId && lhs.renamed == rhs.renamed
                && lhs.failed.map(\.fileId) == rhs.failed.map(\.fileId)
        }
    }

    // MARK: - Execute

    /// Executes the actionable rows of a plan. Each successful file move is
    /// immediately recorded (path update + journal row) so a failure midway
    /// never leaves disk and database out of sync (FR-4.7); already-renamed
    /// files stay renamed and are undoable.
    @discardableResult
    public func execute(rows: [RenamePlanRow]) throws -> BatchResult {
        let batchId = UUID().uuidString
        var renamed = 0
        var failed: [(Int64, String)] = []
        let fileManager = FileManager.default

        for row in rows where row.isActionable {
            let oldPath = row.currentPath
            var targetPath = row.targetPath

            do {
                // Runtime re-check: the plan may be stale (FR-4.5: never
                // overwrite). Case-only renames are moves onto "themselves"
                // on case-insensitive APFS and are always allowed.
                let caseOnly = oldPath.lowercased() == targetPath.lowercased()
                if !caseOnly, fileManager.fileExists(atPath: targetPath) {
                    let dir = (targetPath as NSString).deletingLastPathComponent
                    let existing = Set(
                        ((try? fileManager.contentsOfDirectory(atPath: dir)) ?? [])
                            .map { $0.lowercased() })
                    let free = RenamePlanner.suffixed(
                        (targetPath as NSString).lastPathComponent, avoiding: existing)
                    targetPath = (dir as NSString).appendingPathComponent(free)
                }

                try fileManager.moveItem(atPath: oldPath, toPath: targetPath)

                // Disk move succeeded — record it atomically.
                do {
                    try database.writer.write { db in
                        try db.execute(
                            sql: "UPDATE bookFile SET path = ? WHERE id = ?",
                            arguments: [targetPath, row.id])
                        var log = RenameLog(
                            batchId: batchId, fileId: row.id,
                            oldPath: oldPath, newPath: targetPath)
                        try log.insert(db)
                    }
                } catch {
                    // Database failed after the disk move: roll the file back
                    // so disk and database stay consistent.
                    try? fileManager.moveItem(atPath: targetPath, toPath: oldPath)
                    throw error
                }
                renamed += 1
            } catch {
                failed.append((row.id, error.localizedDescription))
            }
        }
        return BatchResult(batchId: batchId, renamed: renamed, failed: failed)
    }

    // MARK: - Undo (FR-4.8)

    public struct UndoableBatch: Sendable, Equatable {
        public var batchId: String
        public var executedAt: Date
        public var fileCount: Int
    }

    /// The most recent non-reverted batch, if any.
    public func lastBatch() throws -> UndoableBatch? {
        try database.writer.read { db in
            guard let latest = try RenameLog
                .filter(Column("revertedFlag") == false)
                .order(Column("executedAt").desc, Column("id").desc)
                .fetchOne(db)
            else { return nil }
            let count = try RenameLog
                .filter(Column("batchId") == latest.batchId && Column("revertedFlag") == false)
                .fetchCount(db)
            return UndoableBatch(
                batchId: latest.batchId, executedAt: latest.executedAt, fileCount: count)
        }
    }

    public struct UndoResult: Sendable, Equatable {
        public var reverted: Int
        public var failed: [(fileId: Int64, error: String)]

        public static func == (lhs: UndoResult, rhs: UndoResult) -> Bool {
            lhs.reverted == rhs.reverted && lhs.failed.map(\.fileId) == rhs.failed.map(\.fileId)
        }
    }

    /// Reverts the most recent batch: every file moves back to its old name,
    /// paths update, and the journal entries are marked reverted.
    @discardableResult
    public func undoLastBatch() throws -> UndoResult {
        guard let batch = try lastBatch() else {
            return UndoResult(reverted: 0, failed: [])
        }
        let entries = try database.writer.read { db in
            try RenameLog
                .filter(Column("batchId") == batch.batchId && Column("revertedFlag") == false)
                .order(Column("id").desc) // reverse order, in case of chains
                .fetchAll(db)
        }

        var reverted = 0
        var failed: [(Int64, String)] = []
        let fileManager = FileManager.default

        for entry in entries {
            do {
                if fileManager.fileExists(atPath: entry.newPath) {
                    try fileManager.moveItem(atPath: entry.newPath, toPath: entry.oldPath)
                } else if !fileManager.fileExists(atPath: entry.oldPath) {
                    throw CocoaError(.fileNoSuchFile)
                }
                try database.writer.write { db in
                    try db.execute(
                        sql: "UPDATE bookFile SET path = ? WHERE id = ?",
                        arguments: [entry.oldPath, entry.fileId])
                    try db.execute(
                        sql: "UPDATE renameLog SET revertedFlag = 1 WHERE id = ?",
                        arguments: [entry.id])
                }
                reverted += 1
            } catch {
                failed.append((entry.fileId, error.localizedDescription))
            }
        }
        return UndoResult(reverted: reverted, failed: failed)
    }
}
