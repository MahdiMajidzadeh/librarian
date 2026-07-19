import Foundation
import GRDB
import BookShelfKit

/// Serial transport stub: scripted (matcher → response) pairs plus a call log.
final class TransportStub: @unchecked Sendable {
    struct Call { let url: String }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var handler: (URLRequest) throws -> (Data, Int) = { _ in (Data("{}".utf8), 200) }

    var transport: HTTPTransport {
        { [self] request in
            lock.lock()
            calls.append(Call(url: request.url?.absoluteString ?? ""))
            lock.unlock()
            let (data, status) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }
}

private let openLibraryDuneJSON = """
{"docs": [
  {"key": "/works/OL893415W", "title": "Dune", "author_name": ["Frank Herbert"],
   "first_publish_year": 1965, "isbn": ["9780441172719", "0441172717"],
   "publisher": ["Chilton Books"], "language": ["eng"],
   "subject": ["Science fiction", "Deserts"], "cover_i": 12345,
   "number_of_pages_median": 412},
  {"key": "/works/OL999W", "title": "Dune Messiah", "author_name": ["Frank Herbert"],
   "first_publish_year": 1969}
]}
"""

private let googleBooksDuneJSON = """
{"items": [
  {"id": "gb1", "volumeInfo": {
    "title": "Dune", "authors": ["Frank Herbert"], "publisher": "Ace",
    "publishedDate": "1965-08-01", "description": "Spice.",
    "industryIdentifiers": [{"type": "ISBN_13", "identifier": "9780441172719"}],
    "pageCount": 412, "categories": ["Fiction"], "language": "en",
    "imageLinks": {"thumbnail": "http://books.google.com/cover.jpg"}}}
]}
"""

func lookupTests(_ runner: TestRunner) async {
    func makeService(_ stub: TransportStub, googleKey: String? = nil,
                     db: AppDatabase? = nil) throws -> (LookupService, AppDatabase, URL) {
        let database = try db ?? AppDatabase.inMemory()
        let coversDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookshelf-covers-\(UUID().uuidString)")
        let cache = try CoverCache(directory: coversDir)
        let service = LookupService(
            database: database,
            coverCache: cache,
            providers: LookupService.standardProviders(googleAPIKey: googleKey),
            transport: stub.transport,
            minRequestInterval: .zero)
        return (service, database, coversDir)
    }

    await runner.run("open library: parses docs into scored candidates") {
        let stub = TransportStub()
        stub.handler = { _ in (Data(openLibraryDuneJSON.utf8), 200) }
        let (service, _, _) = try makeService(stub)

        let results = try await service.candidates(
            for: LookupQuery(title: "Dune", authors: ["Frank Herbert"]))
        expectEqual(results.count, 2)
        let top = results[0]
        expectEqual(top.title, "Dune")
        expectEqual(top.source, .openLibrary)
        expectEqual(top.isbn13, "9780441172719")
        expectEqual(top.isbn10, "0441172717")
        expectEqual(top.year, 1965)
        expectEqual(top.coverURL?.absoluteString, "https://covers.openlibrary.org/b/id/12345-L.jpg")
        expect(top.similarity > results[1].similarity, "exact title should outscore Dune Messiah")
        expect(stub.calls[0].url.contains("openlibrary.org/search.json"))
        expect(stub.calls[0].url.contains("title=Dune"))
    }

    await runner.run("isbn query hits isbn endpoint and scores 1.0") {
        let stub = TransportStub()
        stub.handler = { _ in (Data(openLibraryDuneJSON.utf8), 200) }
        let (service, _, _) = try makeService(stub)
        let results = try await service.candidates(for: LookupQuery(isbn: "9780441172719"))
        expect(stub.calls[0].url.contains("isbn=9780441172719"))
        expectEqual(results.first?.similarity, 1.0)
    }

    await runner.run("google books used only when key present") {
        let stubNoKey = TransportStub()
        stubNoKey.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("openlibrary") { return (Data("{\"docs\": []}".utf8), 200) }
            return (Data(googleBooksDuneJSON.utf8), 200)
        }
        let (serviceNoKey, _, _) = try makeService(stubNoKey)
        let empty = try await serviceNoKey.candidates(for: LookupQuery(title: "Dune"))
        expectEqual(empty.count, 0, "without key, only Open Library should be tried")
        expect(stubNoKey.calls.allSatisfy { $0.url.contains("openlibrary") })

        let stubWithKey = TransportStub()
        stubWithKey.handler = stubNoKey.handler
        let (serviceWithKey, _, _) = try makeService(stubWithKey, googleKey: "test-key")
        let results = try await serviceWithKey.candidates(for: LookupQuery(title: "Dune"))
        expectEqual(results.first?.source, .googleBooks)
        expectEqual(results.first?.description, "Spice.")
        expect(results.first?.coverURL?.absoluteString.hasPrefix("https://") == true,
               "cover URL must be upgraded to https")
        expect(stubWithKey.calls.contains { $0.url.contains("googleapis.com") && $0.url.contains("key=test-key") })
    }

