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

    /// File extensions that betray a Title field stuffed with a filename
    /// ("0071501126.pdf", "Microsoft Word - thesis.doc").
    static let junkTitleExtensions: Set<String> = [
        "pdf", "epub", "mobi", "azw", "azw3", "djvu", "doc", "docx", "rtf",
        "txt", "html", "htm", "tex", "indd", "qxd", "pmd", "p65", "fb2",
        "cbz", "chm", "ps", "odt",
    ]

    /// True when an embedded title is production junk rather than a real
    /// title: a filename ("0071501126.pdf"), a bare ISBN / long number, an
    /// authoring-tool artifact ("Microsoft Word - chapter1"), or "untitled".
    /// Checks are script-agnostic — real Unicode titles (Persian included)
    /// and short numeric titles like "1984" are never flagged.
    public static func isJunkTitle(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return true }

        let lowered = text.lowercased()
        if ["untitled", "unknown", "no title"].contains(lowered) { return true }
        for prefix in ["microsoft word - ", "microsoft powerpoint - ", "powerpoint presentation"]
        where lowered.hasPrefix(prefix) { return true }

        if let dot = lowered.lastIndex(of: "."),
           junkTitleExtensions.contains(String(lowered[lowered.index(after: dot)...])) {
            return true
        }

        // No letters in any script: pure punctuation is junk; digit runs are
        // junk only at ISBN-ish length so "1984" or "2001" survive.
        if !text.contains(where: \.isLetter) {
            let digitCount = text.filter(\.isNumber).count
            return digitCount == 0 || digitCount >= 8
        }
        return false
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
