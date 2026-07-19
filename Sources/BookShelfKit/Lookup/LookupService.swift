import Foundation
import GRDB

/// Paces requests to a provider (simple minimum-interval limiter).
actor RateLimiter {
    private let minInterval: Duration
    private var lastRequest: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    init(minInterval: Duration) {
        self.minInterval = minInterval
    }

    func waitTurn() async {
        // Reserve the slot before sleeping: actor reentrancy lets another
        // caller enter during the sleep, and it must queue after this one
        // rather than read the same stale lastRequest.
        let slot: ContinuousClock.Instant
        if let last = lastRequest, last + minInterval > clock.now {
            slot = last + minInterval
        } else {
            slot = clock.now
        }
        lastRequest = slot
        try? await clock.sleep(until: slot)
    }
}

/// How online data lands on a book (FR-3.2).
public enum ApplyPolicy: String, Sendable {
    /// Online data fills empty fields only (default).
    case fillEmpty
    /// Online data overwrites embedded data. Manual edits still win.
    case overwrite
}

public struct LookupOutcome: Sendable {
    public var resolved: [Int64] = []
    /// Books whose candidates were ambiguous → UI shows the picker (FR-3.4).
    public var ambiguous: [Int64: [LookupCandidate]] = [:]
    public var failed: [Int64: String] = [:]
    public var noMatch: [Int64] = []
}

/// Orchestrates online metadata resolution: provider order, rate limiting,
/// retry with backoff, ambiguity detection, field-level application with
/// provenance, and resumable batch state (FR-3.1…3.6).
public final class LookupService: Sendable {
    public static let batchStateKey = "pendingResolveBatch"
    static let similarityFloor = 0.55
    static let autoApplyThreshold = 0.75
    static let ambiguityGap = 0.2

    private let database: AppDatabase
    private let coverCache: CoverCache
    private let providers: [any MetadataProvider]
    private let transport: HTTPTransport
    private let limiter: RateLimiter
    private let maxAttempts: Int

    public init(
        database: AppDatabase,
        coverCache: CoverCache,
        providers: [any MetadataProvider],
        transport: @escaping HTTPTransport = HTTP.live,
        minRequestInterval: Duration = .milliseconds(600),
        maxAttempts: Int = 3
    ) {
        self.database = database
        self.coverCache = coverCache
        self.providers = providers
        self.transport = transport
        self.limiter = RateLimiter(minInterval: minRequestInterval)
        self.maxAttempts = maxAttempts
    }

    /// Standard provider stack: Open Library is primary (keyless); Google
    /// Books is consulted as a fallback when the user supplied an API key.
    public static func standardProviders(googleAPIKey: String?) -> [any MetadataProvider] {
        var providers: [any MetadataProvider] = [OpenLibraryProvider()]
        if let key = googleAPIKey, !key.isEmpty {
            providers.append(GoogleBooksProvider(apiKey: key))
        }
        return providers
    }

    // MARK: - Search

    /// Queries providers in order, returning the first non-empty, scored
    /// candidate list.
    public func candidates(for query: LookupQuery) async throws -> [LookupCandidate] {
        guard !query.isEmpty else { return [] }
        var lastError: Error?
        var anySucceeded = false
        for provider in providers {
            do {
                let results = try await searchWithRetry(provider: provider, query: query)
                anySucceeded = true
                if !results.isEmpty {
                    return score(results, against: query)
                }
            } catch {
                lastError = error
            }
        }
        // A provider that answered with zero hits is a genuine no-match;
        // don't let a later provider's failure turn it into an error.
        if !anySucceeded, let lastError { throw lastError }
        return []
    }