    await runner.run("retry with backoff on 429 then success") {
        let stub = TransportStub()
        let counter = Counter()
        stub.handler = { _ in
            if counter.next() == 1 { return (Data(), 429) }
            return (Data(openLibraryDuneJSON.utf8), 200)
        }
        let (service, _, _) = try makeService(stub)
        let results = try await service.candidates(for: LookupQuery(title: "Dune"))
        expectEqual(results.count, 2, "second attempt should succeed")
        expectEqual(stub.calls.count, 2)
    }

    await runner.run("ambiguity: close scores need the picker, clear winner does not") {
        let close = [
            LookupCandidate(id: "a", source: .openLibrary, title: "Rework", similarity: 0.8),
            LookupCandidate(id: "b", source: .openLibrary, title: "Rework II", similarity: 0.75),
        ]
        expectNil(LookupService.unambiguousBest(close), "0.05 gap is ambiguous")

        let clear = [
            LookupCandidate(id: "a", source: .openLibrary, title: "Dune", similarity: 0.95),
            LookupCandidate(id: "b", source: .openLibrary, title: "Dune Messiah", similarity: 0.5),
        ]
        expectEqual(LookupService.unambiguousBest(clear)?.id, "a")

        let weak = [LookupCandidate(id: "a", source: .openLibrary, title: "X", similarity: 0.4)]
        expectNil(LookupService.unambiguousBest(weak), "low similarity never auto-applies")
    }

    await runner.run("apply: fillEmpty keeps existing, manual always wins") {
        let database = try AppDatabase.inMemory()
        let bookId = try await database.writer.write { db -> Int64 in
            var book = Book(title: "My Custom Title", authors: [], year: nil)
            try book.insert(db)
            try ProvenanceRecord(bookId: book.id!, field: "title", source: .manual).save(db)
            return book.id!
        }
        let stub = TransportStub()
        let (service, _, _) = try makeService(stub, db: database)

        let candidate = LookupCandidate(
            id: "c", source: .openLibrary, title: "Dune", authors: ["Frank Herbert"],
            publisher: "Chilton", year: 1965, isbn13: "9780441172719", similarity: 1.0)
        try await service.apply(candidate, to: bookId, policy: .fillEmpty)

        let book = try await database.writer.read { try Book.fetchOne($0, key: bookId) }
        expectEqual(book?.title, "My Custom Title", "manual title must never be overwritten")
        expectEqual(book?.authors ?? [], ["Frank Herbert"], "empty authors get filled")
        expectEqual(book?.year, 1965)
        let provenance = try database.provenance(forBook: bookId)
        expectEqual(provenance["title"], .manual)
        expectEqual(provenance["authors"], .openLibrary)
    }

    await runner.run("apply: overwrite replaces embedded but not manual") {
        let database = try AppDatabase.inMemory()
        let bookId = try await database.writer.write { db -> Int64 in
            var book = Book(title: "dune_scan_v2", authors: ["Unknown"], year: 1900)
            try book.insert(db)
            try ProvenanceRecord(bookId: book.id!, field: "year", source: .manual).save(db)
            try ProvenanceRecord(bookId: book.id!, field: "authors", source: .embedded).save(db)
            return book.id!
        }
        let stub = TransportStub()
        let (service, _, _) = try makeService(stub, db: database)

        let candidate = LookupCandidate(
            id: "c", source: .openLibrary, title: "Dune", authors: ["Frank Herbert"],
            year: 1965, similarity: 1.0)
        try await service.apply(candidate, to: bookId, policy: .overwrite)

        let book = try await database.writer.read { try Book.fetchOne($0, key: bookId) }
        expectEqual(book?.title, "Dune")
        expectEqual(book?.authors ?? [], ["Frank Herbert"], "embedded loses under overwrite policy")
        expectEqual(book?.year, 1900, "manual year survives overwrite policy")
    }

