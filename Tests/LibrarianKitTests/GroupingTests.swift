import XCTest
import GRDB
@testable import LibrarianKit
import LibrarianFixtures

/// Catalog: GRP-01 … GRP-17 (test-case.md).
final class GroupingTests: XCTestCase {
    private func identity(
        _ path: String, isbn: String? = nil, title: String? = nil,
        authors: [String] = [], manual: String? = nil
    ) -> FileIdentity {
        let filename = (path as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        return FileIdentity(
            path: path,
            format: BookFormat(rawValue: ext) ?? .epub,
            stem: stem,
            isbn: isbn,
            titleKey: title.map(Normalizer.key),
            authorKey: authors.isEmpty ? nil : Normalizer.authorSetKey(authors),
            manualGroupId: manual)
    }

    // GRP-01
    func testNormalizerKey() {
        XCTAssertEqual(Normalizer.key("Ḑüné!!"), "dune")
        XCTAssertEqual(Normalizer.key("  The GREAT,  Gatsby. "), "the great gatsby")
        XCTAssertEqual(Normalizer.key("Café — crème"), "cafe creme")
    }

    // GRP-02
    func testStemKeyNoiseWords() {
        XCTAssertEqual(Normalizer.stemKey("dune_v2"), "dune")
        XCTAssertEqual(Normalizer.stemKey("Dune.Final.OCR"), "dune")
        XCTAssertEqual(Normalizer.stemKey("dune (1)"), "dune")
        XCTAssertEqual(Normalizer.stemKey("Moby.Dick.v2"), "moby dick")
        XCTAssertEqual(Normalizer.stemKey("war-and-peace [retail]"), "war and peace")
    }

    // GRP-03
    func testAuthorSetKeyOrderIndependent() {
        XCTAssertEqual(
            Normalizer.authorSetKey(["Frank Herbert", "Kevin Anderson"]),
            Normalizer.authorSetKey(["Kevin Anderson", "Frank Herbert"]))
        XCTAssertNotEqual(
            Normalizer.authorSetKey(["Frank Herbert"]),
            Normalizer.authorSetKey(["Kevin Anderson"]))
    }

    // GRP-04
    func testSimilarityScore() {
        XCTAssertEqual(Normalizer.similarity("Dune", "dune"), 1.0)
        XCTAssertEqual(Normalizer.similarity("Dune", "Emma"), 0.0)
        let partial = Normalizer.similarity("Dune Messiah", "Dune")
        XCTAssertGreaterThan(partial, 0.0)
        XCTAssertLessThan(partial, 1.0)
    }

    // GRP-05
    func testGroupByISBN() {
        let groups = GroupingEngine.propose([
            identity("/x/first-file.epub", isbn: "9780441172719"),
            identity("/x/totally different name.pdf", isbn: "9780441172719"),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].method, .isbn)
    }

    // GRP-06
    func testGroupByTitleAuthor() {
        let groups = GroupingEngine.propose([
            identity("/x/one.epub", title: "Dune", authors: ["Frank Herbert"]),
            identity("/x/two.pdf", title: "DUNE!", authors: ["frank herbert"]),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].method, .metadata)
    }

    // GRP-07
    func testGroupByFilenameStem() {
        let groups = GroupingEngine.propose([
            identity("/x/dune.epub"),
            identity("/x/dune_v2.mobi"),
        ])
        XCTAssertEqual(groups.count, 1)
    }

    // GRP-08
    func testFilenameGroupMarkedAutoGrouped() {
        // epub+pdf join via metadata; the mobi joins only by stem → the whole
        // group needs review (FR-2.5).
        let groups = GroupingEngine.propose([
            identity("/x/dune.epub", title: "Dune", authors: ["Frank Herbert"]),
            identity("/x/dune.pdf", title: "Dune", authors: ["Frank Herbert"]),
            identity("/x/dune_v2.mobi"),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].method, .filename)
    }

    // GRP-09
    func testSameTitleDifferentAuthorsStaySeparate() {
        let groups = GroupingEngine.propose([
            identity("/x/rework.epub", title: "Rework", authors: ["Jason Fried"]),
            identity("/y/rework.epub", title: "Rework", authors: ["Somebody Else"]),
        ])
        XCTAssertEqual(groups.count, 2, "author-token disagreement must keep books apart (§9)")
    }

    // GRP-10
    func testUnknownAuthorJoinsWhenNoConflict() {
        let groups = GroupingEngine.propose([
            identity("/x/dune.epub", title: "Dune", authors: ["Frank Herbert"]),
            identity("/x/dune.mobi"), // no embedded metadata at all
        ])
        XCTAssertEqual(groups.count, 1)
    }

    // GRP-11
    func testManualGroupOverridesAutomatic() {
        let groups = GroupingEngine.propose([
            identity("/x/dune.epub", manual: "token-a"),
            identity("/x/dune.mobi"), // stem-identical, but the epub is pinned
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains { $0.method == .manual })
    }

    // GRP-12
    func testManualSingletonNeverRegroups() {
        let groups = GroupingEngine.propose([
            identity("/x/dune.epub", isbn: "9780441172719", manual: "solo-token"),
            identity("/x/dune_v2.mobi", isbn: "9780441172719"),
        ])
        XCTAssertEqual(groups.count, 2, "even a shared ISBN must not defeat a manual split")
    }

    // GRP-13 (§6.2 acceptance)
    func testDuneAcceptanceCase() throws {
        let (scanner, database, _) = try makeScanner()
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("dune.epub"),
            spec: .init(title: "Dune", authors: ["Frank Herbert"], isbn: "9780441172719"))
        try FixtureFactory.makePdf(
            at: root.appendingPathComponent("Dune - Frank Herbert.pdf"),
            title: "Dune", author: "Frank Herbert")
        try FixtureFactory.makeMobi(
            at: root.appendingPathComponent("dune_v2.mobi"),
            spec: .init(headerTitle: "Dune"))

        _ = try scanner.scan(root: root)
        let library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 1, "one book entry with three format badges")
        let formats = Set(library[0].files.map(\.format))
        XCTAssertEqual(formats, [.epub, .pdf, .mobi])
        XCTAssertEqual(library[0].book.title, "Dune")
        XCTAssertEqual(library[0].book.groupMethod, .filename, "auto-grouped indicator (FR-2.5)")
    }

