import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Stores book covers in Application Support as JPEG (FR-3.5): a grid-sized
/// rendition capped at 600 px on the long edge, plus the original for the
/// detail view and export.
public final class CoverCache: Sendable {
    public let directory: URL
    public static let gridMaxPixels = 600

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func `default`() throws -> CoverCache {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try CoverCache(directory: support.appendingPathComponent("BookShelf/Covers"))
    }

    public func gridURL(bookId: Int64) -> URL {
        directory.appendingPathComponent("\(bookId).jpg")
    }

    public func originalURL(bookId: Int64) -> URL {
        directory.appendingPathComponent("\(bookId)_full.jpg")
    }

    /// Stores cover data for a book; returns the grid-rendition path
    /// (the value persisted in `book.coverCachePath`).
    @discardableResult
    public func store(imageData: Data, bookId: Int64) throws -> URL {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ParseError("cover data is not a decodable image")
        }

        // Original, re-encoded as JPEG.
        guard let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ParseError("cover image could not be decoded")
        }
        try writeJPEG(fullImage, to: originalURL(bookId: bookId))

        // Grid rendition ≤ 600 px long edge.
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.gridMaxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        let gridURL = self.gridURL(bookId: bookId)
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            try writeJPEG(thumb, to: gridURL)
        } else {
            try writeJPEG(fullImage, to: gridURL)
        }
        return gridURL
    }

    public func removeCover(bookId: Int64) {
        try? FileManager.default.removeItem(at: gridURL(bookId: bookId))
        try? FileManager.default.removeItem(at: originalURL(bookId: bookId))
    }

    public func totalSizeBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    public func clear() throws {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ParseError("cannot create JPEG destination at \(url.path)")
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ParseError("failed to write JPEG at \(url.path)")
        }
    }
}