    await runner.run("batch resolve checkpoints and resumes after failure") {
        let database = try AppDatabase.inMemory()
        var ids: [Int64] = []
        for title in ["Dune", "Neuromancer", "Hyperion"] {
            let id = try await database.writer.write { db -> Int64 in
                var book = Book(title: title, authors: ["A B"])
                try book.insert(db)
                var file = BookFile(bookId: book.id!, path: "/x/\(title).epub",
                                    format: .epub, sizeBytes: 1, modifiedAt: Date())
                try file.insert(db)
                return book.id!
            }
            ids.append(id)
        }

        // Fail permanently (404) for the second book only.
        let stub = TransportStub()
        stub.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("Neuromancer") { return (Data(), 404) }
            let doc = """
            {"docs": [{"key": "/w", "title": "\(url.contains("Dune") ? "Dune" : "Hyperion")",
                       "author_name": ["A B"], "first_publish_year": 1980}]}
            """
            return (Data(doc.utf8), 200)
        }
        let (service, _, _) = try makeService(stub, db: database)

        let outcome = await service.resolveBatch(bookIds: ids, policy: .fillEmpty)
        expectEqual(outcome.resolved.count, 2)
        expectEqual(outcome.failed.count, 1)
        expectNotNil(outcome.failed[ids[1]]) != nil
            ? () : expect(false, "book 2 should be in failed")
        expectEqual(service.pendingBatch(), [], "completed batch clears its state")

