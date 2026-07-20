import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// Programmatic ebook builders for tests and the demo-library seeder.
/// Every builder produces a structurally valid file that LibrarianKit's
/// parsers can read back.
public enum FixtureFactory {
    // MARK: - EPUB

    public struct EpubSpec {
        public var title: String?
        public var authors: [String]
        public var isbn: String?
        public var identifierScheme: String?     // "ISBN" / nil
        public var extraIdentifier: String?      // e.g. a UUID identifier
        public var language: String?
        public var publisher: String?
        public var date: String?
        public var description: String?
        public var series: String?
        public var seriesIndex: Double?
        public var coverData: Data?
        /// "meta" (EPUB 2 `<meta name="cover">`), "properties" (EPUB 3), or nil.
        public var coverStyle: String
        /// Percent-encode the cover href in the manifest ("cover%20image.jpg").
        public var percentEncodedCoverHref: Bool

        public init(
            title: String? = nil, authors: [String] = [], isbn: String? = nil,
            identifierScheme: String? = "ISBN", extraIdentifier: String? = nil,
            language: String? = nil, publisher: String? = nil, date: String? = nil,
            description: String? = nil, series: String? = nil, seriesIndex: Double? = nil,
            coverData: Data? = nil, coverStyle: String = "meta",
            percentEncodedCoverHref: Bool = false
        ) {
            self.title = title
            self.authors = authors
            self.isbn = isbn
            self.identifierScheme = identifierScheme
            self.extraIdentifier = extraIdentifier
            self.language = language
            self.publisher = publisher
            self.date = date
            self.description = description
            self.series = series
            self.seriesIndex = seriesIndex
            self.coverData = coverData
            self.coverStyle = coverStyle
            self.percentEncodedCoverHref = percentEncodedCoverHref
        }
    }

