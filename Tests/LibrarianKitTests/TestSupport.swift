import Foundation
import XCTest
@testable import LibrarianKit
import LibrarianFixtures

/// Shared helpers. This file contains no test cases (see test-case.md for
/// the catalog); it provides temp directories, databases, and stub types.
extension XCTestCase {
    /// A unique temp directory, removed automatically after the test.
    /// Symlinks are resolved (/var → /private/var) so paths recorded by the
    /// scanner compare equal to paths built from this URL.
    func makeTempDir() throws -> URL {
        var url = FileManager.default.temporaryDirectory
            .appendingPathComponent("librarian-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Canonicalize /var → /private/var; resolvingSymlinksInPath() leaves
        // these system symlinks alone, the canonical-path resource key doesn't.
        if let canonical = try url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            url = URL(fileURLWithPath: canonical, isDirectory: true)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func makeDatabase() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    func makeCoverCache() throws -> CoverCache {
        try CoverCache(directory: makeTempDir())
    }

    func makeScanner() throws -> (scanner: LibraryScanner, database: AppDatabase, coverCache: CoverCache) {
        let database = try makeDatabase()
        let coverCache = try makeCoverCache()
        return (LibraryScanner(database: database, coverCache: coverCache), database, coverCache)
    }
}

/// Configurable stub metadata provider for lookup tests (no network).
struct StubProvider: MetadataProvider {
    let source: MetadataSource
    let handler: @Sendable (LookupQuery) async throws -> [LookupCandidate]

    func search(_ query: LookupQuery) async throws -> [LookupCandidate] {
        try await handler(query)
    }
}

/// Thread-safe recorder for stub providers (call order, counters).
final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        _events.append(event)
    }

    func count(of event: String) -> Int {
        events.filter { $0 == event }.count
    }
}

func makeCandidate(
    id: String = "stub-1",
    source: MetadataSource = .googleBooks,
    title: String,
    authors: [String] = [],
    year: Int? = nil,
    publisher: String? = nil,
    isbn13: String? = nil,
    description: String? = nil,
    similarity: Double
) -> LookupCandidate {
    var metadata = BookMetadata()
    metadata.title = title
    metadata.authors = authors
    metadata.year = year
    metadata.publisher = publisher
    metadata.isbn13 = isbn13
    metadata.description = description
    return LookupCandidate(
        id: id, source: source, metadata: metadata,
        coverURL: nil, titleSimilarity: similarity)
}

/// Inserts a book (+ optional files) and returns it with its id set.
@discardableResult
func insertBook(
    _ database: AppDatabase,
    title: String,
    authors: [String] = [],
    year: Int? = nil,
    publisher: String? = nil,
    isbn13: String? = nil,
    series: String? = nil,
    filePaths: [String] = []
) throws -> Book {
    try database.writer.write { db in
        var book = Book(title: title, authors: authors)
        book.year = year
        book.publisher = publisher
        book.isbn13 = isbn13
        book.series = series
        book.refreshMetadataStatus()
        try book.insert(db)
        for path in filePaths {
            let ext = (path as NSString).pathExtension.lowercased()
            var file = BookFile(
                bookId: book.id!,
                path: path,
                format: BookFormat(rawValue: ext) ?? .epub,
                sizeBytes: 1000,
                modifiedAt: Date())
            try file.insert(db)
        }
        return book
    }
}
