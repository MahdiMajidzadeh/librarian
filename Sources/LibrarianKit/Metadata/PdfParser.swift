import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Parses PDF embedded metadata via the Info/XMP dictionary and renders the
/// first page as a cover fallback (§6.3 step 1). Uses CoreGraphics + ImageIO
/// for rendering so LibrarianKit stays free of AppKit.
public enum PdfParser {
    public enum ParseError: Error, LocalizedError {
        case unreadable

        public var errorDescription: String? { "Not a readable PDF document" }
    }

    public static func parse(url: URL, renderCover: Bool = true) throws -> BookMetadata {
        guard let document = PDFDocument(url: url) else {
            throw ParseError.unreadable
        }
        var metadata = BookMetadata()

        if let attributes = document.documentAttributes {
            if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String,
               !title.trimmingCharacters(in: .whitespaces).isEmpty {
                metadata.title = title.trimmingCharacters(in: .whitespaces)
            }
            if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String,
               !author.trimmingCharacters(in: .whitespaces).isEmpty {
                // Info dictionaries often join multiple authors with , ; or &.
                metadata.authors = author
                    .components(separatedBy: CharacterSet(charactersIn: ";&"))
                    .flatMap { $0.components(separatedBy: ", ") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            if let subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String,
               metadata.description == nil,
               !subject.trimmingCharacters(in: .whitespaces).isEmpty {
                metadata.description = subject
            }
            if let date = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date {
                metadata.year = Calendar(identifier: .gregorian).component(.year, from: date)
            }
        }

        if renderCover, metadata.coverData == nil {
            metadata.coverData = renderFirstPage(of: document)
        }
        return metadata
    }

    /// Renders page 1 to JPEG data (max 900 px long edge) with CoreGraphics.
    static func renderFirstPage(of document: PDFDocument, maxLongEdge: CGFloat = 900) -> Data? {
        guard let page = document.page(at: 0)?.pageRef else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }

        let scale = min(maxLongEdge / max(box.width, box.height), 4)
        let width = Int(box.width * scale)
        let height = Int(box.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        context.drawPDFPage(page)

        guard let image = context.makeImage() else { return nil }
        return jpegData(from: image)
    }

    static func jpegData(from image: CGImage, quality: CGFloat = 0.85) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
