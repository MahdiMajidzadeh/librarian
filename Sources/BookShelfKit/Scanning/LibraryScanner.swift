import Foundation
import GRDB

// MARK: - Progress & results

public struct ScanProgress: Sendable, Equatable {
    public enum Phase: Sendable { case enumerating, processing, finished }
    public var phase: Phase
    public var processed: Int
    public var total: Int

    public init(phase: Phase, processed: Int, total: Int) {
        self.phase = phase
        self.processed = processed
        self.total = total
    }
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

/// A new file after preparation (parsing, seed computation). Preparation runs
/// outside database transactions so expensive work (PDF rendering, zip
/// reads) never blocks writes.
public struct PreparedFile: Sendable {
    public let file: ScannedFile
    public let seed: GroupingSeed
    public let metadata: EmbeddedMetadata?
    public let parseErrorNote: String?

    public init(file: ScannedFile, seed: GroupingSeed,
                metadata: EmbeddedMetadata? = nil, parseErrorNote: String? = nil) {
        self.file = file
        self.seed = seed
        self.metadata = metadata
        self.parseErrorNote = parseErrorNote
    }

    /// Filename-only preparation (no embedded parsing).
    public static func filenameOnly(_ file: ScannedFile) -> PreparedFile {
        PreparedFile(file: file, seed: .fromFilename(file.url))
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

    /// Runs outside the write transaction for each new file: parse embedded
    /// metadata, compute the grouping seed.
    public typealias FilePreparer = @Sendable (_ file: ScannedFile) -> PreparedFile

    /// Called inside the write transaction for each new file to produce its
    /// book. The default creates one book per file titled after the filename
    /// stem; the scan pipeline supplies grouping + metadata application.
    public typealias BookAssigner = (_ db: Database, _ prepared: PreparedFile) throws -> Int64

    private let prepare: FilePreparer
    private let assignBook: BookAssigner

    public init(database: AppDatabase,
                prepare: FilePreparer? = nil,
                assignBook: BookAssigner? = nil) {
        self.database = database
        self.prepare = prepare ?? { PreparedFile.filenameOnly($0) }
        self.assignBook = assignBook ?? Self.defaultAssigner
    }

    public static let defaultAssigner: BookAssigner = { db, prepared in
        var book = Book(title: prepared.file.url.deletingPathExtension().lastPathComponent)
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
            case new(PreparedFile)
        }

        for chunk in files.chunked(into: 64) {
            var actions: [Action] = []
            var newFiles: [ScannedFile] = []
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
                    newFiles.append(file)
                }
            }

            // Parse new files concurrently, outside the write transaction.
            if !newFiles.isEmpty {
                let prepare = self.prepare
                let prepared = await withTaskGroup(of: PreparedFile.self) { group in
                    for file in newFiles {
                        group.addTask { prepare(file) }
                    }
                    var results: [PreparedFile] = []
                    for await item in group {
                        results.append(item)
                    }
                    return results
                }
                actions.append(contentsOf: prepared.map { .new($0) })
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
                    case .new(let prepared):
                        let bookId = try assignBook(db, prepared)
                        var record = BookFile(
                            bookId: bookId,
                            path: prepared.file.url.path,
                            format: prepared.file.format,
                            sizeBytes: prepared.file.sizeBytes,
                            modifiedAt: prepared.file.modifiedAt
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
