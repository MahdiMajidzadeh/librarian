import Foundation
import GRDB

// MARK: - Progress & results

public struct ScanProgress: Sendable, Equatable {
    public enum Phase: Sendable { case enumerating, processing, finished }
    public var phase: Phase
    public var processed: Int
    public var total: Int
}

public struct ScanResult: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var unchanged = 0
    public var missing = 0
    public var rediscovered = 0
}

/// A file found on disk during enumeration.
public struct ScannedFile: Sendable {
    public let url: URL
    public let format: BookFormat
    public let sizeBytes: Int64
    public let modifiedAt: Date

    public var contentKey: String {
        BookFile.contentKey(sizeBytes: sizeBytes, modifiedAt: modifiedAt)
    }
}

// MARK: - Scanner

/// Recursively scans the library root, keeping the database in sync with disk.
///
/// - Incremental: files keyed by path + size + mtime; unchanged files are not
///   re-processed and their metadata is never discarded (FR-1.4).
/// - Files gone from disk are flagged missing, never silently removed (FR-1.5).
public final class LibraryScanner {
    private let database: AppDatabase

    /// Called for each new or content-changed file to produce/refresh its book.
    /// Replaced by the grouping + metadata pipeline in later milestones; the
    /// default creates one book per file titled after the filename stem.
    public typealias BookAssigner = (_ db: Database, _ file: ScannedFile) throws -> Int64

    private let assignBook: BookAssigner

    public init(database: AppDatabase, assignBook: BookAssigner? = nil) {
        self.database = database
        self.assignBook = assignBook ?? Self.defaultAssigner
    }

    public static let defaultAssigner: BookAssigner = { db, file in
        var book = Book(title: file.url.deletingPathExtension().lastPathComponent)
        try book.insert(db)
        return book.id!
    }

    // MARK: Enumeration

    /// Lists candidate ebook files under `root`, skipping hidden files and
    /// ignored extensions.
    public static func enumerateFiles(
        root: URL,
        ignoredExtensions: Set<String> = []
    ) -> [ScannedFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [ScannedFile] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard let format = BookFormat(rawValue: ext), !ignoredExtensions.contains(ext) else { continue }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { continue }
            files.append(ScannedFile(
                url: url.standardizedFileURL,
                format: format,
                sizeBytes: Int64(size),
                modifiedAt: modified
            ))
        }
        return files
    }

    // MARK: Scan

    @discardableResult
    public func scan(
        root: URL,
        ignoredExtensions: Set<String> = [],
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        onProgress?(ScanProgress(phase: .enumerating, processed: 0, total: 0))
        let files = Self.enumerateFiles(root: root, ignoredExtensions: ignoredExtensions)
        let total = files.count

        // Snapshot of what the database currently knows.
        let known = try await database.writer.read { db in
            try BookFile.fetchAll(db)
        }
        var knownByPath = Dictionary(uniqueKeysWithValues: known.map { ($0.path, $0) })

        var result = ScanResult()
        var processed = 0
        let rootPath = root.standardizedFileURL.path

        // Process in modest batches so progress stays live and transactions stay small.
        // The disk-vs-database diff is computed outside the write closure
        // (which is @Sendable and cannot mutate captured state).
        enum Action: Sendable {
            case rediscovered(BookFile)
            case changed(BookFile, ScannedFile)
            case new(ScannedFile)
        }

        for chunk in files.chunked(into: 64) {
            var actions: [Action] = []
            for file in chunk {
                if let existing = knownByPath.removeValue(forKey: file.url.path) {
                    if existing.contentKey == file.contentKey {
                        if existing.missingFlag {
                            actions.append(.rediscovered(existing))
                        } else {
                            result.unchanged += 1
                        }
                    } else {
                        actions.append(.changed(existing, file))
                    }
                } else {
                    actions.append(.new(file))
                }
            }

            let plan = actions
            try await database.writer.write { [assignBook] db in
                for action in plan {
                    switch action {
                    case .rediscovered(var file):
                        file.missingFlag = false
                        try file.update(db)
                    case .changed(var record, let file):
                        record.sizeBytes = file.sizeBytes
                        record.modifiedAt = file.modifiedAt
                        record.contentKey = file.contentKey
                        record.missingFlag = false
                        try record.update(db)
                    case .new(let file):
                        let bookId = try assignBook(db, file)
                        var record = BookFile(
                            bookId: bookId,
                            path: file.url.path,
                            format: file.format,
                            sizeBytes: file.sizeBytes,
                            modifiedAt: file.modifiedAt
                        )
                        try record.insert(db)
                    }
                }
            }
            for action in plan {
                switch action {
                case .rediscovered: result.rediscovered += 1
                case .changed: result.updated += 1
                case .new: result.added += 1
                }
            }
            processed += chunk.count
            onProgress?(ScanProgress(phase: .processing, processed: processed, total: total))
        }

        // Everything still in `knownByPath` under this root was not seen on disk.
        let vanished = knownByPath.values.filter { !$0.missingFlag && $0.path.hasPrefix(rootPath + "/") }
        if !vanished.isEmpty {
            try await database.writer.write { db in
                for var file in vanished {
                    file.missingFlag = true
                    try file.update(db)
                }
            }
        }
        result.missing = vanished.count

        onProgress?(ScanProgress(phase: .finished, processed: total, total: total))
        return result
    }

    /// Explicitly removes all files flagged missing, deleting books left with
    /// no files (FR-1.5: purge is a user action, never automatic).
    @discardableResult
    public func purgeMissing() async throws -> Int {
        try await database.writer.write { db in
            let missing = try BookFile
                .filter(BookFile.Columns.missingFlag == true)
                .fetchAll(db)
            let bookIds = Set(missing.map(\.bookId))
            for file in missing {
                try file.delete(db)
            }
            for bookId in bookIds {
                let remaining = try BookFile
                    .filter(BookFile.Columns.bookId == bookId)
                    .fetchCount(db)
                if remaining == 0 {
                    _ = try Book.deleteOne(db, key: bookId)
                }
            }
            return missing.count
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
