import Foundation

/// Text normalization used by the grouping engine (FR-2.1) and lookup matching.
public enum Normalizer {
    /// Noise words stripped from filename stems: edition/format markers that
    /// don't identify the work.
    static let noiseWords: Set<String> = [
        "v1", "v2", "v3", "v4", "v5", "final", "draft", "copy", "ocr",
        "scan", "scanned", "ebook", "retail", "edited", "fixed",
        "epub", "pdf", "mobi", "azw3", "en", "eng",
    ]

    /// Casefolds, strips diacritics, removes punctuation, collapses whitespace.
    /// "Café Été!" → "cafe ete"
    public static func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        let mapped = folded.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return " "
        }
        return String(mapped)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Normalizes a title for matching: normalize + drop leading articles.
    public static func normalizeTitle(_ title: String) -> String {
        var tokens = normalize(title).split(separator: " ").map(String.init)
        if let first = tokens.first, ["the", "a", "an"].contains(first), tokens.count > 1 {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ")
    }

    /// Normalizes an author list into an order-independent set of tokens
    /// (§9: "normalize author sets, not sequences").
    /// ["Frank Herbert"] and ["Herbert, Frank"] produce the same set.
    public static func authorTokenSet(_ authors: [String]) -> Set<String> {
        var tokens: Set<String> = []
        for author in authors {
            for token in normalize(author).split(separator: " ") {
                // Skip initials — they're inconsistent across sources.
                if token.count > 1 {
                    tokens.insert(String(token))
                }
            }
        }
        return tokens
    }

    /// Normalizes a filename stem for rule-3 matching: extension already
    /// removed by caller; separators `._-` collapsed; noise words stripped.
    /// "Dune_v2.final" → "dune"
    public static func normalizeFilenameStem(_ stem: String) -> String {
        // Trailing "(1)"-style duplicate-copy markers are noise, but bare
        // volume numbers are not ("Foundation 2" is a different work than
        // "Foundation 1") — strip only the parenthesized trailing form.
        var stem = stem
        while let range = stem.range(of: #"\s*\(\d+\)\s*$"#, options: .regularExpression) {
            stem.removeSubrange(range)
        }
        let separated = stem.map { ch -> Character in
            if "._-()[]{}+".contains(ch) { return " " }
            return ch
        }
        let tokens = normalize(String(separated))
            .split(separator: " ")
            .map(String.init)
            .filter { !noiseWords.contains($0) }
        return tokens.joined(separator: " ")
    }

    /// Jaccard-style similarity between two normalized strings' token sets.
    /// Used for lookup-candidate scoring and fuzzy title comparison.
    public static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        let setA = Set(normalize(a).split(separator: " "))
        let setB = Set(normalize(b).split(separator: " "))
        guard !setA.isEmpty, !setB.isEmpty else { return 0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(intersection) / Double(union)
    }

    /// Extracts and validates ISBN-10/13 from a raw identifier string.
    /// Returns digits-only (with X check digit allowed for ISBN-10).
    public static func extractISBN(_ raw: String) -> String? {
        let cleaned = raw.uppercased()
            .replacingOccurrences(of: "URN:ISBN:", with: "")
            .replacingOccurrences(of: "ISBN", with: "")
            .filter { $0.isNumber || $0 == "X" }
        switch cleaned.count {
        case 13 where !cleaned.contains("X"):
            return isValidISBN13(cleaned) ? cleaned : nil
        case 10:
            return isValidISBN10(cleaned) ? cleaned : nil
        default:
            return nil
        }
    }

    static func isValidISBN13(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count == 13 else { return false }
        let sum = digits.enumerated().reduce(0) { acc, pair in
            acc + pair.element * (pair.offset % 2 == 0 ? 1 : 3)
        }
        return sum % 10 == 0
    }

    static func isValidISBN10(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        var sum = 0
        for (i, ch) in s.enumerated() {
            let value: Int
            if ch == "X" {
                guard i == 9 else { return false }
                value = 10
            } else if let v = ch.wholeNumberValue {
                value = v
            } else {
                return false
            }
            sum += value * (10 - i)
        }
        return sum % 11 == 0
    }
}
