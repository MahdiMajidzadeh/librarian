import Foundation

/// A candidate match returned by an online metadata provider (FR-3.4).
public struct LookupCandidate: Sendable, Identifiable, Equatable {
    public var id: String
    public var source: MetadataSource
    public var metadata: BookMetadata
    /// URL of the largest available cover image, fetched on confirmation.
    public var coverURL: URL?
    /// Token similarity between the query title and the candidate title,
    /// in [0, 1] — shown in the picker so wrong ISBNs are rejectable (§9).
    public var titleSimilarity: Double

    public init(
        id: String, source: MetadataSource, metadata: BookMetadata,
        coverURL: URL? = nil, titleSimilarity: Double = 0
    ) {
        self.id = id
        self.source = source
        self.metadata = metadata
        self.coverURL = coverURL
        self.titleSimilarity = titleSimilarity
    }
}

/// The query sent to providers (§6.3 step 2): by ISBN when available,
/// otherwise title + author.
public struct LookupQuery: Sendable, Equatable {
    public var isbn: String?
    public var title: String?
    public var author: String?

    public init(isbn: String? = nil, title: String? = nil, author: String? = nil) {
        self.isbn = isbn
        self.title = title
        self.author = author
    }

    public var isEmpty: Bool {
        isbn == nil && (title ?? "").isEmpty
    }
}

/// One online metadata source. Implementations must be stateless and safe to
/// call from any thread; rate limiting happens in `LookupService`.
public protocol MetadataProvider: Sendable {
    var source: MetadataSource { get }
    /// Returns candidates ordered by provider relevance. An empty array means
    /// "no match" — distinct from a thrown network/decoding error.
    func search(_ query: LookupQuery) async throws -> [LookupCandidate]
}

/// Shared HTTP plumbing for providers.
enum ProviderHTTP {
    static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Librarian/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw LookupError.httpStatus(http.statusCode)
            }
        }
        return data
    }
}

public enum LookupError: Error, LocalizedError, Equatable {
    case httpStatus(Int)
    case rateLimited
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "Server returned HTTP \(code)"
        case .rateLimited: return "Rate limited by the metadata service"
        case .cancelled: return "Lookup cancelled"
        }
    }
}
