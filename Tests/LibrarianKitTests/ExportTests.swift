import XCTest
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: EXP-01 … EXP-08 (test-case.md).
final class ExportTests: XCTestCase {
    private func sampleEntries() -> [Exporters.Entry] {
        var dune = Book(title: "Dune", authors: ["Frank Herbert"])
        dune.id = 1
        dune.year = 1965
        dune.isbn13 = "9780441172719"
        dune.series = "Dune Chronicles"
        dune.seriesIndex = 1
        dune.metadataStatus = .complete
        dune.groupMethod = .isbn
        var duneEpub = BookFile(
            bookId: 1, path: "/books/dune.epub", format: .epub,
            sizeBytes: 1000, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        duneEpub.id = 1
        var dunePdf = BookFile(
            bookId: 1, path: "/books/dune.pdf", format: .pdf,
            sizeBytes: 2000, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            missingFlag: true)
        dunePdf.id = 2

        var owl = Book(title: "بوف کور", authors: ["صادق هدایت", "Second Person"])
        owl.id = 2
        owl.language = "fa"
        var owlFile = BookFile(
            bookId: 2, path: "/books/بوف کور.epub", format: .epub,
            sizeBytes: 500, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        owlFile.id = 3

        return [(dune, [duneEpub, dunePdf]), (owl, [owlFile])]
    }

    // EXP-01
    func testJSONSchema() throws {
        let out = try makeTempDir().appendingPathComponent("export.json")
        try Exporters.exportJSON(entries: sampleEntries(), provenance: [:], to: out)

        let payload = try JSONSerialization.jsonObject(
            with: Data(contentsOf: out)) as! [String: Any]
        XCTAssertEqual(payload["schema_version"] as? Int, 1)
        XCTAssertEqual(payload["book_count"] as? Int, 2)
        let books = payload["books"] as! [[String: Any]]
        XCTAssertEqual(books.count, 2)

        let dune = books.first { ($0["title"] as? String) == "Dune" }!
        XCTAssertEqual(dune["authors"] as? [String], ["Frank Herbert"])
        XCTAssertEqual(dune["isbn13"] as? String, "9780441172719")
        XCTAssertEqual(dune["group_method"] as? String, "isbn")
        let files = dune["files"] as! [[String: Any]]
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0]["path"] as? String, "/books/dune.epub")
        XCTAssertEqual(files[0]["format"] as? String, "epub")
        XCTAssertEqual(files[0]["size_bytes"] as? Int, 1000)
        XCTAssertEqual(files[0]["missing"] as? Bool, false)
        XCTAssertEqual(files[1]["missing"] as? Bool, true)
        XCTAssertNotNil(files[0]["modified_date"])
    }

    // EXP-02
    func testJSONProvenanceIncluded() throws {
        let out = try makeTempDir().appendingPathComponent("export.json")
        let provenance: [Int64: [String: Provenance]] = [
            1: [
                "title": Provenance(bookId: 1, field: "title", source: .embedded),
                "year": Provenance(bookId: 1, field: "year", source: .googleBooks),
            ],
        ]
        try Exporters.exportJSON(entries: sampleEntries(), provenance: provenance, to: out)

        let payload = try JSONSerialization.jsonObject(
            with: Data(contentsOf: out)) as! [String: Any]
        let books = payload["books"] as! [[String: Any]]
        let dune = books.first { ($0["title"] as? String) == "Dune" }!
        let provenanceMap = dune["provenance"] as! [String: [String: Any]]
        XCTAssertEqual(provenanceMap["title"]?["source"] as? String, "embedded")
        XCTAssertEqual(provenanceMap["year"]?["source"] as? String, "google_books")
        XCTAssertNotNil(provenanceMap["year"]?["fetched_at"])
    }

