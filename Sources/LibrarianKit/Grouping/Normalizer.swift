import Foundation

/// Text normalization for grouping (FR-2.1): case-folded, diacritics-stripped,
/// punctuation-removed keys, plus filename-stem cleanup with noise-word removal.
public enum Normalizer {
    /// Edition/format noise words stripped from filename stems (FR-2.1 rule 3).
    static let noiseWords: Set<String> = [
        "v1", "v2", "v3", "v4", "v5", "final", "draft", "ocr", "scan",
        "scanned", "retail", "ebook", "e-book", "edition", "ed", "revised",
        "copy", "new", "full", "complete", "unabridged", "www", "com", "org",
    ]

    /// Normalizes any text into a matching key: lowercase, diacritics stripped,
    /// punctuation removed, whitespace collapsed.
    public static func key(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Normalizes a filename stem for grouping: collapses `._-` separators,
    /// strips bracketed chunks, noise words, and trailing counters like "(1)".
    public static func stemKey(_ stem: String) -> String {
        var s = stem
        // Remove bracketed/parenthesized qualifiers: "(1)", "[retail]", "(ocr)".
        s = s.replacingOccurrences(of: #"[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: " ", options: .regularExpression)
        // Collapse separators into spaces.
        s = s.replacingOccurrences(of: #"[._\-–—]+"#, with: " ", options: .regularExpression)
        let base = key(s)
        let words = base.split(separator: " ").map(String.init).filter { word in
            !noiseWords.contains(word)
        }
        return words.joined(separator: " ")
    }

    /// Human-readable cleanup of a filename stem (for display and inference):
    /// separators become spaces, noise removed, original casing kept.
    public static func cleanStemForDisplay(_ stem: String) -> String {
        var s = stem
        s = s.replacingOccurrences(of: #"[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
        // Normalize only *spaced* dashes to " - " (the author/title
        // separator). Bare hyphens are part of the word: "corrupt-book".
        s = s.replacingOccurrences(of: #"\s+[-–—]\s+"#, with: " - ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        let words = s.split(separator: " ").filter { word in
            !noiseWords.contains(key(String(word)))
        }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Author set key: order-independent (§9 multi-author ordering), normalized.
    public static func authorSetKey(_ authors: [String]) -> String {
        authors.map { key($0) }.filter { !$0.isEmpty }.sorted().joined(separator: "|")
    }

    /// Similarity in [0, 1] between two strings, based on token overlap
    /// (Jaccard). Used for lookup candidate scoring (FR-3.4, §9).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let ta = Set(key(a).split(separator: " "))
        let tb = Set(key(b).split(separator: " "))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let intersection = ta.intersection(tb).count
        let union = ta.union(tb).count
        return Double(intersection) / Double(union)
    }
}
