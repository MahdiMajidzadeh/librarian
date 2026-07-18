import Foundation

/// Keyword fields in the wild often contain prose (a PDF "Keywords" entry
/// holding the whole marketing blurb), which comma-splitting turns into
/// paragraph-length "tags". This gate keeps only things that look like
/// actual keywords.
public enum TagSanitizer {
    public static let maxTagLength = 48
    public static let maxTagCount = 15

    /// True when a stored tag list looks like real keywords (used to decide
    /// whether previously saved tags should be re-cleaned).
    public static func isValid(_ tags: [String]) -> Bool {
        tags.allSatisfy { $0.count <= maxTagLength && !$0.isEmpty }
    }

    /// Trims, drops prose-length entries, dedupes case-insensitively, and
    /// caps the count. May return an empty array if nothing survives.
    public static func sanitize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maxTagLength else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == maxTagCount { break }
        }
        return result
    }
}