    private func searchWithRetry(provider: any MetadataProvider, query: LookupQuery) async throws -> [LookupCandidate] {
        var attempt = 0
        while true {
            attempt += 1
            await limiter.waitTurn()
            do {
                return try await provider.search(query, transport: transport)
            } catch {
                let transient = (error as? HTTPStatusError)?.isTransient ?? (error is URLError)
                guard transient, attempt < maxAttempts else { throw error }
                // Exponential backoff: 1s, 2s, 4s…
                let delay = Duration.seconds(1 << (attempt - 1))
                try? await Task.sleep(for: delay)
            }
        }
    }

    func score(_ candidates: [LookupCandidate], against query: LookupQuery) -> [LookupCandidate] {
        var scored = candidates.map { candidate in
            var c = candidate
            if let isbn = query.isbn,
               let normalized = Normalizer.extractISBN(isbn),
               candidate.isbn13 == normalized || candidate.isbn10 == normalized {
                c.similarity = 1.0
            } else if let title = query.title, !title.isEmpty {
                c.similarity = Normalizer.tokenSimilarity(title, candidate.title)
            } else {
                c.similarity = 0.5
            }
            return c
        }
        scored.sort { $0.similarity > $1.similarity }
        return scored
    }

    /// The single clear winner, or nil when the result set is ambiguous and
    /// the user must pick (FR-3.4).
    public static func unambiguousBest(_ candidates: [LookupCandidate]) -> LookupCandidate? {
        guard let top = candidates.first, top.similarity >= autoApplyThreshold else {
            return nil
        }
        if candidates.count == 1 { return top }
        let runnerUp = candidates[1].similarity
        return (top.similarity - runnerUp) >= ambiguityGap || top.similarity == 1.0 ? top : nil
    }

    // MARK: - Apply

    /// Applies a candidate to a book, respecting the precedence policy and
    /// manual provenance (manual edits always win), recording provenance for
    /// every field written, and caching the cover.
    public func apply(_ candidate: LookupCandidate, to bookId: Int64, policy: ApplyPolicy) async throws {
        // Fetch cover first (network), outside the write transaction.
        let coverData: Data?
        if let coverURL = candidate.coverURL {
            await limiter.waitTurn()
            coverData = try? await fetchData(from: coverURL)
        } else {
            coverData = nil
        }
        let coverCache = self.coverCache

        try await database.writer.write { db in
            guard var book = try Book.fetchOne(db, key: bookId) else { return }
            let provenance = try ProvenanceRecord
                .filter(ProvenanceRecord.Columns.bookId == bookId)
                .fetchAll(db)
            let sourceByField = Dictionary(uniqueKeysWithValues: provenance.map { ($0.field, $0.source) })

            func canWrite(_ field: String, isEmpty: Bool) -> Bool {
                if sourceByField[field] == .manual { return false }
                return policy == .overwrite || isEmpty
            }

            var written: [String] = []
            if !candidate.title.isEmpty, canWrite("title", isEmpty: sourceByField["title"] == nil) {
                book.title = candidate.title
                book.titleSort = Book.sortKey(forTitle: candidate.title)
                written.append("title")
            }
            if !candidate.authors.isEmpty, canWrite("authors", isEmpty: book.authors.isEmpty) {
                book.authors = candidate.authors
                book.authorSort = Book.sortKey(forAuthors: candidate.authors)
                written.append("authors")
            }
            if let publisher = candidate.publisher, canWrite("publisher", isEmpty: book.publisher == nil) {
                book.publisher = publisher
                written.append("publisher")
            }
            if let year = candidate.year, canWrite("year", isEmpty: book.year == nil) {
                book.year = year
                written.append("year")
            }
            if let language = candidate.language, canWrite("language", isEmpty: book.language == nil) {
                book.language = language
                written.append("language")
            }
            if let isbn13 = candidate.isbn13, canWrite("isbn", isEmpty: book.isbn13 == nil) {
                book.isbn13 = isbn13
                written.append("isbn")
            }
            if let isbn10 = candidate.isbn10, book.isbn10 == nil || policy == .overwrite,
               sourceByField["isbn"] != .manual {
                book.isbn10 = isbn10
                if !written.contains("isbn") { written.append("isbn") }
            }
            if let description = candidate.description,
               canWrite("description", isEmpty: book.bookDescription == nil) {
                book.bookDescription = description
                written.append("description")
            }
            if case let cleaned = TagSanitizer.sanitize(candidate.categories), !cleaned.isEmpty,
               canWrite("tags", isEmpty: book.tags.isEmpty) {
                book.tags = cleaned
                written.append("tags")
            }
            if let coverData, canWrite("cover", isEmpty: book.coverCachePath == nil),
               let gridURL = try? coverCache.store(imageData: coverData, bookId: bookId) {
                book.coverCachePath = gridURL.path
                written.append("cover")
            }

            book.metadataStatus = ScanPipeline.status(for: book)
            book.updatedAt = Date()
            try book.update(db)
            for field in written {
                try ProvenanceRecord(bookId: bookId, field: field, source: candidate.source).save(db)
            }
        }
    }

