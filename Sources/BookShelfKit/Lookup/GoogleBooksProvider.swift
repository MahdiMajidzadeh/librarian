import Foundation

/// Google Books volumes API — used only when the user supplied an API key in
/// Settings (user decision: Open Library is the default provider).
public struct GoogleBooksProvider: MetadataProvider {
    public let source = ProvenanceSource.googleBooks
    let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func search(_ query: LookupQuery, transport: HTTPTransport) async throws -> [LookupCandidate] {
        var q: String
        if let isbn = query.isbn {
            q = "isbn:\(isbn)"
        } else {
            var parts: [String] = []
            if let title = query.title, !title.isEmpty {
                parts.append("intitle:\(title)")
            }
            if let author = query.authors.first, !author.isEmpty {
                parts.append("inauthor:\(author)")
            }
            q = parts.joined(separator: " ")
        }
        guard !q.isEmpty,
              var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "maxResults", value: "8"),
            URLQueryItem(name: "key", value: apiKey),
        ]

        let (data, response) = try await transport(URLRequest(url: components.url!))
        guard response.statusCode == 200 else {
            throw HTTPStatusError(response.statusCode)
        }

        let decoded = try JSONDecoder().decode(VolumesResponse.self, from: data)
        return (decoded.items ?? []).compactMap { item in
            guard let info = item.volumeInfo, let title = info.title else { return nil }
            let identifiers = info.industryIdentifiers ?? []
            func isbn(_ type: String) -> String? {
                identifiers.first { $0.type == type }?.identifier
                    .flatMap(Normalizer.extractISBN)
            }
            // Prefer the largest cover; force https.
            let coverLink = info.imageLinks?.extraLarge ?? info.imageLinks?.large
                ?? info.imageLinks?.medium ?? info.imageLinks?.thumbnail
            let coverURL = coverLink
                .map { $0.replacingOccurrences(of: "http://", with: "https://") }
                .flatMap(URL.init(string:))

            return LookupCandidate(
                id: "googlebooks:\(item.id ?? UUID().uuidString)",
                source: .googleBooks,
                title: title,
                authors: info.authors ?? [],
                publisher: info.publisher,
                year: info.publishedDate.flatMap(EmbeddedMetadata.year(fromDateString:)),
                isbn10: isbn("ISBN_10"),
                isbn13: isbn("ISBN_13"),
                pageCount: info.pageCount,
                language: info.language,
                categories: info.categories ?? [],
                description: info.description,
                coverURL: coverURL
            )
        }
    }

    struct VolumesResponse: Decodable {
        let items: [Volume]?
    }

    struct Volume: Decodable {
        let id: String?
        let volumeInfo: VolumeInfo?
    }

    struct VolumeInfo: Decodable {
        let title: String?
        let authors: [String]?
        let publisher: String?
        let publishedDate: String?
        let description: String?
        let industryIdentifiers: [IndustryIdentifier]?
        let pageCount: Int?
        let categories: [String]?
        let language: String?
        let imageLinks: ImageLinks?
    }

    struct IndustryIdentifier: Decodable {
        let type: String?
        let identifier: String?
    }

    struct ImageLinks: Decodable {
        let thumbnail: String?
        let medium: String?
        let large: String?
        let extraLarge: String?
    }
}