    public static func makeEpub(at url: URL, spec: EpubSpec) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)

        try addEntry(archive, "mimetype", Data("application/epub+zip".utf8))
        try addEntry(archive, "META-INF/container.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8))

        var metadataXML = ""
        if let title = spec.title {
            metadataXML += "<dc:title>\(escapeXML(title))</dc:title>\n"
        }
        for author in spec.authors {
            metadataXML += "<dc:creator>\(escapeXML(author))</dc:creator>\n"
        }
        if let isbn = spec.isbn {
            let scheme = spec.identifierScheme.map { " opf:scheme=\"\($0)\"" } ?? ""
            metadataXML += "<dc:identifier\(scheme)>\(isbn)</dc:identifier>\n"
        }
        if let extra = spec.extraIdentifier {
            metadataXML += "<dc:identifier>\(escapeXML(extra))</dc:identifier>\n"
        }
        if let language = spec.language {
            metadataXML += "<dc:language>\(language)</dc:language>\n"
        }
        if let publisher = spec.publisher {
            metadataXML += "<dc:publisher>\(escapeXML(publisher))</dc:publisher>\n"
        }
        if let date = spec.date {
            metadataXML += "<dc:date>\(date)</dc:date>\n"
        }
        if let description = spec.description {
            metadataXML += "<dc:description>\(escapeXML(description))</dc:description>\n"
        }
        if let series = spec.series {
            metadataXML += "<meta name=\"calibre:series\" content=\"\(escapeXML(series))\"/>\n"
        }
        if let index = spec.seriesIndex {
            metadataXML += "<meta name=\"calibre:series_index\" content=\"\(index)\"/>\n"
        }

        var manifestXML = """
            <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
            """
        if spec.coverData != nil {
            let realName = spec.percentEncodedCoverHref ? "cover image.jpg" : "cover.jpg"
            let href = spec.percentEncodedCoverHref ? "cover%20image.jpg" : "cover.jpg"
            let properties = spec.coverStyle == "properties" ? " properties=\"cover-image\"" : ""
            manifestXML += "\n<item id=\"cover-img\" href=\"\(href)\" media-type=\"image/jpeg\"\(properties)/>"
            if spec.coverStyle == "meta" {
                metadataXML += "<meta name=\"cover\" content=\"cover-img\"/>\n"
            }
            try addEntry(archive, "OEBPS/\(realName)", spec.coverData!)
        }

        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
              \(metadataXML)
              </metadata>
              <manifest>
              \(manifestXML)
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        try addEntry(archive, "OEBPS/content.opf", Data(opf.utf8))
        try addEntry(archive, "OEBPS/text.xhtml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Fixture.</p></body></html>
            """.utf8))
    }

    /// A valid zip archive that is not an epub (no META-INF/container.xml).
    public static func makeBareZip(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        try addEntry(archive, "readme.txt", Data("not an epub".utf8))
    }

    // MARK: - PDF

    /// Creates a one-page PDF with an Info dictionary. The creation date is
    /// stamped by CoreGraphics (current date).
    public static func makePdf(
        at url: URL, title: String? = nil, author: String? = nil, subject: String? = nil
    ) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 450)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let author { info[kCGPDFContextAuthor] = author }
        if let subject { info[kCGPDFContextSubject] = subject }

        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary)
        else { throw FixtureError.pdfContextFailed }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 40, y: 60, width: 220, height: 330))
        context.endPDFPage()
        context.closePDF()
    }

    // MARK: - MOBI / AZW3

    public struct MobiSpec {
        public var headerTitle: String
        public var updatedTitle: String?     // EXTH 503
        public var author: String?
        public var publisher: String?
        public var description: String?
        public var isbn: String?
        public var publishDate: String?
        public var language: String?
        public var coverData: Data?
        /// Corrupts one EXTH record with length < 8 (parser must stop cleanly).
        public var malformedEXTHRecord: Bool

        public init(
            headerTitle: String, updatedTitle: String? = nil, author: String? = nil,
            publisher: String? = nil, description: String? = nil, isbn: String? = nil,
            publishDate: String? = nil, language: String? = nil, coverData: Data? = nil,
            malformedEXTHRecord: Bool = false
        ) {
            self.headerTitle = headerTitle
            self.updatedTitle = updatedTitle
            self.author = author
            self.publisher = publisher
            self.description = description
            self.isbn = isbn
            self.publishDate = publishDate
            self.language = language
            self.coverData = coverData
            self.malformedEXTHRecord = malformedEXTHRecord
        }
    }

    public static func makeMobi(at url: URL, spec: MobiSpec) throws {
        // --- EXTH block ---
        var exthRecords = Data()
        var exthCount: UInt32 = 0
        func exth(_ type: UInt32, _ payload: Data) {
            exthRecords.append(be32(type))
            exthRecords.append(be32(UInt32(8 + payload.count)))
            exthRecords.append(payload)
            exthCount += 1
        }
        if let author = spec.author { exth(100, Data(author.utf8)) }
        if let publisher = spec.publisher { exth(101, Data(publisher.utf8)) }
        if let description = spec.description { exth(103, Data(description.utf8)) }
        if let isbn = spec.isbn { exth(104, Data(isbn.utf8)) }
        if let date = spec.publishDate { exth(106, Data(date.utf8)) }
        if spec.coverData != nil { exth(201, be32(0)) } // cover = first image record
        if let title = spec.updatedTitle { exth(503, Data(title.utf8)) }
        if let language = spec.language { exth(524, Data(language.utf8)) }
        if spec.malformedEXTHRecord {
            // Type + bogus length (4 < 8): a well-behaved parser stops here.
            exthRecords.append(be32(999))
            exthRecords.append(be32(4))
            exthCount += 1
        }

        var exth = Data()
        exth.append(Data("EXTH".utf8))
        exth.append(be32(UInt32(12 + exthRecords.count)))
        exth.append(be32(exthCount))
        exth.append(exthRecords)
        while exth.count % 4 != 0 { exth.append(0) }

        // --- Record 0: PalmDOC header + MOBI header + EXTH + full name ---
        let mobiHeaderLength: UInt32 = 232
        let textBytes = Data("Fixture text content.".utf8)
        let nameBytes = Data(spec.headerTitle.utf8)

        var record0 = Data()
        // PalmDOC header (16 bytes).
        record0.append(be16(1))                        // compression: none
        record0.append(be16(0))
        record0.append(be32(UInt32(textBytes.count)))  // text length
        record0.append(be16(1))                        // record count
        record0.append(be16(4096))                     // record size
        record0.append(be32(0))                        // encryption + unknown

        // MOBI header (mobiHeaderLength bytes from here).
        let mobiStart = record0.count                  // == 16
        var mobi = Data(count: Int(mobiHeaderLength))
        mobi.replaceSubrange(0..<4, with: Data("MOBI".utf8))
        mobi.replaceSubrange(4..<8, with: be32(mobiHeaderLength))
        mobi.replaceSubrange(8..<12, with: be32(2))        // mobi type: book
        mobi.replaceSubrange(12..<16, with: be32(65001))   // UTF-8
        let fullNameOffset = UInt32(mobiStart) + mobiHeaderLength + UInt32(exth.count)
        mobi.replaceSubrange(0x54..<0x58, with: be32(fullNameOffset))
        mobi.replaceSubrange(0x58..<0x5C, with: be32(UInt32(nameBytes.count)))
        let firstImageIndex: UInt32 = spec.coverData != nil ? 2 : 0xFFFF_FFFF
        mobi.replaceSubrange(0x6C..<0x70, with: be32(firstImageIndex))
        mobi.replaceSubrange(0x80..<0x84, with: be32(0x40)) // EXTH present
        record0.append(mobi)
        record0.append(exth)
        record0.append(nameBytes)
        record0.append(Data([0, 0]))

        // --- Records ---
        var records: [Data] = [record0, textBytes]
        if let cover = spec.coverData {
            records.append(cover)
        }

        // --- PalmDB container ---
        var palm = Data(count: 32)                     // database name
        palm.replaceSubrange(0..<min(31, url.lastPathComponent.utf8.count),
                             with: Data(url.lastPathComponent.utf8.prefix(31)))
        palm.append(be16(0))                           // attributes
        palm.append(be16(0))                           // version
        palm.append(be32(0)); palm.append(be32(0)); palm.append(be32(0)) // dates
        palm.append(be32(0))                           // modification number
        palm.append(be32(0))                           // app info
        palm.append(be32(0))                           // sort info
        palm.append(Data("BOOK".utf8))                 // type
        palm.append(Data("MOBI".utf8))                 // creator
        palm.append(be32(0))                           // unique id seed
        palm.append(be32(0))                           // next record list
        palm.append(be16(UInt16(records.count)))       // record count (offset 76)

        let recordListSize = records.count * 8 + 2     // + 2 pad bytes
        var offset = palm.count + recordListSize
        for (index, record) in records.enumerated() {
            palm.append(be32(UInt32(offset)))
            palm.append(be32(UInt32(index)))           // attributes + unique id
            offset += record.count
        }
        palm.append(Data([0, 0]))                      // traditional pad
        for record in records {
            palm.append(record)
        }
        try palm.write(to: url)
    }

    // MARK: - Images

    /// A small valid JPEG (solid color), decodable by ImageIO.
    public static func tinyJPEG(width: Int = 24, height: Int = 32) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: - Demo library (librarian-seed)

    /// Seeds a folder with a mixed demo library covering the interesting
    /// cases: multi-format groups, Persian titles, series, corrupt files.
    public static func seedDemoLibrary(into root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let sf = root.appendingPathComponent("SciFi", isDirectory: true)
        let classics = root.appendingPathComponent("Classics", isDirectory: true)
        try fm.createDirectory(at: sf, withIntermediateDirectories: true)
        try fm.createDirectory(at: classics, withIntermediateDirectories: true)

        // The Dune acceptance trio (§6.2): epub with metadata, pdf, noisy mobi.
        try makeEpub(at: sf.appendingPathComponent("dune.epub"), spec: EpubSpec(
            title: "Dune", authors: ["Frank Herbert"], isbn: "9780441172719",
            language: "en", publisher: "Ace", date: "1990-09-01",
            description: "Melange, sandworms, and the spice must flow.",
            series: "Dune Chronicles", seriesIndex: 1, coverData: tinyJPEG()))
        try makePdf(at: sf.appendingPathComponent("Dune - Frank Herbert.pdf"),
                    title: "Dune", author: "Frank Herbert")
        try makeMobi(at: sf.appendingPathComponent("dune_v2.mobi"), spec: MobiSpec(
            headerTitle: "Dune"))

        // A series in epub.
        for (index, title) in ["Foundation", "Foundation and Empire", "Second Foundation"].enumerated() {
            try makeEpub(at: sf.appendingPathComponent("\(title).epub"), spec: EpubSpec(
                title: title, authors: ["Isaac Asimov"], isbn: "97805532934\(60 + index)",
                language: "en", publisher: "Bantam", date: "1951-06-01",
                series: "Foundation", seriesIndex: Double(index + 1), coverData: tinyJPEG()))
        }

        // Persian title (NFR-4: RTL/Unicode first-class).
        try makeEpub(at: classics.appendingPathComponent("بوف کور.epub"), spec: EpubSpec(
            title: "بوف کور", authors: ["صادق هدایت"], language: "fa",
            publisher: "امیرکبیر", date: "1937-01-01", coverData: tinyJPEG()))

        // Same-format duplicates in one logical book (duplicate-format filter).
        try makeEpub(at: classics.appendingPathComponent("1984.epub"), spec: EpubSpec(
            title: "1984", authors: ["George Orwell"], isbn: "9780451524935",
            language: "en", coverData: tinyJPEG()))
        try makeEpub(at: classics.appendingPathComponent("1984 (retail).epub"), spec: EpubSpec(
            title: "1984", authors: ["George Orwell"], isbn: "9780451524935",
            language: "en"))

        // Same title, different authors (§9): must stay separate.
        try makeEpub(at: classics.appendingPathComponent("Rework - Jason Fried.epub"),
                     spec: EpubSpec(title: "Rework", authors: ["Jason Fried"]))
        try makeEpub(at: classics.appendingPathComponent("Rework - Unrelated Author.epub"),
                     spec: EpubSpec(title: "Rework", authors: ["Unrelated Author"]))

        // Metadata-free files that only group by filename.
        try makePdf(at: classics.appendingPathComponent("Moby Dick.pdf"))
        try makeMobi(at: classics.appendingPathComponent("Moby.Dick.v2.mobi"),
                     spec: MobiSpec(headerTitle: "Moby Dick"))

        // Recognized-but-unparsed formats.
        try Data("plain text book".utf8)
            .write(to: classics.appendingPathComponent("Old Notes - Anonymous.txt"))

        // A corrupt epub (§9: non-fatal parse failure).
        try Data("this is not a zip archive".utf8)
            .write(to: classics.appendingPathComponent("corrupt-book.epub"))
    }

    // MARK: - Helpers

    public enum FixtureError: Error {
        case pdfContextFailed
    }

    private static func addEntry(_ archive: Archive, _ name: String, _ data: Data) throws {
        try archive.addEntry(
            with: name, type: .file, uncompressedSize: Int64(data.count)
        ) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }

    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func be16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func be32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
