import Foundation

/// Google Books API provider (§6.3 step 2, primary). Keyless — low quota is
/// acceptable because lookups are always explicit user actions (FR-3.1).
public struct GoogleBooksProvider: MetadataProvider {
    public let source = MetadataSource.googleBooks
    let baseURL: URL

    public init(baseURL: URL = URL(string: "https://www.googleapis.com/books/v1")!) {
        self.baseURL = baseURL
    }

    public func search(_ query: LookupQuery) async throws -> [LookupCandidate] {
        guard let url = searchURL(for: query) else { return [] }
        let data = try await ProviderHTTP.get(url)
        return Self.parse(data, queryTitle: query.title)
    }

    func searchURL(for query: LookupQuery) -> URL? {
        var q: String
        if let isbn = query.isbn {
            q = "isbn:\(isbn)"
        } else if let title = query.title, !title.isEmpty {
            q = "intitle:\(title)"
            if let author = query.author, !author.isEmpty {
                q += "+inauthor:\(author)"
            }
        } else {
            return nil
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("volumes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "maxResults", value: "10"),
            URLQueryItem(name: "printType", value: "books"),
        ]
        return components.url
    }

    // MARK: - Response parsing

    struct Response: Decodable {
        var items: [Volume]?
    }

    struct Volume: Decodable {
        var id: String
        var volumeInfo: VolumeInfo
    }

    struct VolumeInfo: Decodable {
        var title: String?
        var authors: [String]?
        var publisher: String?
        var publishedDate: String?
        var description: String?
        var industryIdentifiers: [IndustryIdentifier]?
        var language: String?
        var imageLinks: ImageLinks?
    }

    struct IndustryIdentifier: Decodable {
        var type: String
        var identifier: String
    }

    struct ImageLinks: Decodable {
        var extraLarge: String?
        var large: String?
        var medium: String?
        var small: String?
        var thumbnail: String?
        var smallThumbnail: String?

        /// Largest available (FR: fetch cover image, largest available).
        var best: String? {
            extraLarge ?? large ?? medium ?? small ?? thumbnail ?? smallThumbnail
        }
    }

    static func parse(_ data: Data, queryTitle: String?) -> [LookupCandidate] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return []
        }
        return (response.items ?? []).compactMap { volume in
            let info = volume.volumeInfo
            guard let title = info.title else { return nil }

            var metadata = BookMetadata()
            metadata.title = title
            metadata.authors = info.authors ?? []
            metadata.publisher = info.publisher
            metadata.year = parseYear(info.publishedDate)
            metadata.description = info.description
            metadata.language = info.language
            for identifier in info.industryIdentifiers ?? [] {
                ISBN.assign(identifier.identifier, to: &metadata)
            }

            // Google serves covers over http:// links; force https.
            var coverURL: URL?
            if let link = info.imageLinks?.best {
                coverURL = URL(string: link.replacingOccurrences(of: "http://", with: "https://"))
            }

            return LookupCandidate(
                id: "gb-\(volume.id)",
                source: .googleBooks,
                metadata: metadata,
                coverURL: coverURL,
                titleSimilarity: queryTitle.map { Normalizer.similarity($0, title) } ?? 1)
        }
    }
}
