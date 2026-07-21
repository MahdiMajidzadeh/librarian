import Foundation

/// Metadata extracted from a book file or an online provider, before it is
/// merged into a `Book`. All fields optional — parsers fill what they find.
public struct BookMetadata: Sendable, Equatable {
    public var title: String?
    public var authors: [String] = []
    public var series: String?
    public var seriesIndex: Double?
    public var publisher: String?
    public var year: Int?
    public var language: String?
    public var isbn10: String?
    public var isbn13: String?
    public var description: String?
    /// Raw cover image bytes (JPEG/PNG), when the source provides one.
    public var coverData: Data?

    public init() {}

    public var isEmpty: Bool {
        title == nil && authors.isEmpty && series == nil && publisher == nil
            && year == nil && language == nil && isbn10 == nil && isbn13 == nil
            && description == nil && coverData == nil
    }

    /// Field names as stored in the provenance table (FR-3.3).
    public var populatedFields: [String] {
        var fields: [String] = []
        if title != nil { fields.append("title") }
        if !authors.isEmpty { fields.append("authors") }
        if series != nil { fields.append("series") }
        if seriesIndex != nil { fields.append("series_index") }
        if publisher != nil { fields.append("publisher") }
        if year != nil { fields.append("year") }
        if language != nil { fields.append("language") }
        if isbn10 != nil { fields.append("isbn10") }
        if isbn13 != nil { fields.append("isbn13") }
        if description != nil { fields.append("description") }
        if coverData != nil { fields.append("cover") }
        return fields
    }
}

/// ISBN normalization helpers.
public enum ISBN {
    /// Strips separators and validates length; returns nil when clearly not an ISBN.
    public static func normalize(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "urn:isbn:", with: "", options: .caseInsensitive)
            .filter { $0.isNumber || $0 == "X" || $0 == "x" }
            .uppercased()
        switch cleaned.count {
        case 10, 13: return cleaned
        default: return nil
        }
    }

    public static func isISBN13(_ isbn: String) -> Bool { isbn.count == 13 }

    /// True when a normalized ISBN has a valid check digit and is not an
    /// obvious placeholder (all one digit). Embedded metadata in the wild is
    /// full of junk ISBNs shared across unrelated files — using one as a
    /// grouping key would merge strangers (§9), so grouping requires this.
    public static func isPlausible(_ isbn: String) -> Bool {
        let chars = Array(isbn)
        guard Set(chars).count > 1 else { return false } // "0000000000" & co.

        if chars.count == 13 {
            guard chars.allSatisfy(\.isNumber) else { return false }
            let sum = chars.enumerated().reduce(0) { total, pair in
                total + pair.element.wholeNumberValue! * (pair.offset % 2 == 0 ? 1 : 3)
            }
            return sum % 10 == 0
        }
        if chars.count == 10 {
            var sum = 0
            for (index, char) in chars.enumerated() {
                let value: Int
                if char == "X" {
                    guard index == 9 else { return false }
                    value = 10
                } else if char.isNumber {
                    value = char.wholeNumberValue!
                } else {
                    return false
                }
                sum += value * (10 - index)
            }
            return sum % 11 == 0
        }
        return false
    }

    /// Assigns a normalized ISBN to the right slot of the metadata struct.
    public static func assign(_ raw: String, to metadata: inout BookMetadata) {
        guard let isbn = normalize(raw) else { return }
        if isISBN13(isbn) {
            if metadata.isbn13 == nil { metadata.isbn13 = isbn }
        } else {
            if metadata.isbn10 == nil { metadata.isbn10 = isbn }
        }
    }
}

/// Parses a publish year out of loosely formatted date strings ("2005-06-01",
/// "June 2005", "2005").
public func parseYear(_ raw: String?) -> Int? {
    guard let raw else { return nil }
    let digits = raw.split(whereSeparator: { !$0.isNumber })
    for chunk in digits where chunk.count == 4 {
        if let year = Int(chunk), (1000...2999).contains(year) { return year }
    }
    return nil
}

/// Infers `Author - Title` / `Title - Author` metadata from a filename stem
/// (§6.3 step 3). Used only to seed online queries, never stored as truth.
public enum FilenameInference {
    public struct Guess: Sendable, Equatable {
        public var title: String
        public var author: String?
    }

    public static func guess(fromStem stem: String) -> Guess {
        let cleaned = Normalizer.cleanStemForDisplay(stem)
        let parts = cleaned.components(separatedBy: " - ")
        guard parts.count >= 2 else {
            return Guess(title: cleaned, author: nil)
        }
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let rest = parts.dropFirst().joined(separator: " - ")
            .trimmingCharacters(in: .whitespaces)
        // Heuristic: author names are short (≤ 4 words) and contain no digits.
        let firstLooksLikeAuthor = first.split(separator: " ").count <= 4
            && first.rangeOfCharacter(from: .decimalDigits) == nil
        if firstLooksLikeAuthor {
            return Guess(title: rest, author: first)
        }
        return Guess(title: first, author: rest)
    }
}
