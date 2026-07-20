import XCTest
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: LOOK-01 … LOOK-18 (test-case.md). Providers are stubbed — the
/// suite never touches the network.
final class LookupTests: XCTestCase {
    // MARK: Provider parsing

    // LOOK-01
    func testGoogleBooksParse() throws {
        let json = """
        {"items":[{"id":"abc123","volumeInfo":{
            "title":"Dune","authors":["Frank Herbert"],"publisher":"Ace",
            "publishedDate":"1990-09-01","description":"Spice.","language":"en",
            "industryIdentifiers":[
                {"type":"ISBN_13","identifier":"9780441172719"},
                {"type":"ISBN_10","identifier":"0441172717"}],
            "imageLinks":{"thumbnail":"http://books.google.com/thumb.jpg"}}}]}
        """
        let candidates = GoogleBooksProvider.parse(Data(json.utf8), queryTitle: "Dune")
        XCTAssertEqual(candidates.count, 1)
        let c = candidates[0]
        XCTAssertEqual(c.metadata.title, "Dune")
        XCTAssertEqual(c.metadata.authors, ["Frank Herbert"])
        XCTAssertEqual(c.metadata.isbn13, "9780441172719")
        XCTAssertEqual(c.metadata.isbn10, "0441172717")
        XCTAssertEqual(c.metadata.year, 1990)
        XCTAssertEqual(c.coverURL?.scheme, "https", "covers must be fetched over https")
        XCTAssertEqual(c.titleSimilarity, 1.0)
        XCTAssertEqual(c.source, .googleBooks)
    }

    // LOOK-02
    func testGoogleBooksSearchURLByISBN() {
        let url = GoogleBooksProvider().searchURL(
            for: LookupQuery(isbn: "9780441172719", title: "Dune"))
        XCTAssertTrue(url!.absoluteString.contains("isbn:9780441172719"))
    }

    // LOOK-03
    func testGoogleBooksSearchURLTitleAuthor() {
        let url = GoogleBooksProvider().searchURL(
            for: LookupQuery(title: "Dune", author: "Frank Herbert"))!
        let query = url.absoluteString.removingPercentEncoding!
        XCTAssertTrue(query.contains("intitle:Dune"))
        XCTAssertTrue(query.contains("inauthor:Frank Herbert"))
    }

