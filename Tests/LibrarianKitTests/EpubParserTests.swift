import XCTest
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: EPUB-01 … EPUB-09 (test-case.md).
final class EpubParserTests: XCTestCase {
    // EPUB-01
    func testParseDublinCore() throws {
        let url = try makeTempDir().appendingPathComponent("book.epub")
        try FixtureFactory.makeEpub(at: url, spec: .init(
            title: "Dune",
            authors: ["Frank Herbert", "Kevin J. Anderson"],
            language: "en",
            publisher: "Ace Books",
            date: "1990-09-01",
            description: "The spice must flow."))
        let metadata = try EpubParser.parse(url: url)
        XCTAssertEqual(metadata.title, "Dune")
        XCTAssertEqual(metadata.authors, ["Frank Herbert", "Kevin J. Anderson"])
        XCTAssertEqual(metadata.language, "en")
        XCTAssertEqual(metadata.publisher, "Ace Books")
        XCTAssertEqual(metadata.year, 1990)
        XCTAssertEqual(metadata.description, "The spice must flow.")
    }

    // EPUB-02
    func testParseISBNFromIdentifier() throws {
        let url = try makeTempDir().appendingPathComponent("book.epub")
        try FixtureFactory.makeEpub(at: url, spec: .init(
            title: "Dune", isbn: "978-0-441-17271-9", identifierScheme: "ISBN"))
        let metadata = try EpubParser.parse(url: url)
        XCTAssertEqual(metadata.isbn13, "9780441172719")
    }

    // EPUB-03
    func testIgnoreUUIDIdentifier() throws {
        let url = try makeTempDir().appendingPathComponent("book.epub")
        try FixtureFactory.makeEpub(at: url, spec: .init(
            title: "Dune", isbn: nil,
            extraIdentifier: "urn:uuid:12345678-1234-1234-1234-123456789012"))
        let metadata = try EpubParser.parse(url: url)
        XCTAssertNil(metadata.isbn13)
        XCTAssertNil(metadata.isbn10)
    }

    // EPUB-04
    func testParseCalibreSeries() throws {
        let url = try makeTempDir().appendingPathComponent("book.epub")
        try FixtureFactory.makeEpub(at: url, spec: .init(
            title: "Dune Messiah", series: "Dune Chronicles", seriesIndex: 2))
        let metadata = try EpubParser.parse(url: url)
        XCTAssertEqual(metadata.series, "Dune Chronicles")
        XCTAssertEqual(metadata.seriesIndex, 2)
    }

    // EPUB-05
    func testCoverByMetaReference() throws {
        let url = try makeTempDir().appendingPathComponent("book.epub")
        let cover = FixtureFactory.tinyJPEG()
        try FixtureFactory.makeEpub(at: url, spec: .init(
            title: "Dune", coverData: cover, coverStyle: "meta"))
        let metadata = try EpubParser.parse(url: url)
        XCTAssertEqual(metadata.coverData, cover)
    }

    // EPUB-06
    func testCoverByProperties() throws {
        let url = try makeTempDir().appendingPathComponent("book.epub")
        let cover = FixtureFactory.tinyJPEG()
        try FixtureFactory.makeEpub(at: url, spec: .init(
            title: "Dune", coverData: cover, coverStyle: "properties"))
        let metadata = try EpubParser.parse(url: url)
        XCTAssertEqual(metadata.coverData, cover)
    }

    // EPUB-07
    func testPercentEncodedCoverHref() throws {
        let url = try makeTempDir().appendingPathComponent("book.epub")
        let cover = FixtureFactory.tinyJPEG()
        try FixtureFactory.makeEpub(at: url, spec: .init(
            title: "Dune", coverData: cover, coverStyle: "meta",
            percentEncodedCoverHref: true))
        let metadata = try EpubParser.parse(url: url)
        XCTAssertEqual(metadata.coverData, cover, "percent-encoded hrefs must resolve")
    }

    // EPUB-08
    func testNotAZipThrows() throws {
        let url = try makeTempDir().appendingPathComponent("fake.epub")
        try Data("definitely not a zip".utf8).write(to: url)
        XCTAssertThrowsError(try EpubParser.parse(url: url)) { error in
            XCTAssertEqual(error as? EpubParser.ParseError, .notAZipArchive)
        }
    }

    // EPUB-09
    func testMissingContainerThrows() throws {
        let url = try makeTempDir().appendingPathComponent("bare.epub")
        try FixtureFactory.makeBareZip(at: url) // valid zip, no container.xml
        XCTAssertThrowsError(try EpubParser.parse(url: url)) { error in
            XCTAssertEqual(error as? EpubParser.ParseError, .missingContainer)
        }
    }
}
