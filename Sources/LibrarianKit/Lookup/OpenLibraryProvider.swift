import Foundation

/// Open Library provider (§6.3 step 2, fallback). No API key required.
public struct OpenLibraryProvider: MetadataProvider {
    public let source = MetadataSource.openLibrary
    let baseURL: URL

    public init(baseURL: URL = URL(string: "https://openlibrary.org")!) {
        self.baseURL = baseURL
    }

    public func search(_ query: LookupQuery) async throws -> [LookupCandidate] {
        guard let url = searchURL(for: query) else { return [] }
        let data = try await ProviderHTTP.get(url)
        return Self.parse(data, queryTitle: query.title)
    }

    func searchURL(for query: LookupQuery) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search.json"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let isbn = query.isbn {
            items.append(URLQueryItem(name: "q", value: "isbn:\(isbn)"))
        } else if let title = query.title, !title.isEmpty {
            items.append(URLQueryItem(name: "title", value: title))
            if let author = query.author, !author.isEmpty {
                items.append(URLQueryItem(name: "author", value: author))
            }
        } else {
            return nil
        }
        items.append(URLQueryItem(name: "limit", value: "10"))
        items.append(URLQueryItem(
            name: "fields",
            value: "key,title,author_name,first_publish_year,publisher,isbn,language,cover_i"))
        components.queryItems = items
        return components.url
    }

    // MARK: - Response parsing

    struct Response: Decodable {
        var docs: [Doc]?
    }

    struct Doc: Decodable {
        var key: String?
        var title: String?
        var author_name: [String]?
        var first_publish_year: Int?
        var publisher: [String]?
        var isbn: [String]?
        var language: [String]?
        var cover_i: Int?
    }

    static func parse(_ data: Data, queryTitle: String?) -> [LookupCandidate] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return []
        }
        return (response.docs ?? []).compactMap { doc in
            guard let title = doc.title else { return nil }

            var metadata = BookMetadata()
            metadata.title = title
            metadata.authors = doc.author_name ?? []
            metadata.publisher = doc.publisher?.first
            metadata.year = doc.first_publish_year
            metadata.language = doc.language?.first
            for isbn in (doc.isbn ?? []).prefix(20) {
                ISBN.assign(isbn, to: &metadata)
            }

            var coverURL: URL?
            if let coverId = doc.cover_i {
                coverURL = URL(string: "https://covers.openlibrary.org/b/id/\(coverId)-L.jpg")
            }

            return LookupCandidate(
                id: "ol-\(doc.key ?? UUID().uuidString)",
                source: .openLibrary,
                metadata: metadata,
                coverURL: coverURL,
                titleSimilarity: queryTitle.map { Normalizer.similarity($0, title) } ?? 1)
        }
    }
}
