import Foundation
import ZIPFoundation

/// Parses EPUB (2 & 3) embedded metadata and cover (§6.3 step 1):
/// META-INF/container.xml → OPF `dc:*` fields, calibre series meta,
/// cover via `<meta name="cover">` or `properties="cover-image"`.
public enum EpubParser {
    public enum ParseError: Error, LocalizedError, Equatable {
        case notAZipArchive
        case missingContainer
        case missingOPF(String)

        public var errorDescription: String? {
            switch self {
            case .notAZipArchive: return "Not a valid EPUB (zip) archive"
            case .missingContainer: return "META-INF/container.xml not found"
            case .missingOPF(let path): return "OPF package document not found: \(path)"
            }
        }
    }

    public static func parse(url: URL) throws -> BookMetadata {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ParseError.notAZipArchive
        }

        guard let containerData = try? extract(archive, path: "META-INF/container.xml") else {
            throw ParseError.missingContainer
        }
        let opfPath = try containerOPFPath(containerData)
        guard let opfData = try? extract(archive, path: opfPath) else {
            throw ParseError.missingOPF(opfPath)
        }

        let opf = OPFDocument(data: opfData)
        var metadata = opf.metadata

        // Resolve the cover image href relative to the OPF's directory.
        if let coverHref = opf.coverHref {
            let opfDir = (opfPath as NSString).deletingLastPathComponent
            // Hrefs may be percent-encoded ("cover%20image.jpg").
            let decoded = coverHref.removingPercentEncoding ?? coverHref
            let candidates = [
                opfDir.isEmpty ? decoded : "\(opfDir)/\(decoded)",
                decoded,
            ]
            for candidate in candidates {
                let normalized = normalizePath(candidate)
                if let data = try? extract(archive, path: normalized) {
                    metadata.coverData = data
                    break
                }
            }
        }
        return metadata
    }

    // MARK: - Zip helpers

    private static func extract(_ archive: Archive, path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw ParseError.missingContainer
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    /// Collapses "a/b/../c" and "./c" segments.
    private static func normalizePath(_ path: String) -> String {
        var stack: [String] = []
        for segment in path.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": _ = stack.popLast()
            default: stack.append(String(segment))
            }
        }
        return stack.joined(separator: "/")
    }

    // MARK: - container.xml

    static func containerOPFPath(_ data: Data) throws -> String {
        let parser = ContainerParser()
        guard let path = parser.parse(data) else { throw ParseError.missingContainer }
        return path
    }

    private final class ContainerParser: NSObject, XMLParserDelegate {
        private var fullPath: String?

        func parse(_ data: Data) -> String? {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
            return fullPath
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            if elementName == "rootfile", fullPath == nil,
               let path = attributeDict["full-path"] {
                fullPath = path
            }
        }
    }
}

/// Parses the OPF package document: Dublin Core metadata, calibre series
/// meta tags, and the manifest to locate the cover image.
final class OPFDocument: NSObject, XMLParserDelegate {
    private(set) var metadata = BookMetadata()
    private(set) var coverHref: String?

    // Parsing state.
    private var currentElement = ""
    private var currentText = ""
    private var currentIdentifierScheme: String?
    private var coverItemId: String?              // from <meta name="cover" content="…">
    private var manifestItems: [String: (href: String, mediaType: String, properties: String)] = [:]

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        resolveCover()
    }

    private func resolveCover() {
        // EPUB 3: manifest item with properties="cover-image".
        if let item = manifestItems.values.first(where: { $0.properties.contains("cover-image") }) {
            coverHref = item.href
            return
        }
        // EPUB 2: <meta name="cover" content="item-id">.
        if let id = coverItemId, let item = manifestItems[id] {
            coverHref = item.href
            return
        }
        // Fallback: a manifest image whose id or href mentions "cover".
        if let item = manifestItems.first(where: { key, value in
            value.mediaType.hasPrefix("image/")
                && (key.lowercased().contains("cover") || value.href.lowercased().contains("cover"))
        }) {
            coverHref = item.value.href
        }
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        currentElement = elementName
        currentText = ""

        switch elementName.lowercased() {
        case "dc:identifier":
            currentIdentifierScheme = attributeDict["opf:scheme"]?.lowercased()
                ?? attributeDict["scheme"]?.lowercased()
        case "meta":
            let name = attributeDict["name"] ?? ""
            let content = attributeDict["content"] ?? ""
            switch name {
            case "cover":
                coverItemId = content
            case "calibre:series":
                metadata.series = content
            case "calibre:series_index":
                metadata.seriesIndex = Double(content)
            default:
                break
            }
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifestItems[id] = (
                    href: href,
                    mediaType: attributeDict["media-type"] ?? "",
                    properties: attributeDict["properties"] ?? ""
                )
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { currentText = "" }
        guard !text.isEmpty else { return }

        switch elementName.lowercased() {
        case "dc:title":
            if metadata.title == nil { metadata.title = text }
        case "dc:creator":
            metadata.authors.append(text)
        case "dc:language":
            if metadata.language == nil { metadata.language = text }
        case "dc:publisher":
            if metadata.publisher == nil { metadata.publisher = text }
        case "dc:date":
            if metadata.year == nil { metadata.year = parseYear(text) }
        case "dc:description":
            if metadata.description == nil { metadata.description = text }
        case "dc:identifier":
            if currentIdentifierScheme == "isbn" || text.lowercased().contains("isbn")
                || ISBN.normalize(text) != nil && looksLikeISBN(text) {
                ISBN.assign(text, to: &metadata)
            }
            currentIdentifierScheme = nil
        default:
            break
        }
    }

    /// Guards against UUID identifiers being misread as ISBNs: require the
    /// digit density of an ISBN, not a UUID with stray digits.
    private func looksLikeISBN(_ text: String) -> Bool {
        if text.lowercased().contains("uuid") || text.contains("-") && text.count > 20 {
            return false
        }
        let digits = text.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        return digits.count == 10 || digits.count == 13
    }
}
