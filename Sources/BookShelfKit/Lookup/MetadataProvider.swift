import Foundation

/// What we ask a provider for: ISBN when available, otherwise title/authors
/// (possibly inferred from the filename — spec §6.3 pipeline).
public struct LookupQuery: Sendable, Equatable {
    public var isbn: String?
    public var title: String?
    public var authors: [String]

    public init(isbn: String? = nil, title: String? = nil, authors: [String] = []) {
        self.isbn = isbn
        self.title = title
        self.authors = authors
    }

    public var isEmpty: Bool { isbn == nil && (title ?? "").isEmpty }

    /// Builds the best query for a book: ISBN → embedded/manual title+authors
    /// → filename inference as last resort (FR-3, step 3).
    public static func forBook(_ book: Book, files: [BookFile]) -> LookupQuery {
        if let isbn = book.isbn13 ?? book.isbn10 {
            return LookupQuery(isbn: isbn, title: book.title, authors: book.authors)
        }
        if !book.title.isEmpty, !book.authors.isEmpty {
            return LookupQuery(title: book.title, authors: book.authors)
        }
        // Filename inference.
        if let path = files.first?.path {
            let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let inferred = GroupingEngine.inferTitleAuthors(fromStem: stem)
            let title = book.title.isEmpty ? inferred.title : book.title
            let authors = book.authors.isEmpty ? inferred.authors : book.authors
            return LookupQuery(title: title, authors: authors)
        }
        return LookupQuery(title: book.title, authors: book.authors)
    }
}

/// A normalized result from any provider.
public struct LookupCandidate: Sendable, Identifiable, Equatable {
    public var id: String
    public var source: ProvenanceSource
    public var title: String
    public var authors: [String]
    public var publisher: String?
    public var year: Int?
    public var isbn10: String?
    public var isbn13: String?
    public var pageCount: Int?
    public var language: String?
    public var categories: [String]
    public var description: String?
    public var coverURL: URL?
    /// Token similarity between the candidate and the query title (0…1),
    /// shown in the picker (§9) and used for ambiguity detection.
    public var similarity: Double

    public init(id: String, source: ProvenanceSource, title: String, authors: [String] = [],
                publisher: String? = nil, year: Int? = nil, isbn10: String? = nil,
                isbn13: String? = nil, pageCount: Int? = nil, language: String? = nil,
                categories: [String] = [], description: String? = nil,
                coverURL: URL? = nil, similarity: Double = 0) {
        self.id = id
        self.source = source
        self.title = title
        self.authors = authors
        self.publisher = publisher
        self.year = year
        self.isbn10 = isbn10
        self.isbn13 = isbn13
        self.pageCount = pageCount
        self.language = language
        self.categories = categories
        self.description = description
        self.coverURL = coverURL
        self.similarity = similarity
    }
}

/// Pluggable HTTP transport so tests can stub network responses.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum HTTP {
    public static let live: HTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

public struct HTTPStatusError: Error, Equatable {
    public let statusCode: Int
    public init(_ statusCode: Int) { self.statusCode = statusCode }

    /// Worth retrying with backoff?
    public var isTransient: Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }
}

public protocol MetadataProvider: Sendable {
    var source: ProvenanceSource { get }
    func search(_ query: LookupQuery, transport: HTTPTransport) async throws -> [LookupCandidate]
}
