import Foundation

/// Dispatches embedded-metadata extraction by format (spec §4 tier 1).
/// Recognized-only formats (djvu, cbz, …) return nil — their metadata comes
/// from online lookup or filename inference alone.
public enum MetadataExtractor {
    public static func extract(url: URL, format: BookFormat) -> Result<EmbeddedMetadata, ParseError>? {
        guard format.supportsEmbeddedMetadata else { return nil }
        do {
            let meta: EmbeddedMetadata
            switch format {
            case .epub:
                meta = try EpubParser.parse(url: url)
            case .pdf:
                meta = try PdfParser.parse(url: url)
            case .mobi, .azw3:
                meta = try MobiParser.parse(url: url)
            default:
                return nil
            }
            return .success(meta)
        } catch let error as ParseError {
            return .failure(error)
        } catch {
            return .failure(ParseError("\(error)"))
        }
    }

    /// Grouping seed for a scanned file: embedded metadata when parseable,
    /// filename stem always.
    public static func groupingSeed(for file: ScannedFile) -> GroupingSeed {
        var seed = GroupingSeed.fromFilename(file.url)
        if case .success(let meta)? = extract(url: file.url, format: file.format) {
            seed.isbn = meta.isbn
            seed.title = meta.title
            seed.authors = meta.authors
        }
        return seed
    }
}
