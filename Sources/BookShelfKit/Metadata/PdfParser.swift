import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Extracts PDF Info-dictionary metadata via PDFKit, with a first-page render
/// as the cover fallback (spec §6.3 pipeline step 1).
public enum PdfParser {
    /// Long edge, in pixels, of the rendered first-page cover.
    static let coverRenderMaxPixels: CGFloat = 900

    public static func parse(url: URL) throws -> EmbeddedMetadata {
        guard let document = PDFDocument(url: url) else {
            throw ParseError("not a readable PDF")
        }
        if document.isLocked {
            throw ParseError("PDF is password-protected")
        }

        var meta = EmbeddedMetadata()
        let attributes = document.documentAttributes ?? [:]

        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String,
           !title.trimmingCharacters(in: .whitespaces).isEmpty {
            meta.title = title.trimmingCharacters(in: .whitespaces)
        }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String {
            meta.authors = splitAuthors(author)
        }
        if let subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String,
           !subject.isEmpty {
            meta.description = subject
        }
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] {
            // PDFKit may return a single string or an array of strings, and
            // either can itself contain ";" / "," separated lists.
            let rawItems: [String]
            if let list = keywords as? [String] {
                rawItems = list
            } else if let joined = keywords as? String {
                rawItems = [joined]
            } else {
                rawItems = []
            }
            meta.subjects = rawItems
                .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",;")) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let created = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date {
            meta.year = Calendar(identifier: .gregorian).component(.year, from: created)
        }

        meta.coverData = renderFirstPage(document)
        return meta
    }

    /// "A; B", "A, B", "A & B", "A and B" → ["A", "B"]
    public static func splitAuthors(_ raw: String) -> [String] {
        var text = raw
        for separator in [" and ", " & ", ";"] {
            text = text.replacingOccurrences(of: separator, with: "|")
        }
        // Comma is ambiguous ("Last, First") — only treat as separator when
        // it yields more than one plausible name on both sides.
        if !text.contains("|"), text.contains(",") {
            let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2, parts.allSatisfy({ $0.split(separator: " ").count >= 2 }) {
                text = parts.joined(separator: "|")
            }
        }
        return text
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Renders page 1 to JPEG data for use as the cover.
    static func renderFirstPage(_ document: PDFDocument) -> Data? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let scale = coverRenderMaxPixels / max(bounds.width, bounds.height)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
