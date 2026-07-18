import Foundation

/// Open Library search — the default, keyless provider.
/// Search API: https://openlibrary.org/search.json
/// Covers API: https://covers.openlibrary.org/b/id/{cover_i}-L.jpg
public struct OpenLibraryProvider: MetadataProvider {
    public let source = ProvenanceSource.openLibrary

    public init() {}

    public func search(_ query: LookupQuery, transport: HTTPTransport) async throws -> [LookupCandidate] {
        guard var components = URLComponents(string: "https://openlibrary.org/search.json") else {
            return []
        }
        var items = [URLQueryItem(name: "limit", value: "8")]
        if let isbn = query.isbn {
            items.append(URLQueryItem(name: "isbn", value: isbn))
        } else {
            if let title = query.title, !title.isEmpty {
                items.append(URLQueryItem(name: "title", value: title))
            }
            if let author = query.authors.first, !author.isEmpty {
                items.append(URLQueryItem(name: "author", value: author))
            }
        }
        guard items.count > 1 else { return [] }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("BookShelf/1.0 (personal library manager)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else {
            throw HTTPStatusError(response.statusCode)
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.docs.map { doc in
            let isbns = (doc.isbn ?? []).compactMap(Normalizer.extractISBN)
            return LookupCandidate(
                id: "openlibrary:\(doc.key ?? UUID().uuidString)",
                source: .openLibrary,
                title: doc.title ?? "",
                authors: doc.author_name ?? [],
                publisher: doc.publisher?.first,
                year: doc.first_publish_year,
                isbn10: isbns.first { $0.count == 10 },
                isbn13: isbns.first { $0.count == 13 },
                pageCount: doc.number_of_pages_median,
                language: doc.language?.first,
                categories: Array((doc.subject ?? []).prefix(6)),
                description: nil,
                coverURL: doc.cover_i.map {
                    URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg")!
                }
            )
        }
        .filter { !$0.title.isEmpty }
    }

    struct SearchResponse: Decodable {
        let docs: [Doc]
    }

    struct Doc: Decodable {
        let key: String?
        let title: String?
        let author_name: [String]?
        let first_publish_year: Int?
        let isbn: [String]?
        let publisher: [String]?
        let language: [String]?
        let subject: [String]?
        let cover_i: Int?
        let number_of_pages_median: Int?
    }
}