    private func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await transport(URLRequest(url: url))
        guard response.statusCode == 200 else {
            throw HTTPStatusError(response.statusCode)
        }
        return data
    }

    // MARK: - Batch resolve (FR-3.6: resumable)

    /// Resolves a set of books, checkpointing remaining ids to the settings
    /// table after each book so an interrupted batch can resume.
    ///
    /// `reviewCompleted` controls what happens to books that are already
    /// `.complete`: with `false` a clear winner is auto-applied (which is a
    /// no-op under fill-empty — every field is taken), with `true` their
    /// candidates always go through the picker so the user can re-resolve a
    /// book to a different edition as often as they like.
    public func resolveBatch(
        bookIds: [Int64],
        policy: ApplyPolicy,
        reviewCompleted: Bool = false,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> LookupOutcome {
        var outcome = LookupOutcome()
        var remaining = bookIds
        let total = bookIds.count
        try? database.setSetting(Self.batchStateKey, encodeIds(remaining))

        for (index, bookId) in bookIds.enumerated() {
            defer {
                remaining.removeAll { $0 == bookId }
                try? database.setSetting(Self.batchStateKey,
                                         remaining.isEmpty ? nil : encodeIds(remaining))
                onProgress?(index + 1, total)
            }
            do {
                guard let (book, files) = try await fetchBookWithFiles(bookId) else { continue }
                let query = LookupQuery.forBook(book, files: files)
                let results = try await candidates(for: query)
                let viable = results.filter { $0.similarity >= Self.similarityFloor }
                if viable.isEmpty {
                    outcome.noMatch.append(bookId)
                } else if reviewCompleted, book.metadataStatus == .complete {
                    outcome.ambiguous[bookId] = viable
                } else if let best = Self.unambiguousBest(viable) {
                    try await apply(best, to: bookId, policy: policy)
                    outcome.resolved.append(bookId)
                } else {
                    outcome.ambiguous[bookId] = viable
                }
            } catch {
                outcome.failed[bookId] = "\(error)"
            }
        }
        return outcome
    }

    /// Book ids left over from an interrupted "resolve all" batch.
    public func pendingBatch() -> [Int64] {
        guard let raw = (try? database.setting(Self.batchStateKey)) ?? nil else { return [] }
        return raw.split(separator: ",").compactMap { Int64($0) }
    }

    public func clearPendingBatch() {
        try? database.setSetting(Self.batchStateKey, nil)
    }

    private func encodeIds(_ ids: [Int64]) -> String {
        ids.map(String.init).joined(separator: ",")
    }

    private func fetchBookWithFiles(_ bookId: Int64) async throws -> (Book, [BookFile])? {
        try await database.writer.read { db in
            guard let book = try Book.fetchOne(db, key: bookId) else { return nil }
            let files = try BookFile
                .filter(BookFile.Columns.bookId == bookId)
                .fetchAll(db)
            return (book, files)
        }
    }
}
