import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Local cover cache (FR-3.5): JPEGs under Application Support. Two variants
/// per book — a grid thumbnail (max 600 px long edge) and the original bytes
/// for the detail view and export.
public final class CoverCache: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Cache in `~/Library/Application Support/Librarian/Covers`.
    public static func standard() throws -> CoverCache {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try CoverCache(
            directory: support.appendingPathComponent("Librarian/Covers", isDirectory: true))
    }

    /// Stores cover data for a book; returns the relative cache path to store
    /// on the Book record (the grid-thumbnail path).
    @discardableResult
    public func store(_ data: Data, forBookId bookId: Int64) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let originalName = "book-\(bookId)-original.jpg"
        let thumbName = "book-\(bookId)-grid.jpg"

        let original = Self.reencodeJPEG(data) ?? data
        try original.write(to: directory.appendingPathComponent(originalName), options: .atomic)

        let thumb = Self.downscaleJPEG(data, maxLongEdge: 600) ?? original
        try thumb.write(to: directory.appendingPathComponent(thumbName), options: .atomic)
        return thumbName
    }

    public func gridURL(forPath relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }

    public func originalURL(forBookId bookId: Int64) -> URL? {
        let url = directory.appendingPathComponent("book-\(bookId)-original.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func removeCover(forBookId bookId: Int64) {
        lock.lock(); defer { lock.unlock() }
        for name in ["book-\(bookId)-original.jpg", "book-\(bookId)-grid.jpg"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Total size of the cache in bytes (Settings display, §6.7).
    public func totalSizeBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Clears every cached cover (Settings, §6.7).
    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - ImageIO helpers

    static func downscaleJPEG(_ data: Data, maxLongEdge: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return PdfParser.jpegData(from: image)
    }

    /// Re-encodes arbitrary image data (PNG/GIF/JPEG) to JPEG, keeping size.
    static func reencodeJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return PdfParser.jpegData(from: image)
    }
}
