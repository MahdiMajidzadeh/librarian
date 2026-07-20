import Foundation

/// Dispatches embedded-metadata extraction by format (§6.3 step 1).
/// Parse failures are non-fatal (§9): the result carries an error note and
/// the book falls back to filename-derived identity.
public enum MetadataExtractor {
    public struct Result: Sendable {
        public var metadata: BookMetadata
        public var parseErrorNote: String?
    }

    public static func extract(url: URL, format: BookFormat) -> Result {
        guard format.hasEmbeddedSupport else {
            return Result(metadata: BookMetadata(), parseErrorNote: nil)
        }
        do {
            let metadata: BookMetadata
            switch format {
            case .epub:
                metadata = try EpubParser.parse(url: url)
            case .pdf:
                metadata = try PdfParser.parse(url: url)
            case .mobi, .azw3:
                metadata = try MobiParser.parse(url: url)
            default:
                metadata = BookMetadata()
            }
            return Result(metadata: sanitized(metadata, filename: url.lastPathComponent))
        } catch {
            return Result(
                metadata: BookMetadata(),
                parseErrorNote: "\(format.badge) parse failed: \(error.localizedDescription)")
        }
    }

    /// Junk embedded titles ("Untitled", "unknown", the bare filename of a
    /// conversion tool) must not mask the real filename-derived title.
    static func sanitized(_ metadata: BookMetadata, filename: String) -> BookMetadata {
        var m = metadata
        if let title = m.title {
            let key = Normalizer.key(title)
            let junk: Set<String> = ["untitled", "unknown", "no title", "title", "document", "book"]
            if key.isEmpty || junk.contains(key) {
                m.title = nil
            }
        }
        m.authors = m.authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { author in
                let key = Normalizer.key(author)
                return !key.isEmpty && key != "unknown" && key != "unknown author"
            }
        return m
    }
}