    // GRP-14
    func testMergeCommand() throws {
        let database = try makeDatabase()
        let coverCache = try makeCoverCache()
        let a = try insertBook(database, title: "Dune", authors: ["Frank Herbert"],
                               year: 1965, filePaths: ["/x/dune.epub"])
        let b = try insertBook(database, title: "Dune (scan)", publisher: "Ace",
                               filePaths: ["/x/dune-scan.pdf"])
        let commands = GroupCommands(database: database, coverCache: coverCache)
        let survivorId = try commands.merge(bookIds: [a.id!, b.id!])

        XCTAssertEqual(survivorId, a.id!, "the more complete book survives")
        let library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library[0].files.count, 2)
        XCTAssertEqual(library[0].book.publisher, "Ace", "empty fields filled from the absorbed book")
        XCTAssertEqual(library[0].book.groupMethod, .manual)
        let tokens = Set(library[0].files.compactMap(\.manualGroupId))
        XCTAssertEqual(tokens.count, 1, "all files share one manual token")
    }

    // GRP-15
    func testUngroupCommand() throws {
        let database = try makeDatabase()
        let coverCache = try makeCoverCache()
        let book = try insertBook(
            database, title: "Dune", authors: ["Frank Herbert"], year: 1965,
            filePaths: ["/x/dune.epub", "/x/dune.pdf", "/x/dune.mobi"])
        let commands = GroupCommands(database: database, coverCache: coverCache)
        let ids = try commands.ungroup(bookId: book.id!)

        XCTAssertEqual(ids.count, 3)
        let library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 3)
        XCTAssertTrue(library.allSatisfy { $0.files.count == 1 })
        let original = library.first { $0.book.id == book.id }
        XCTAssertEqual(original?.book.title, "Dune", "original book keeps its metadata")
        let tokens = library.flatMap { $0.files.compactMap(\.manualGroupId) }
        XCTAssertEqual(Set(tokens).count, 3, "every file gets a unique manual token")
    }

    // GRP-16
    func testMergeSurvivesRescan() throws {
        let (scanner, database, coverCache) = try makeScanner()
        let root = try makeTempDir()
        try FixtureFactory.makeEpub(at: root.appendingPathComponent("alpha.epub"),
                                    spec: .init(title: "Alpha", authors: ["A"]))
        try FixtureFactory.makeEpub(at: root.appendingPathComponent("beta.epub"),
                                    spec: .init(title: "Beta", authors: ["B"]))
        _ = try scanner.scan(root: root)
        var library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 2)

        let commands = GroupCommands(database: database, coverCache: coverCache)
        try commands.merge(bookIds: library.compactMap(\.book.id))

        _ = try scanner.scan(root: root)
        library = try database.fetchLibrary()
        XCTAssertEqual(library.count, 1, "manual merge persists across rescans (FR-2.4)")
        XCTAssertEqual(library[0].files.count, 2)
    }

    // GRP-17
    func testCoverFromFileCommand() throws {
        let (scanner, database, coverCache) = try makeScanner()
        let root = try makeTempDir()
        // Two epubs with metadata match → one book; only the second has a cover.
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("dune.epub"),
            spec: .init(title: "Dune", authors: ["Frank Herbert"]))
        try FixtureFactory.makeEpub(
            at: root.appendingPathComponent("dune retail.epub"),
            spec: .init(title: "Dune", authors: ["Frank Herbert"],
                        coverData: FixtureFactory.tinyJPEG(width: 64, height: 96)))
        _ = try scanner.scan(root: root)
        let entry = try database.fetchLibrary()[0]
        let bookId = entry.book.id!

        let commands = GroupCommands(database: database, coverCache: coverCache)
        let coverless = entry.files.first { $0.filename == "dune.epub" }!
        XCTAssertFalse(try commands.setCover(bookId: bookId, fromFile: coverless),
                       "a file without an embedded cover reports failure")

        let covered = entry.files.first { $0.filename == "dune retail.epub" }!
        XCTAssertTrue(try commands.setCover(bookId: bookId, fromFile: covered))
        let book = try database.writer.read { db in try Book.fetchOne(db, key: bookId)! }
        XCTAssertNotNil(book.coverCachePath)
        XCTAssertEqual(try database.provenance(forBook: bookId)["cover"]?.source, .manual)
    }
}
