import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// Programmatic test fixtures — no binary files checked into the repo.
enum Fixtures {
    /// A tiny valid JPEG of the given size and gray level.
    static func jpegData(width: Int = 40, height: Int = 60, gray: CGFloat = 0.5) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    struct EpubSpec {
        var title: String? = "Dune"
        var authors: [String] = ["Frank Herbert"]
        var publisher: String? = "Chilton Books"
        var language: String? = "en"
        var isbn: String? = "9780441172719"
        var date: String? = "1965-08-01"
        var description: String? = "Melange is everything."
        var subjects: [String] = ["Science Fiction"]
        var includeCover = true
        var epub2StyleCover = false
    }

    /// Writes a minimal but structurally valid epub at `url`.
    static func makeEpub(at url: URL, spec: EpubSpec = EpubSpec()) throws {
        let archive = try Archive(url: url, accessMode: .create)

        func add(_ path: String, _ data: Data) throws {
            try archive.addEntry(
                with: path, type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<(Int(position) + size))
                })
        }

        try add("mimetype", Data("application/epub+zip".utf8))
        try add("META-INF/container.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8))

        var metadataXML = ""
        if let title = spec.title { metadataXML += "<dc:title>\(title)</dc:title>\n" }
        for author in spec.authors { metadataXML += "<dc:creator>\(author)</dc:creator>\n" }
        if let publisher = spec.publisher { metadataXML += "<dc:publisher>\(publisher)</dc:publisher>\n" }
        if let language = spec.language { metadataXML += "<dc:language>\(language)</dc:language>\n" }
        if let isbn = spec.isbn { metadataXML += "<dc:identifier>urn:isbn:\(isbn)</dc:identifier>\n" }
        if let date = spec.date { metadataXML += "<dc:date>\(date)</dc:date>\n" }
        if let description = spec.description { metadataXML += "<dc:description>\(description)</dc:description>\n" }
        for subject in spec.subjects { metadataXML += "<dc:subject>\(subject)</dc:subject>\n" }

        var manifestXML = #"<item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>"#
        if spec.includeCover {
            if spec.epub2StyleCover {
                metadataXML += #"<meta name="cover" content="cover-img"/>"# + "\n"
                manifestXML += "\n" + #"<item id="cover-img" href="images/cover.jpg" media-type="image/jpeg"/>"#
            } else {
                manifestXML += "\n" + #"<item id="cover-img" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#
            }
        }

        try add("OEBPS/content.opf", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0" unique-identifier="uid">
          <metadata>
        \(metadataXML)
          </metadata>
          <manifest>
        \(manifestXML)
          </manifest>
          <spine><itemref idref="text"/></spine>
        </package>
        """.utf8))

        try add("OEBPS/text.xhtml", Data("<html><body><p>…</p></body></html>".utf8))
        if spec.includeCover {
            try add("OEBPS/images/cover.jpg", jpegData())
        }
    }
}
