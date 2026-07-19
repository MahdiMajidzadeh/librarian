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
            return .success(dropJunkTitle(meta))
        } catch let error as ParseError {
            return .failure(error)
        } catch {
            return .failure(ParseError("\(error)"))
        }
    }

    /// Publishers routinely stamp the source filename or bare ISBN into the
    /// Title field ("0071501126.pdf"). Such a title must never beat the
    /// filename-derived one, so it is dropped here — but when it embeds a
    /// valid ISBN, that identifier is salvaged for grouping and lookup.
    private static func dropJunkTitle(_ meta: EmbeddedMetadata) -> EmbeddedMetadata {
        guard let title = meta.title, EmbeddedMetadata.isJunkTitle(title) else { return meta }
        var cleaned = meta
        cleaned.title = nil
        if cleaned.isbn == nil, let isbn = Normalizer.extractISBN(title) {
            cleaned.isbn = isbn
        }
        return cleaned
    }
}
