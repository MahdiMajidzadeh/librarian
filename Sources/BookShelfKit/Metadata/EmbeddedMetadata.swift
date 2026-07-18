import Foundation

/// Metadata extracted from inside a book file (epub OPF, PDF info dictionary,
/// MOBI EXTH headers). All fields optional — parsers fill what they find.
public struct EmbeddedMetadata: Sendable, Equatable {
    public var title: String?
    public var authors: [String] = []
    public var publisher: String?
    public var language: String?
    public var isbn: String?
    public var year: Int?
    public var description: String?
    public var subjects: [String] = []
    public var coverData: Data?

    public init() {}

    public var isEmpty: Bool {
        title == nil && authors.isEmpty && publisher == nil && language == nil
            && isbn == nil && year == nil && description == nil
            && subjects.isEmpty && coverData == nil
    }

    /// Fields that carry provenance when applied to a book.
    public var populatedFields: [String] {
        var fields: [String] = []
        if title != nil { fields.append("title") }
        if !authors.isEmpty { fields.append("authors") }
        if publisher != nil { fields.append("publisher") }
        if language != nil { fields.append("language") }
        if isbn != nil { fields.append("isbn") }
        if year != nil { fields.append("year") }
        if description != nil { fields.append("description") }
        if !subjects.isEmpty { fields.append("tags") }
        if coverData != nil { fields.append("cover") }
        return fields
    }

    /// Parses a year out of strings like "1965", "1965-08-01", "August 1965".
    public static func year(fromDateString raw: String) -> Int? {
        var digits = ""
        for ch in raw {
            if ch.isNumber {
                digits.append(ch)
                if digits.count == 4 { break }
            } else {
                digits = ""
            }
        }
        guard digits.count == 4, let year = Int(digits), (1000...2200).contains(year) else {
            return nil
        }
        return year
    }
}

/// Failure produced by a format parser. Non-fatal by design (§9): the book
/// still appears, flagged unresolved with the note attached.
public struct ParseError: Error, CustomStringConvertible {
    public let note: String
    public init(_ note: String) { self.note = note }
    public var description: String { note }
}
