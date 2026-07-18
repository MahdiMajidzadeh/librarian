import Foundation

/// Template-driven filename generation (FR-4.1/4.2/4.4).
///
/// Syntax: literals plus `{token}` and conditional segments
/// `{series? ({series} #{series_index})}` — the inner part renders only when
/// the guard token has a value. Default template: `{author} - {title}.{ext}`.
public struct RenameTemplate: Sendable, Equatable {
    public enum Token: String, CaseIterable, Sendable {
        case title, author, authors
        case authorSort = "author_sort"
        case year, series
        case seriesIndex = "series_index"
        case isbn, language, publisher, ext
    }

    public indirect enum Segment: Sendable, Equatable {
        case literal(String)
        case token(Token)
        case conditional(Token, [Segment])
    }

    public let segments: [Segment]
    public static let defaultRaw = "{author} - {title}.{ext}"

    public struct ParseFailure: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    // MARK: - Parsing

    public static func parse(_ raw: String) throws -> RenameTemplate {
        var chars = Array(raw)[...]
        let segments = try parseSegments(&chars, stopAtBrace: false)
        return RenameTemplate(segments: segments)
    }

    private static func parseSegments(
        _ chars: inout ArraySlice<Character>, stopAtBrace: Bool
    ) throws -> [Segment] {
        var segments: [Segment] = []
        var literal = ""

        func flushLiteral() {
            if !literal.isEmpty {
                segments.append(.literal(literal))
                literal = ""
            }
        }

        while let ch = chars.first {
            if ch == "}" {
                if stopAtBrace {
                    flushLiteral()
                    return segments
                }
                throw ParseFailure(message: "unbalanced '}'")
            }
            if ch == "{" {
                chars.removeFirst()
                flushLiteral()
                segments.append(try parseBraced(&chars))
            } else {
                literal.append(ch)
                chars.removeFirst()
            }
        }
        if stopAtBrace {
            throw ParseFailure(message: "missing closing '}'")
        }
        flushLiteral()
        return segments
    }

    private static func parseBraced(_ chars: inout ArraySlice<Character>) throws -> Segment {
        var name = ""
        while let ch = chars.first, ch != "}" && ch != "?" {
            name.append(ch)
            chars.removeFirst()
        }
        let token = try resolveToken(name)
        guard let next = chars.first else {
            throw ParseFailure(message: "missing closing '}'")
        }
        if next == "}" {
            chars.removeFirst()
            return .token(token)
        }
        // Conditional: everything after '?' (including leading whitespace,
        // which becomes part of the rendered output) up to the matching '}'.
        chars.removeFirst()
        let inner = try parseSegments(&chars, stopAtBrace: true)
        guard chars.first == "}" else {
            throw ParseFailure(message: "missing closing '}' for conditional {\(token.rawValue)?…}")
        }
        chars.removeFirst()
        return .conditional(token, inner)
    }

    private static func resolveToken(_ name: String) throws -> Token {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let token = Token(rawValue: trimmed) else {
            let known = Token.allCases.map(\.rawValue).joined(separator: ", ")
            throw ParseFailure(message: "unknown token {\(trimmed)} — available: \(known)")
        }
        return token
    }

    // MARK: - Rendering

    public struct RenderResult: Sendable, Equatable {
        /// The sanitized filename, nil when required tokens were missing.
        public let name: String?
        /// Required (non-conditional) tokens that had no value (FR-4.9).
        public let missingTokens: [Token]
    }

    public func render(book: Book, fileExtension: String) -> RenderResult {
        var missing: [Token] = []
        let rendered = Self.render(
            segments: segments, book: book, fileExtension: fileExtension,
            requiredMissing: &missing)
        if !missing.isEmpty {
            return RenderResult(name: nil, missingTokens: missing)
        }
        let cleaned = Self.sanitize(rendered, fileExtension: fileExtension)
        return RenderResult(name: cleaned, missingTokens: [])
    }

