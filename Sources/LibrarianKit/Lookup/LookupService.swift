import Foundation
import GRDB

/// Outcome of resolving one book online (§6.3).
public enum LookupOutcome: Sendable {
    /// Providers responded but nothing matched — not an error.
    case noMatch
    /// A confident match was applied; carries the fields that changed.
    case applied([String])
    /// Ambiguous (multiple candidates / low similarity): the caller shows the
    /// candidate picker (FR-3.4) and applies a choice via `apply(candidate:)`.
    case needsConfirmation([LookupCandidate])
    /// Network/service failure; the batch is resumable (FR-3.6).
    case failed(String)
}

/// Field-precedence policy (FR-3.2).
public enum MergePolicy: String, Sendable {
    /// Online data fills empty fields only (default).
    case fillEmpty = "fill_empty"
    /// Online data overwrites embedded data. Manual edits still always win.
    case overwrite
}

/// Minimum-interval rate limiter, one per provider (FR-3.6). Actor-isolated
/// so concurrent lookups queue instead of racing.
actor RateLimiter {
    private let minInterval: TimeInterval
    private var nextSlot = Date.distantPast

    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    func waitTurn() async throws {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(minInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

/// Online metadata resolution (§6.3 step 2): explicit, per book / selection /
/// "resolve all missing" — never automatic on scan (FR-3.1).
public final class LookupService: @unchecked Sendable {
    private let database: AppDatabase
    private let coverCache: CoverCache
    private let providers: [MetadataProvider]
    private var limiters: [MetadataSource: RateLimiter] = [:]
    /// Auto-apply threshold: below this similarity a picker is required.
    private let confidenceThreshold: Double
    /// Base of the exponential retry backoff; injectable for tests.
    private let backoffBase: TimeInterval

    public init(
        database: AppDatabase,
        coverCache: CoverCache,
        providers: [MetadataProvider] = [GoogleBooksProvider(), OpenLibraryProvider()],
        requestInterval: TimeInterval = 1.0,
        confidenceThreshold: Double = 0.6,
        backoffBase: TimeInterval = 1.0
    ) {
        self.database = database
        self.coverCache = coverCache
        self.providers = providers
        self.confidenceThreshold = confidenceThreshold
        self.backoffBase = backoffBase
        for provider in providers {
            limiters[provider.source] = RateLimiter(minInterval: requestInterval)
        }
    }

    // MARK: - Query building

    /// ISBN first; else title + author; the book's identity already includes
    /// filename inference from scan time (§6.3 step 3).
    public static func query(for book: Book) -> LookupQuery {
        if let isbn = book.isbn13 ?? book.isbn10 {
            return LookupQuery(isbn: isbn, title: book.title, author: book.authors.first)
        }
        return LookupQuery(title: book.title, author: book.authors.first)
    }

    // MARK: - Search

    /// Queries providers in settings order until one returns candidates.
    /// Distinguishes "no match" (all providers empty) from errors (FR-3.6,
    /// retry with backoff on transient failures).
    public func searchCandidates(for book: Book) async -> Result<[LookupCandidate], Error> {
        let query = Self.query(for: book)
        guard !query.isEmpty else { return .success([]) }

        var lastError: Error?
        for provider in orderedProviders() {
            do {
                let candidates = try await searchWithRetry(provider: provider, query: query)
                if !candidates.isEmpty {
                    return .success(candidates.sorted { $0.titleSimilarity > $1.titleSimilarity })
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { return .failure(lastError) }
        return .success([])
    }

    private func orderedProviders() -> [MetadataProvider] {
        let order = ((try? database.setting(SettingKey.providerOrder)) ?? nil)?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        guard !order.isEmpty else { return providers }
        let bySource = Dictionary(uniqueKeysWithValues: providers.map { ($0.source.rawValue, $0) })
        var sorted = order.compactMap { bySource[$0] }
        for provider in providers where !sorted.contains(where: { $0.source == provider.source }) {
            sorted.append(provider)
        }
        return sorted
    }

    private func searchWithRetry(
        provider: MetadataProvider, query: LookupQuery, attempts: Int = 3
    ) async throws -> [LookupCandidate] {
        var lastError: Error = LookupError.cancelled
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            try await limiters[provider.source]?.waitTurn()
            do {
                return try await provider.search(query)
            } catch {
                lastError = error
                // Exponential backoff on transient failures (FR-3.6).
                let transient: Bool
                if case LookupError.httpStatus(let code) = error {
                    transient = code == 429 || code >= 500
                } else {
                    transient = (error as? URLError) != nil
                }
                guard transient, attempt < attempts - 1 else { throw error }
                let backoff = backoffBase * pow(2.0, Double(attempt)) // base, 2×base
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
        throw lastError
    }

    // MARK: - Resolution

    /// Resolves one book: auto-applies a single confident match, otherwise
    /// returns candidates for the picker (FR-3.4).
    public func resolve(bookId: Int64) async -> LookupOutcome {
        guard let book = try? await database.writer.read({ try Book.fetchOne($0, key: bookId) })
        else { return .failed("Book no longer exists") }

        let result = await searchCandidates(for: book)
        switch result {
        case .failure(let error):
            return .failed(error.localizedDescription)
        case .success(let candidates):
            guard let top = candidates.first else { return .noMatch }
            let unambiguous = candidates.count == 1
                || top.titleSimilarity - (candidates.dropFirst().first?.titleSimilarity ?? 0) >= 0.3
            let confident = top.titleSimilarity >= confidenceThreshold
            let byISBN = Self.query(for: book).isbn != nil

            if confident && (unambiguous || byISBN) {
                do {
                    let fields = try await apply(candidate: top, toBookId: bookId)
                    return .applied(fields)
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            return .needsConfirmation(candidates)
        }
    }

    /// Batch resolve (FR-3.1 "resolve all missing", FR-3.6 resumable): books
    /// are processed sequentially under the rate limit; a failure on one book
    /// records the failure and continues, and already-applied books persist,
    /// so re-running the batch resumes where it left off.
    public func resolveAll(
        bookIds: [Int64],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int64: LookupOutcome] {
        var outcomes: [Int64: LookupOutcome] = [:]
        for (index, bookId) in bookIds.enumerated() {
            if Task.isCancelled {
                outcomes[bookId] = .failed(LookupError.cancelled.localizedDescription)
                continue
            }
            outcomes[bookId] = await resolve(bookId: bookId)
            progress?(index + 1, bookIds.count)
        }
        return outcomes
    }

    // MARK: - Apply

    /// Applies a candidate to a book under the configured merge policy
    /// (FR-3.2): fill-empty by default, overwrite when enabled; fields whose
    /// provenance is `manual` are never touched. Returns changed fields.
    @discardableResult
    public func apply(candidate: LookupCandidate, toBookId bookId: Int64) async throws -> [String] {
        let rawPolicy = (try? database.setting(SettingKey.metadataOverwrite)) ?? nil
        let policy = rawPolicy.flatMap(MergePolicy.init(rawValue:)) ?? .fillEmpty

        // Cover download happens outside the write transaction.
        var coverData: Data?
        if let coverURL = candidate.coverURL {
            coverData = try? await ProviderHTTP.get(coverURL)
        }

        let changed: [String] = try await database.writer.write { db in
            guard var book = try Book.fetchOne(db, key: bookId) else {
                throw GroupCommands.GroupError.booksNotFound
            }
            let provenance = try Provenance
                .filter(Column("bookId") == bookId)
                .fetchAll(db)
            let manualFields = Set(provenance.filter { $0.source == .manual }.map(\.field))

            var changed: [String] = []
            let m = candidate.metadata

            func update<T>(
                _ field: String, _ keyPath: WritableKeyPath<Book, T?>, _ value: T?
            ) {
                guard let value else { return }
                guard !manualFields.contains(field) else { return }
                let isEmpty = book[keyPath: keyPath] == nil
                guard policy == .overwrite || isEmpty else { return }
                book[keyPath: keyPath] = value
                changed.append(field)
            }

            if let title = m.title, !manualFields.contains("title"),
               policy == .overwrite || book.title.isEmpty {
                if book.title != title {
                    book.title = title
                    book.titleSort = Book.sortKey(forTitle: title)
                    changed.append("title")
                }
            }
            if !m.authors.isEmpty, !manualFields.contains("authors"),
               policy == .overwrite || book.authors.isEmpty {
                if book.authors != m.authors {
                    book.authors = m.authors
                    book.authorSort = Book.sortKey(forAuthors: m.authors)
                    changed.append("authors")
                }
            }
            update("publisher", \.publisher, m.publisher)
            update("year", \.year, m.year)
            update("language", \.language, m.language)
            update("isbn10", \.isbn10, m.isbn10)
            update("isbn13", \.isbn13, m.isbn13)
            update("description", \.bookDescription, m.description)
            update("series", \.series, m.series)
            update("series_index", \.seriesIndex, m.seriesIndex)

            if !changed.isEmpty {
                book.refreshMetadataStatus()
                book.updatedAt = Date()
                try book.save(db)
                for field in changed {
                    try Provenance(bookId: bookId, field: field, source: candidate.source).save(db)
                }
            }
            return changed
        }

        // Cover: fill when absent, replace on overwrite — never a manual cover.
        var allChanged = changed
        if let coverData {
            let state = try await database.writer.read { db -> (hasCover: Bool, manual: Bool)? in
                guard let book = try Book.fetchOne(db, key: bookId) else { return nil }
                let coverProvenance = try Provenance
                    .filter(Column("bookId") == bookId && Column("field") == "cover")
                    .fetchOne(db)
                return (book.coverCachePath != nil, coverProvenance?.source == .manual)
            }
            if let state, !state.manual, (!state.hasCover || policy == .overwrite) {
                let path = try coverCache.store(coverData, forBookId: bookId)
                try await database.writer.write { db in
                    try db.execute(
                        sql: "UPDATE book SET coverCachePath = ?, updatedAt = ? WHERE id = ?",
                        arguments: [path, Date(), bookId])
                    try Provenance(bookId: bookId, field: "cover", source: candidate.source).save(db)
                }
                allChanged.append("cover")
            }
        }
        return allChanged
    }
}
