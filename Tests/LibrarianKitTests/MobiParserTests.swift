import XCTest
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: MOBI-01 … MOBI-06 (test-case.md).
final class MobiParserTests: XCTestCase {
    // MOBI-01
    func testParseFullTitle() throws {
        let url = try makeTempDir().appendingPathComponent("book.mobi")
        try FixtureFactory.makeMobi(at: url, spec: .init(headerTitle: "Dune Messiah"))
        let metadata = try MobiParser.parse(url: url)
        XCTAssertEqual(metadata.title, "Dune Messiah")
    }

    // MOBI-02
    func testParseEXTHFields() throws {
        let url = try makeTempDir().appendingPathComponent("book.azw3")
        try FixtureFactory.makeMobi(at: url, spec: .init(
            headerTitle: "Dune",
            author: "Frank Herbert",
            publisher: "Ace",
            description: "Spice.",
            isbn: "9780441172719",
            publishDate: "1990-09-01",
            language: "en"))
        let metadata = try MobiParser.parse(url: url)
        XCTAssertEqual(metadata.authors, ["Frank Herbert"])
        XCTAssertEqual(metadata.publisher, "Ace")
        XCTAssertEqual(metadata.description, "Spice.")
        XCTAssertEqual(metadata.isbn13, "9780441172719")
        XCTAssertEqual(metadata.year, 1990)
        XCTAssertEqual(metadata.language, "en")
    }

    // MOBI-03
    func testParseCoverRecord() throws {
        let url = try makeTempDir().appendingPathComponent("book.mobi")
        let cover = FixtureFactory.tinyJPEG()
        try FixtureFactory.makeMobi(at: url, spec: .init(headerTitle: "Dune", coverData: cover))
        let metadata = try MobiParser.parse(url: url)
        XCTAssertEqual(metadata.coverData, cover)
    }

    // MOBI-04
    func testMalformedEXTHRecordStopsCleanly() throws {
        let url = try makeTempDir().appendingPathComponent("book.mobi")
        try FixtureFactory.makeMobi(at: url, spec: .init(
            headerTitle: "Dune", author: "Frank Herbert", malformedEXTHRecord: true))
        let metadata = try MobiParser.parse(url: url)
        // Records before the malformed one are kept; no crash, no throw.
        XCTAssertEqual(metadata.authors, ["Frank Herbert"])
    }

    // MOBI-05
    func testNotBookMobiThrows() throws {
        let url = try makeTempDir().appendingPathComponent("fake.mobi")
        try Data(repeating: 0x41, count: 200).write(to: url)
        XCTAssertThrowsError(try MobiParser.parse(url: url)) { error in
            XCTAssertEqual(error as? MobiParser.ParseError, .notPalmDatabase)
        }
    }

    // MOBI-06
    func testUpdatedTitleOverridesHeaderTitle() throws {
        let url = try makeTempDir().appendingPathComponent("book.mobi")
        try FixtureFactory.makeMobi(at: url, spec: .init(
            headerTitle: "dune-final-OCR", updatedTitle: "Dune"))
        let metadata = try MobiParser.parse(url: url)
        XCTAssertEqual(metadata.title, "Dune")
    }
}