    private static func render(
        segments: [Segment], book: Book, fileExtension: String,
        requiredMissing: inout [Token]
    ) -> String {
        var out = ""
        for segment in segments {
            switch segment {
            case .literal(let text):
                out += text
            case .token(let token):
                let value = value(of: token, book: book, fileExtension: fileExtension)
                if value.isEmpty {
                    if !requiredMissing.contains(token) {
                        requiredMissing.append(token)
                    }
                } else {
                    out += value
                }
            case .conditional(let guardToken, let inner):
                let guardValue = value(of: guardToken, book: book, fileExtension: fileExtension)
                if !guardValue.isEmpty {
                    // Inner empties collapse silently; they are not required.
                    var ignored: [Token] = []
                    out += render(segments: inner, book: book,
                                  fileExtension: fileExtension, requiredMissing: &ignored)
                }
            }
        }
        return out
    }

    static func value(of token: Token, book: Book, fileExtension: String) -> String {
        switch token {
        case .title:
            return book.title
        case .author:
            return book.authors.first ?? ""
        case .authors:
            return book.authors.joined(separator: ", ")
        case .authorSort:
            return book.authorSort.map(capitalizeSortName) ?? ""
        case .year:
            return book.year.map(String.init) ?? ""
        case .series:
            return book.series ?? ""
        case .seriesIndex:
            guard let index = book.seriesIndex else { return "" }
            return index.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(index)) : String(index)
        case .isbn:
            return book.isbn13 ?? book.isbn10 ?? ""
        case .language:
            return book.language ?? ""
        case .publisher:
            return book.publisher ?? ""
        case .ext:
            return fileExtension
        }
    }

    /// "herbert, frank" → "Herbert, Frank"
    private static func capitalizeSortName(_ sort: String) -> String {
        sort.split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Sanitization (FR-4.4)

    /// Strips path-illegal characters, collapses whitespace, removes dangling
    /// separators and empty brackets, and enforces the 255-byte APFS limit
    /// with UTF-8-safe truncation (Persian titles keep whole characters).
    static func sanitize(_ raw: String, fileExtension: String) -> String {
        var text = raw
        // Illegal on APFS/HFS+ (and Finder's ':' remapping).
        for ch in ["/", ":", "\0"] {
            text = text.replacingOccurrences(of: ch, with: " ")
        }
        // Empty bracket pairs left by collapsed tokens.
        for pair in ["()", "[]", "{}", "( )", "[ ]"] {
            text = text.replacingOccurrences(of: pair, with: "")
        }
        // Collapse whitespace.
        text = text.split(separator: " ").joined(separator: " ")
        // Dangling separators at either end (e.g. " - Title" when author was
        // present but template put it first… or trailing "-").
        let junk = CharacterSet(charactersIn: " -_.,")
        // Preserve the extension dot: split first.
        var stem = text
        var ext = ""
        if !fileExtension.isEmpty, text.lowercased().hasSuffix("." + fileExtension.lowercased()) {
            stem = String(text.dropLast(fileExtension.count + 1))
            ext = fileExtension
        }
        stem = stem.trimmingCharacters(in: junk)
        // Repeated separator runs like "- -" → "-".
        while stem.contains("- -") {
            stem = stem.replacingOccurrences(of: "- -", with: "-")
        }
        while stem.contains("--") {
            stem = stem.replacingOccurrences(of: "--", with: "-")
        }
        stem = stem.trimmingCharacters(in: junk)
        if stem.isEmpty {
            stem = "Untitled"
        }

        // APFS: 255 bytes UTF-8 for the whole filename.
        let suffix = ext.isEmpty ? "" : "." + ext
        let budget = 255 - suffix.utf8.count
        if stem.utf8.count > budget {
            var truncated = ""
            var used = 0
            for ch in stem {
                let size = String(ch).utf8.count
                if used + size > budget { break }
                truncated.append(ch)
                used += size
            }
            stem = truncated.trimmingCharacters(in: junk)
        }
        return stem + suffix
    }
}
