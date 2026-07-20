import XCTest
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: META-01 … META-10 (test-case.md).
final class MetadataTests: XCTestCase {
    // META-01
    func testJunkTitleDropped() {
        var metadata = BookMetadata()
        metadata.title = "Untitled"
        var sanitized = MetadataExtractor.sanitized(metadata, filename: "real-name.epub")
        XCTAssertNil(sanitized.title)

        metadata.title = "unknown"
        sanitized = MetadataExtractor.sanitized(metadata, filename: "real-name.epub")
        XCTAssertNil(sanitized.title)

        metadata.title = "Dune"
        sanitized = MetadataExtractor.sanitized(metadata, filename: "real-name.epub")
        XCTAssertEqual(sanitized.title, "Dune")
    }

    // META-02
    func testUnknownAuthorDropped() {
        var metadata = BookMetadata()
        metadata.authors = ["Unknown", "  ", "Frank Herbert", "unknown author"]
        let sanitized = MetadataExtractor.sanitized(metadata, filename: "x.epub")
        XCTAssertEqual(sanitized.authors, ["Frank Herbert"])
    }

    // META-03
    func testISBNNormalization() {
        XCTAssertEqual(ISBN.normalize("978-0-441-17271-9"), "9780441172719")
        XCTAssertEqual(ISBN.normalize("urn:isbn:0441172717"), "0441172717")
        XCTAssertEqual(ISBN.normalize("044117271x"), "044117271X")
        XCTAssertNil(ISBN.normalize("12345"))
        XCTAssertNil(ISBN.normalize("no digits here"))

        var metadata = BookMetadata()
        ISBN.assign("9780441172719", to: &metadata)
        ISBN.assign("0441172717", to: &metadata)
        XCTAssertEqual(metadata.isbn13, "9780441172719")
        XCTAssertEqual(metadata.isbn10, "0441172717")
    }

    // META-04
    func testParseYearFormats() {
        XCTAssertEqual(parseYear("2005-06-01"), 2005)
        XCTAssertEqual(parseYear("June 2005"), 2005)
        XCTAssertEqual(parseYear("2005"), 2005)
        XCTAssertEqual(parseYear("01/06/2005"), 2005)
        XCTAssertNil(parseYear("someday"))
        XCTAssertNil(parseYear(nil))
        XCTAssertNil(parseYear("year 12"))
    }

    // META-05 (§6.3 acceptance seed)
    func testFilenameInferenceAuthorTitle() {
        let guess = FilenameInference.guess(fromStem: "Herbert - Dune")
        XCTAssertEqual(guess.author, "Herbert")
        XCTAssertEqual(guess.title, "Dune")
    }

    // META-06
    func testFilenameInferenceTitleAuthor() {
        // First part has digits/too many words → treated as the title.
        let guess = FilenameInference.guess(
            fromStem: "The Count of Monte Cristo Volume 2 - Alexandre Dumas")
        XCTAssertEqual(guess.title, "The Count of Monte Cristo Volume 2")
        XCTAssertEqual(guess.author, "Alexandre Dumas")
    }

    // META-07
    func testFilenameInferenceTitleOnly() {
        let guess = FilenameInference.guess(fromStem: "book_final2")
        XCTAssertNil(guess.author)
        XCTAssertFalse(guess.title.isEmpty)
    }

    // META-08
    func testExtractorDispatchUnsupportedFormat() throws {
        let url = try makeTempDir().appendingPathComponent("notes.txt")
        try Data("just text".utf8).write(to: url)
        let result = MetadataExtractor.extract(url: url, format: .txt)
        XCTAssertNil(result.parseErrorNote)
        XCTAssertTrue(result.metadata.isEmpty)
    }

    // META-09
    func testCoverCacheStoreAndVariants() throws {
        let cache = try makeCoverCache()
        let big = FixtureFactory.tinyJPEG(width: 1200, height: 1800)
        let path = try cache.store(big, forBookId: 7)

        let gridURL = cache.gridURL(forPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gridURL.path))
        let originalURL = try XCTUnwrap(cache.originalURL(forBookId: 7))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))

        // Grid variant is downscaled to ≤ 600 px on the long edge (FR-3.5).
        let gridData = try Data(contentsOf: gridURL)
        let source = CGImageSourceCreateWithData(gridData as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        let width = props[kCGImagePropertyPixelWidth] as! Int
        let height = props[kCGImagePropertyPixelHeight] as! Int
        XCTAssertLessThanOrEqual(max(width, height), 600)
    }

    // META-10
    func testCoverCacheClearAndSize() throws {
        let cache = try makeCoverCache()
        XCTAssertEqual(cache.totalSizeBytes(), 0)
        try cache.store(FixtureFactory.tinyJPEG(), forBookId: 1)
        XCTAssertGreaterThan(cache.totalSizeBytes(), 0)
        try cache.clear()
        XCTAssertEqual(cache.totalSizeBytes(), 0)
        XCTAssertNil(cache.originalURL(forBookId: 1))
    }
}