        // Simulate an interrupted batch: state persists for resume.
        try database.setSetting(LookupService.batchStateKey, "\(ids[1]),\(ids[2])")
        expectEqual(service.pendingBatch(), [ids[1], ids[2]])
        service.clearPendingBatch()
        expectEqual(service.pendingBatch(), [])
    }

    await runner.run("reviewCompleted routes complete books to the picker") {
        let database = try AppDatabase.inMemory()
        let (completeId, incompleteId) = try await database.writer.write { db -> (Int64, Int64) in
            var complete = Book(title: "Dune", authors: ["Frank Herbert"],
                                year: 1965, metadataStatus: .complete)
            try complete.insert(db)
            var incomplete = Book(title: "Dune", authors: [])
            try incomplete.insert(db)
            return (complete.id!, incomplete.id!)
        }
        let stub = TransportStub()
        stub.handler = { _ in (Data(openLibraryDuneJSON.utf8), 200) }
        let (service, _, _) = try makeService(stub, db: database)

        // Explicit re-resolve: the complete book must come back for review
        // even though "Dune" is a clear winner; the incomplete one still
        // auto-applies as before.
        let outcome = await service.resolveBatch(
            bookIds: [completeId, incompleteId], policy: .fillEmpty, reviewCompleted: true)
        expectNotNil(outcome.ambiguous[completeId],
                     "complete book goes to the picker under reviewCompleted")
        expectEqual(outcome.resolved, [incompleteId])

        // Default (background/resume) behavior is unchanged: clear winners
        // auto-apply without a picker.
        let silent = await service.resolveBatch(bookIds: [completeId], policy: .fillEmpty)
        expectEqual(silent.ambiguous.count, 0)
        expectEqual(silent.resolved, [completeId])
    }

    await runner.run("query built from filename when book has no metadata") {
        let book = Book(title: "", authors: [])
        let file = BookFile(bookId: 1, path: "/books/Frank Herbert - Dune.epub",
                            format: .epub, sizeBytes: 1, modifiedAt: Date())
        let query = LookupQuery.forBook(book, files: [file])
        expectEqual(query.title, "Dune")
        expectEqual(query.authors, ["Frank Herbert"])
    }

    await runner.run("transient errors retry, permanent ones do not; empty query skips network") {
        expect(HTTPStatusError(429).isTransient)
        expect(HTTPStatusError(500).isTransient)
        expect(HTTPStatusError(503).isTransient)
        expect(!HTTPStatusError(404).isTransient)
        expect(!HTTPStatusError(400).isTransient)

        expect(LookupQuery().isEmpty)
        expect(!LookupQuery(isbn: "9780441172719").isEmpty)
        expect(!LookupQuery(title: "Dune").isEmpty)
        expect(LookupQuery(title: "", authors: ["Frank Herbert"]).isEmpty,
               "authors alone cannot drive a search")

        let stub = TransportStub()
        let (service, _, _) = try makeService(stub)
        let results = try await service.candidates(for: LookupQuery())
        expectEqual(results.count, 0)
        expectEqual(stub.calls.count, 0, "empty query must never hit the network")
    }

    await runner.run("provider no-match is not turned into a later provider's error") {
        let stub = TransportStub()
        stub.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("openlibrary") { return (Data("{\"docs\": []}".utf8), 200) }
            return (Data(), 404)  // Google fails permanently
        }
        let (service, _, _) = try makeService(stub, googleKey: "test-key")
        let results = try await service.candidates(for: LookupQuery(title: "Dune"))
        expectEqual(results.count, 0, "zero hits is a genuine no-match, not an error")

        // When every provider fails, the error does surface.
        let allFail = TransportStub()
        allFail.handler = { _ in (Data(), 404) }
        let (failing, _, _) = try makeService(allFail, googleKey: "test-key")
        do {
            _ = try await failing.candidates(for: LookupQuery(title: "Dune"))
            expect(false, "all-providers-failed must throw")
        } catch {
            expectEqual(error as? HTTPStatusError, HTTPStatusError(404))
        }
    }

    await runner.run("apply: candidate cover is fetched, cached, and gets provenance") {
        let database = try AppDatabase.inMemory()
        let bookId = try await database.writer.write { db -> Int64 in
            var book = Book(title: "Dune", authors: ["Frank Herbert"], year: 1965)
            try book.insert(db)
            return book.id!
        }
        let stub = TransportStub()
        stub.handler = { request in
            let url = request.url!.absoluteString
            expect(url.contains("covers.example"), "only the cover URL should be fetched")
            return (Fixtures.jpegData(), 200)
        }
        let (service, _, coversDir) = try makeService(stub, db: database)

        let candidate = LookupCandidate(
            id: "c", source: .openLibrary, title: "Dune", authors: ["Frank Herbert"],
            coverURL: URL(string: "https://covers.example/dune-L.jpg"), similarity: 1.0)
        try await service.apply(candidate, to: bookId, policy: .fillEmpty)

        let book = try await database.writer.read { try Book.fetchOne($0, key: bookId) }
        let coverPath = book?.coverCachePath
        expect(coverPath?.hasPrefix(coversDir.path) == true,
               "cover must land in the cache, got \(coverPath ?? "nil")")
        expect(FileManager.default.fileExists(atPath: coverPath ?? ""), "grid file written")
        expectEqual(try database.provenance(forBook: bookId)["cover"], .openLibrary)
        expectEqual(book?.metadataStatus, .complete,
                    "title+author+year+cover now all present")
    }

    await runner.run("google books: largest cover preferred, both ISBN types extracted") {
        let payload = """
        {"items": [
          {"id": "gb2", "volumeInfo": {
            "title": "Dune", "authors": ["Frank Herbert"],
            "industryIdentifiers": [
              {"type": "ISBN_10", "identifier": "0441172717"},
              {"type": "ISBN_13", "identifier": "9780441172719"}],
            "imageLinks": {"thumbnail": "http://books.google.com/small.jpg",
                           "large": "http://books.google.com/large.jpg"}}}
        ]}
        """
        let stub = TransportStub()
        stub.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("openlibrary") { return (Data("{\"docs\": []}".utf8), 200) }
            return (Data(payload.utf8), 200)
        }
        let (service, _, _) = try makeService(stub, googleKey: "test-key")
        let results = try await service.candidates(for: LookupQuery(title: "Dune"))
        let top = expectNotNil(results.first, "google candidate expected")
        expectEqual(top?.coverURL?.absoluteString, "https://books.google.com/large.jpg",
                    "large beats thumbnail and is upgraded to https")
        expectEqual(top?.isbn10, "0441172717")
        expectEqual(top?.isbn13, "9780441172719")
    }

    await runner.run("open library: docs without a title are dropped") {
        let payload = """
        {"docs": [
          {"key": "/works/OL1W", "title": "Dune", "author_name": ["Frank Herbert"]},
          {"key": "/works/OL2W", "author_name": ["Anonymous"]}
        ]}
        """
        let stub = TransportStub()
        stub.handler = { _ in (Data(payload.utf8), 200) }
        let (service, _, _) = try makeService(stub)
        let results = try await service.candidates(for: LookupQuery(title: "Dune"))
        expectEqual(results.count, 1, "the title-less doc must be filtered out")
        expectEqual(results.first?.title, "Dune")
    }
}

final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
