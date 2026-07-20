import XCTest
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: PDF-01 … PDF-04 (test-case.md).
final class PdfParserTests: XCTestCase {
    // PDF-01
    func testParseInfoDictionary() throws {
        let url = try makeTempDir().appendingPathComponent("book.pdf")
        try FixtureFactory.makePdf(at: url, title: "Dune", author: "Frank Herbert")
        let metadata = try PdfParser.parse(url: url, renderCover: false)
        XCTAssertEqual(metadata.title, "Dune")
        XCTAssertEqual(metadata.authors, ["Frank Herbert"])
        // CoreGraphics stamps the creation date at build time.
        XCTAssertEqual(metadata.year, Calendar.current.component(.year, from: Date()))
    }

    // PDF-02
    func testMultipleAuthorsSplit() throws {
        let url = try makeTempDir().appendingPathComponent("book.pdf")
        try FixtureFactory.makePdf(at: url, title: "T", author: "Ann Author; Bob Writer & Carol Co")
        let metadata = try PdfParser.parse(url: url, renderCover: false)
        XCTAssertEqual(metadata.authors, ["Ann Author", "Bob Writer", "Carol Co"])
    }

    // PDF-03
    func testFirstPageCoverRender() throws {
        let url = try makeTempDir().appendingPathComponent("book.pdf")
        try FixtureFactory.makePdf(at: url, title: "Covered")
        let metadata = try PdfParser.parse(url: url, renderCover: true)
        let cover = try XCTUnwrap(metadata.coverData)
        XCTAssertEqual([UInt8](cover.prefix(2)), [0xFF, 0xD8], "cover must be JPEG data")
    }

    // PDF-04
    func testUnreadableThrows() throws {
        let url = try makeTempDir().appendingPathComponent("fake.pdf")
        try Data("not a pdf at all".utf8).write(to: url)
        XCTAssertThrowsError(try PdfParser.parse(url: url))
    }
}
