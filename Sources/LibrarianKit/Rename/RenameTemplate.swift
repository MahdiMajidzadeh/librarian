import Foundation

/// Template-driven filename rendering (FR-4.1..4.4).
///
/// Tokens: `{title}`, `{author}`, `{authors}`, `{author_sort}`, `{year}`,
/// `{series}`, `{series_index}`, `{isbn}`, `{language}`, `{publisher}`,
/// `{ext}`, plus literal text.
/// Conditional segments render only when every token inside has a value:
/// `{series? ({series} #{series_index})}` (FR-4.2). Empty tokens collapse
/// cleanly — no dangling " - " or "()".
public enum RenameTemplate {
    public static let defaultTemplate = "{author} - {title}.{ext}"
    public static let knownTokens: Set<String> = [
        "title", "author", "authors", "author_sort", "year",
        "series", "series_index", "isbn", "language", "publisher", "ext",
    ]

    // MARK: - Parsing

    indirect enum Node: Equatable {
        case literal(String)
        case token(String)
        /// `{name? inner-nodes}` — renders inner only when `name` has a value.
        case conditional(String, [Node])
    }

    public struct ParseFailure: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    static func parse(_ template: String) throws -> [Node] {
        var nodes: [Node] = []
        var literal = ""
        var index = template.startIndex

        func flushLiteral() {
            if !literal.isEmpty {
                nodes.append(.literal(literal))
                literal = ""
            }
        }

        while index < template.endIndex {
            let char = template[index]
            if char == "{" {
                // Find the matching close brace (conditionals nest one level:
                // `{series? ({series})}` — count braces).
                var depth = 1
                var cursor = template.index(after: index)
                var body = ""
                while cursor < template.endIndex, depth > 0 {
                    let c = template[cursor]
                    if c == "{" { depth += 1 }
                    if c == "}" { depth -= 1 }
                    if depth > 0 { body.append(c) }
                    cursor = template.index(after: cursor)
                }
                guard depth == 0 else {
                    throw ParseFailure(message: "Unclosed '{' in template")
                }
                flushLiteral()
                if let qIndex = body.firstIndex(of: "?") {
                    let name = String(body[..<qIndex]).trimmingCharacters(in: .whitespaces)
                    guard knownTokens.contains(name) else {
                        throw ParseFailure(message: "Unknown token '{\(name)}'")
                    }
                    let inner = String(body[body.index(after: qIndex)...])
                    nodes.append(.conditional(name, try parse(inner)))
                } else {
                    let name = body.trimmingCharacters(in: .whitespaces)
                    guard knownTokens.contains(name) else {
                        throw ParseFailure(message: "Unknown token '{\(name)}'")
                    }
                    nodes.append(.token(name))
                }
                index = cursor
            } else {
                literal.append(char)
                index = template.index(after: index)
            }
        }
        flushLiteral()
        return nodes
    }

    /// Validates a template; returns a user-facing error message or nil.
    public static func validate(_ template: String) -> String? {
        do {
            _ = try parse(template)
            return nil
        } catch {
            return (error as? ParseFailure)?.message ?? error.localizedDescription
        }
    }

    // MARK: - Token values

    /// Token values for a book + file. Empty/missing values are nil.
    public static func values(book: Book, fileExtension: String) -> [String: String] {
        var v: [String: String] = [:]
        func put(_ key: String, _ value: String?) {
            if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                v[key] = value
            }
        }
        put("title", book.title)
        put("author", book.authors.first)
        put("authors", book.authors.isEmpty ? nil : book.authors.joined(separator: ", "))
        put("author_sort", book.authors.first.map(Book.lastFirst))
        put("year", book.year.map(String.init))
        put("series", book.series)
        if let index = book.seriesIndex {
            let isWhole = index.truncatingRemainder(dividingBy: 1) == 0
            put("series_index", isWhole ? String(Int(index)) : String(index))
        }
        put("isbn", book.isbn13 ?? book.isbn10)
        put("language", book.language)
        put("publisher", book.publisher)
        put("ext", fileExtension.lowercased())
        return v
    }

    // MARK: - Rendering

    public struct RenderResult: Equatable, Sendable {
        public var filename: String
        /// Tokens referenced by the template that had no value. When the
        /// unresolved token was inside a conditional the render still
        /// succeeds; otherwise the file must be excluded (FR-4.9).
        public var missingRequiredTokens: [String]
    }

    public static func render(
        template: String, book: Book, fileExtension: String
    ) throws -> RenderResult {
        let nodes = try parse(template)
        let values = values(book: book, fileExtension: fileExtension)
        var missing: [String] = []
        let raw = renderNodes(nodes, values: values, missingRequired: &missing)
        let sanitized = sanitize(raw, fileExtension: fileExtension)
        return RenderResult(filename: sanitized, missingRequiredTokens: missing)
    }

    private static func renderNodes(
        _ nodes: [Node], values: [String: String], missingRequired: inout [String]
    ) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .literal(let text):
                out += text
            case .token(let name):
                if let value = values[name] {
                    out += value
                } else {
                    missingRequired.append(name)
                }
            case .conditional(let name, let inner):
                // Renders only when the guarding token has a value (FR-4.2);
                // a missing token inside a skipped conditional is not an error.
                if values[name] != nil {
                    out += renderNodes(inner, values: values, missingRequired: &missingRequired)
                }
            }
        }
        return out
    }

    // MARK: - Sanitization (FR-4.4)

    /// Strips illegal filename characters, collapses whitespace and dangling
    /// separators, and enforces the APFS 255-byte UTF-8 limit while keeping
    /// Unicode (Persian titles) intact — no transliteration.
    public static func sanitize(_ raw: String, fileExtension: String) -> String {
        var name = raw
        // Illegal on APFS/Finder: "/" and ":". Also strip control characters.
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.replacingOccurrences(of: ":", with: "-")
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        // Collapse whitespace runs.
        name = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        // Collapse separator artifacts from empty tokens: " - - ", "()", "[]".
        name = name.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\[\s*\]"#, with: "", options: .regularExpression)
        while name.contains("- -") {
            name = name.replacingOccurrences(of: "- -", with: "-")
        }
        name = name.replacingOccurrences(of: #"\s+\."#, with: ".", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        // A name can't start with a dot (hidden) or be empty.
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Untitled.\(fileExtension.lowercased())" }
        return truncateTo255Bytes(name, fileExtension: fileExtension)
    }

    /// APFS limits filenames to 255 UTF-8 bytes; multi-byte scripts hit this
    /// with far fewer characters (FR-4.4). Truncates the stem, keeps the
    /// extension, never splits a character.
    public static func truncateTo255Bytes(_ name: String, fileExtension: String) -> String {
        let maxBytes = 255
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let trimmed = trimToBytes(stem, maxBytes - suffix.utf8.count)
        return trimmed + suffix
    }

    /// Cuts a string to at most `budget` UTF-8 bytes on a character boundary.
    public static func trimToBytes(_ string: String, _ budget: Int) -> String {
        guard string.utf8.count > budget else { return string }
        var truncated = ""
        var used = 0
        for char in string {
            let bytes = String(char).utf8.count
            if used + bytes > budget { break }
            truncated.append(char)
            used += bytes
        }
        return truncated.trimmingCharacters(in: .whitespaces)
    }
}