    // EXP-03
    func testJSONCoversFolder() throws {
        let dir = try makeTempDir()
        let out = dir.appendingPathComponent("export.json")
        let cache = try makeCoverCache()
        try cache.store(FixtureFactory.tinyJPEG(), forBookId: 1)

        try Exporters.exportJSON(
            entries: sampleEntries(), provenance: [:], to: out,
            options: .init(includeCovers: true), coverCache: cache)

        let coverFile = dir.appendingPathComponent("covers/book-1.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverFile.path))
        let payload = try JSONSerialization.jsonObject(
            with: Data(contentsOf: out)) as! [String: Any]
        let books = payload["books"] as! [[String: Any]]
        let dune = books.first { ($0["title"] as? String) == "Dune" }!
        XCTAssertEqual(dune["cover_path"] as? String, "covers/book-1.jpg")
    }

    // EXP-04
    func testCSVHeaderAndRow() throws {
        let out = try makeTempDir().appendingPathComponent("export.csv")
        try Exporters.exportCSV(entries: sampleEntries(), to: out)
        let text = String(data: try Data(contentsOf: out), encoding: .utf8)!
        let lines = text.split(separator: "\r\n").map(String.init)

        // String(data:) may or may not surface the BOM character; EXP-05
        // asserts the raw bytes. Here only the header content matters.
        let header = lines[0].replacingOccurrences(of: "\u{FEFF}", with: "")
        XCTAssertTrue(header.hasPrefix("title,authors,series"))
        XCTAssertEqual(lines.count, 3) // header + 2 books
        let duneLine = lines.first { $0.hasPrefix("Dune") }!
        XCTAssertTrue(duneLine.contains("epub;pdf"), "formats joined with ';' (FR-5.3)")
        XCTAssertTrue(duneLine.contains("9780441172719"))
    }

    // EXP-05
    func testCSVBOMAndPersian() throws {
        let out = try makeTempDir().appendingPathComponent("export.csv")
        try Exporters.exportCSV(entries: sampleEntries(), to: out)
        let raw = try Data(contentsOf: out)
        XCTAssertEqual([UInt8](raw.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 BOM for Excel")
        let text = String(data: raw, encoding: .utf8)!
        XCTAssertTrue(text.contains("بوف کور"))
        XCTAssertTrue(text.contains("صادق هدایت"))
    }

    // EXP-06
    func testCSVEscaping() {
        XCTAssertEqual(Exporters.escapeCSV("plain", delimiter: ","), "plain")
        XCTAssertEqual(Exporters.escapeCSV("has,comma", delimiter: ","), "\"has,comma\"")
        XCTAssertEqual(
            Exporters.escapeCSV("say \"hi\"", delimiter: ","), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(
            Exporters.escapeCSV("line\nbreak", delimiter: ","), "\"line\nbreak\"")
        XCTAssertEqual(Exporters.escapeCSV("has,comma", delimiter: ";"), "has,comma",
                       "only the active delimiter forces quoting")
    }

    // EXP-07
    func testCSVDelimiterOptions() throws {
        let dir = try makeTempDir()
        for (delimiter, name) in [(";", "semi.csv"), ("\t", "tab.csv")] {
            let out = dir.appendingPathComponent(name)
            try Exporters.exportCSV(
                entries: sampleEntries(), to: out,
                options: .init(delimiter: delimiter))
            let text = String(data: try Data(contentsOf: out), encoding: .utf8)!
            let header = text.split(separator: "\r\n")[0]
            XCTAssertTrue(header.contains("title\(delimiter)authors"))
        }
    }

    // EXP-08
    func testCSVMultiValueSeparator() throws {
        let out = try makeTempDir().appendingPathComponent("export.csv")
        try Exporters.exportCSV(
            entries: sampleEntries(), to: out,
            options: .init(delimiter: ";", multiValueSeparator: " | "))
        let text = String(data: try Data(contentsOf: out), encoding: .utf8)!
        XCTAssertTrue(text.contains("صادق هدایت | Second Person"))
    }
}
