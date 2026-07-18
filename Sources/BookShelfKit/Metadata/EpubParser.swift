import Foundation
import ZIPFoundation

/// Reads epub metadata: `META-INF/container.xml` → OPF package document →
/// Dublin Core fields + cover image (epub3 `cover-image` property, with the
/// epub2 `<meta name="cover">` fallback).
public enum EpubParser {
    public static func parse(url: URL) throws -> EmbeddedMetadata {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ParseError("not a readable zip container: \(error)")
        }

        guard let containerData = try? data(from: archive, path: "META-INF/container.xml") else {
            throw ParseError("missing META-INF/container.xml")
        }
        guard let opfPath = ContainerXMLParser.rootFilePath(containerData) else {
            throw ParseError("container.xml has no rootfile entry")
        }
        guard let opfData = try? data(from: archive, path: opfPath) else {
            throw ParseError("missing OPF package document at \(opfPath)")
        }

        let opf = OPFParser()
        guard opf.parse(opfData) else {
            throw ParseError("malformed OPF XML")
        }

        var meta = EmbeddedMetadata()
        meta.title = opf.title
        meta.authors = opf.creators
        meta.publisher = opf.publisher
        meta.language = opf.language
        meta.description = opf.synopsis
        meta.subjects = opf.subjects
        if let date = opf.date {
            meta.year = EmbeddedMetadata.year(fromDateString: date)
        }
        meta.isbn = opf.identifiers.compactMap(Normalizer.extractISBN).first

        if let coverHref = opf.coverHref {
            let opfDir = (opfPath as NSString).deletingLastPathComponent
            let coverPath = opfDir.isEmpty
                ? coverHref
                : (opfDir as NSString).appendingPathComponent(coverHref)
            meta.coverData = try? data(from: archive, path: normalize(zipPath: coverPath))
        }
        return meta
    }

    private static func data(from archive: Archive, path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw ParseError("zip entry not found: \(path)")
        }
        var collected = Data()
        _ = try archive.extract(entry) { chunk in
            collected.append(chunk)
        }
        return collected
    }

    /// Resolves "OEBPS/../cover.jpg" style relative components.
    private static func normalize(zipPath: String) -> String {
        var stack: [String] = []
        for component in zipPath.split(separator: "/") {
            if component == ".." {
                _ = stack.popLast()
            } else if component != "." {
                stack.append(String(component))
            }
        }
        return stack.joined(separator: "/")
    }
}

// MARK: - container.xml

private enum ContainerXMLParser {
    static func rootFilePath(_ data: Data) -> String? {
        final class Delegate: NSObject, XMLParserDelegate {
            var path: String?
            func parser(_ parser: XMLParser, didStartElement name: String,
                        namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String]) {
                if name == "rootfile", path == nil,
                   let fullPath = attributes["full-path"] {
                    path = fullPath
                }
            }
        }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.path
    }
}

// MARK: - OPF package document

final class OPFParser: NSObject, XMLParserDelegate {
    private(set) var title: String?
    private(set) var creators: [String] = []
    private(set) var publisher: String?
    private(set) var language: String?
    private(set) var date: String?
    private(set) var synopsis: String?
    private(set) var subjects: [String] = []
    private(set) var identifiers: [String] = []

    /// href of the cover image, relative to the OPF file.
    var coverHref: String? {
        // epub3: manifest item with properties containing "cover-image".
        if let item = manifestItems.first(where: {
            ($0.properties ?? "").split(separator: " ").contains("cover-image")
        }) {
            return item.href
        }
        // epub2: <meta name="cover" content="item-id"/>.
        if let coverId = epub2CoverId,
           let item = manifestItems.first(where: { $0.id == coverId }) {
            return item.href
        }
        return nil
    }

    struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String?
        let properties: String?
    }

    private var manifestItems: [ManifestItem] = []
    private var epub2CoverId: String?
    private var currentElement = ""
    private var currentText = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        currentElement = name
        currentText = ""
        switch name {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifestItems.append(ManifestItem(
                    id: id, href: href,
                    mediaType: attributes["media-type"],
                    properties: attributes["properties"]))
            }
        case "meta":
            if attributes["name"] == "cover", let content = attributes["content"] {
                epub2CoverId = content
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch name {
        case "title" where title == nil:
            title = text
        case "creator":
            creators.append(text)
        case "publisher" where publisher == nil:
            publisher = text
        case "language" where language == nil:
            language = text
        case "date" where date == nil:
            date = text
        case "description" where synopsis == nil:
            synopsis = text
        case "subject":
            subjects.append(text)
        case "identifier":
            identifiers.append(text)
        default:
            break
        }
        currentText = ""
    }
}