    // LOOK-04
    func testOpenLibraryParse() throws {
        let json = """
        {"docs":[{"key":"/works/OL893415W","title":"Dune",
            "author_name":["Frank Herbert"],"first_publish_year":1965,
            "publisher":["Chilton"],"isbn":["9780441172719"],
            "language":["eng"],"cover_i":12345}]}
        """
        let candidates = OpenLibraryProvider.parse(Data(json.utf8), queryTitle: "Dune")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].metadata.year, 1965)
        XCTAssertEqual(candidates[0].metadata.isbn13, "9780441172719")
        XCTAssertEqual(
            candidates[0].coverURL?.absoluteString,
            "https://covers.openlibrary.org/b/id/12345-L.jpg")
        XCTAssertEqual(candidates[0].source, .openLibrary)
    }

    // LOOK-05
    func testOpenLibrarySearchURL() {
        let url = OpenLibraryProvider().searchURL(
            for: LookupQuery(title: "Dune", author: "Frank Herbert"))!
        let absolute = url.absoluteString.removingPercentEncoding!
        XCTAssertTrue(absolute.contains("search.json"))
        XCTAssertTrue(absolute.contains("title=Dune"))
        XCTAssertTrue(absolute.contains("author=Frank Herbert"))
        XCTAssertTrue(absolute.contains("limit=10"))
    }

    // LOOK-06
    func testQueryPrefersISBN() {
        var book = Book(title: "Dune", authors: ["Frank Herbert"])
        book.isbn13 = "9780441172719"
        XCTAssertEqual(LookupService.query(for: book).isbn, "9780441172719")
        book.isbn13 = nil
        let query = LookupService.query(for: book)
        XCTAssertNil(query.isbn)
        XCTAssertEqual(query.title, "Dune")
        XCTAssertEqual(query.author, "Frank Herbert")
    }

    // MARK: Service orchestration

    private func makeService(
        database: AppDatabase,
        providers: [MetadataProvider]
    ) throws -> LookupService {
        LookupService(
            database: database,
            coverCache: try makeCoverCache(),
            providers: providers,
            requestInterval: 0,
            backoffBase: 0.01)
    }

    // LOOK-07
    func testProviderOrderSetting() async throws {
        let database = try makeDatabase()
        let book = try insertBook(database, title: "Dune", authors: ["Frank Herbert"])
        let recorder = CallRecorder()
        let google = StubProvider(source: .googleBooks) { _ in
            recorder.record("google"); return []
        }
        let openLibrary = StubProvider(source: .openLibrary) { _ in
            recorder.record("openlibrary"); return []
        }
        try database.setSetting(SettingKey.providerOrder, to: "open_library,google_books")
        let service = try makeService(database: database, providers: [google, openLibrary])
        _ = await service.searchCandidates(for: book)
        XCTAssertEqual(recorder.events, ["openlibrary", "google"])
    }

    // LOOK-08
    func testFallbackToSecondProvider() async throws {
        let database = try makeDatabase()
        let book = try insertBook(database, title: "Dune", authors: ["Frank Herbert"])
        let google = StubProvider(source: .googleBooks) { _ in [] }
        let openLibrary = StubProvider(source: .openLibrary) { _ in
            [makeCandidate(source: .openLibrary, title: "Dune", similarity: 1.0)]
        }
        let service = try makeService(database: database, providers: [google, openLibrary])
        let result = await service.searchCandidates(for: book)
        let candidates = try result.get()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].source, .openLibrary)
    }

    // LOOK-09
    func testNoMatchDistinctFromError() async throws {
        let database = try makeDatabase()
        let book = try insertBook(database, title: "Very Obscure", authors: ["Nobody"])

        let empty = StubProvider(source: .googleBooks) { _ in [] }
        var service = try makeService(database: database, providers: [empty])
        var outcome = await service.resolve(bookId: book.id!)
        guard case .noMatch = outcome else {
            return XCTFail("expected noMatch, got \(outcome)")
        }

        let failing = StubProvider(source: .googleBooks) { _ in
            throw LookupError.httpStatus(404)
        }
        service = try makeService(database: database, providers: [failing])
        outcome = await service.resolve(bookId: book.id!)
        guard case .failed = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
    }

    // LOOK-10
    func testAutoApplyConfidentMatch() async throws {
        let database = try makeDatabase()
        let book = try insertBook(database, title: "Dune", authors: ["Frank Herbert"])
        let provider = StubProvider(source: .googleBooks) { _ in
            [makeCandidate(title: "Dune", authors: ["Frank Herbert"],
                           year: 1965, publisher: "Chilton",
                           isbn13: "9780441172719", similarity: 1.0)]
        }
        let service = try makeService(database: database, providers: [provider])
        let outcome = await service.resolve(bookId: book.id!)
        guard case .applied(let fields) = outcome else {
            return XCTFail("expected applied, got \(outcome)")
        }
        XCTAssertTrue(fields.contains("year"))
        let updated = try await database.writer.read { db in try Book.fetchOne(db, key: book.id!)! }
        XCTAssertEqual(updated.year, 1965)
        XCTAssertEqual(updated.isbn13, "9780441172719")
        XCTAssertEqual(
            try database.provenance(forBook: book.id!)["year"]?.source, .googleBooks)
    }

    // LOOK-11
    func testAmbiguousNeedsConfirmation() async throws {
        let database = try makeDatabase()
        let book = try insertBook(database, title: "Dune", authors: ["Frank Herbert"])
        let provider = StubProvider(source: .googleBooks) { _ in
            [
                makeCandidate(id: "c1", title: "Dune", similarity: 0.9),
                makeCandidate(id: "c2", title: "Dune Deluxe", similarity: 0.8),
            ]
        }
        let service = try makeService(database: database, providers: [provider])
        let outcome = await service.resolve(bookId: book.id!)
        guard case .needsConfirmation(let candidates) = outcome else {
            return XCTFail("expected needsConfirmation, got \(outcome)")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    // LOOK-12
    func testLowSimilarityNeedsConfirmation() async throws {
        let database = try makeDatabase()
        let book = try insertBook(database, title: "Dune", authors: ["Frank Herbert"])
        let provider = StubProvider(source: .googleBooks) { _ in
            [makeCandidate(title: "Cooking For Beginners", similarity: 0.1)]
        }
        let service = try makeService(database: database, providers: [provider])
        let outcome = await service.resolve(bookId: book.id!)
        guard case .needsConfirmation = outcome else {
            return XCTFail("expected needsConfirmation, got \(outcome)")
        }
    }

    // LOOK-13
    func testFillEmptyPolicy() async throws {
        let database = try makeDatabase()
        let book = try insertBook(
            database, title: "Dune", authors: ["Frank Herbert"], year: 1965)
        let service = try makeService(database: database, providers: [])
        let candidate = makeCandidate(
            title: "Dune", year: 1990, publisher: "Ace", similarity: 1.0)
        let changed = try await service.apply(candidate: candidate, toBookId: book.id!)

        XCTAssertTrue(changed.contains("publisher"), "empty field is filled")
        XCTAssertFalse(changed.contains("year"), "existing field is kept under fill_empty")
        let updated = try await database.writer.read { db in try Book.fetchOne(db, key: book.id!)! }
        XCTAssertEqual(updated.year, 1965)
        XCTAssertEqual(updated.publisher, "Ace")
    }

    // LOOK-14
    func testOverwritePolicy() async throws {
        let database = try makeDatabase()
        try database.setSetting(SettingKey.metadataOverwrite, to: MergePolicy.overwrite.rawValue)
        let book = try insertBook(
            database, title: "Dune", authors: ["Frank Herbert"], year: 1965)
        let service = try makeService(database: database, providers: [])
        let candidate = makeCandidate(title: "Dune", year: 1990, similarity: 1.0)
        let changed = try await service.apply(candidate: candidate, toBookId: book.id!)

        XCTAssertTrue(changed.contains("year"))
        let updated = try await database.writer.read { db in try Book.fetchOne(db, key: book.id!)! }
        XCTAssertEqual(updated.year, 1990)
    }

    // LOOK-15
    func testManualFieldsNeverOverwritten() async throws {
        let database = try makeDatabase()
        try database.setSetting(SettingKey.metadataOverwrite, to: MergePolicy.overwrite.rawValue)
        let book = try insertBook(
            database, title: "Dune", authors: ["Frank Herbert"], year: 1965)
        try database.recordProvenance(bookId: book.id!, fields: ["year"], source: .manual)

        let service = try makeService(database: database, providers: [])
        let candidate = makeCandidate(title: "Dune", year: 1990, similarity: 1.0)
        let changed = try await service.apply(candidate: candidate, toBookId: book.id!)

        XCTAssertFalse(changed.contains("year"))
        let updated = try await database.writer.read { db in try Book.fetchOne(db, key: book.id!)! }
        XCTAssertEqual(updated.year, 1965, "manual edits always win (FR-3.2)")
        XCTAssertEqual(try database.provenance(forBook: book.id!)["year"]?.source, .manual)
    }

    // LOOK-16
    func testRetryWithBackoffOnTransientError() async throws {
        let database = try makeDatabase()
        let book = try insertBook(database, title: "Dune", authors: ["Frank Herbert"])
        let recorder = CallRecorder()
        let flaky = StubProvider(source: .googleBooks) { _ in
            recorder.record("call")
            if recorder.count(of: "call") <= 2 {
                throw LookupError.httpStatus(500)
            }
            return [makeCandidate(title: "Dune", year: 1965, similarity: 1.0)]
        }
        let service = try makeService(database: database, providers: [flaky])
        let outcome = await service.resolve(bookId: book.id!)
        guard case .applied = outcome else {
            return XCTFail("expected applied after retries, got \(outcome)")
        }
        XCTAssertEqual(recorder.count(of: "call"), 3)
    }

    // LOOK-17
    func testRateLimiterSpacesRequests() async throws {
        let limiter = RateLimiter(minInterval: 0.2)
        let start = Date()
        try await limiter.waitTurn()
        try await limiter.waitTurn()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.19)
    }

    // LOOK-18
    func testBatchResolveContinuesAfterFailure() async throws {
        let database = try makeDatabase()
        let bad = try insertBook(database, title: "Failing Book", authors: ["X"])
        let good = try insertBook(database, title: "Dune", authors: ["Frank Herbert"])
        let provider = StubProvider(source: .googleBooks) { query in
            if query.title == "Failing Book" {
                throw LookupError.httpStatus(404)
            }
            return [makeCandidate(title: "Dune", year: 1965, similarity: 1.0)]
        }
        let service = try makeService(database: database, providers: [provider])
        let outcomes = await service.resolveAll(bookIds: [bad.id!, good.id!])

        guard case .failed = outcomes[bad.id!] else {
            return XCTFail("expected failure for the bad book")
        }
        guard case .applied = outcomes[good.id!] else {
            return XCTFail("expected the batch to continue and apply the good book")
        }
    }
}
