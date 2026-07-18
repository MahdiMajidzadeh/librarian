import Foundation

/// Parses MOBI / AZW3 (KF8) containers: PalmDB record directory → record 0
/// (PalmDOC + MOBI headers) → EXTH metadata records + cover image record.
/// Format reference: MobileRead wiki "MOBI" / "PDB" documentation.
public enum MobiParser {
    // EXTH record types.
    private enum EXTHType: Int {
        case author = 100
        case publisher = 101
        case description = 103
        case isbn = 104
        case subject = 105
        case publishDate = 106
        case coverOffset = 201
        case language = 524
        case updatedTitle = 503
    }

    public static func parse(url: URL) throws -> EmbeddedMetadata {
        let bytes: [UInt8]
        do {
            bytes = [UInt8](try Data(contentsOf: url))
        } catch {
            throw ParseError("unreadable file: \(error)")
        }
        let reader = BinaryReader(bytes)

        // PalmDB header: creator type "BOOK"/"MOBI" at 60...67.
        guard bytes.count > 78,
              let typeCreator = reader.ascii(60..<68),
              typeCreator == "BOOKMOBI" else {
            throw ParseError("not a MOBI/AZW3 (PalmDB type is not BOOKMOBI)")
        }
        guard let recordCount = reader.u16(76), recordCount > 0 else {
            throw ParseError("PalmDB has no records")
        }

        // Record directory: 8 bytes per entry, offset in the first 4.
        var offsets: [Int] = []
        for i in 0..<recordCount {
            guard let offset = reader.u32(78 + i * 8) else {
                throw ParseError("truncated record directory")
            }
            offsets.append(offset)
        }
        offsets.append(bytes.count)
        guard offsets.dropLast().allSatisfy({ $0 <= bytes.count }) else {
            throw ParseError("record offset beyond end of file")
        }

        func record(_ index: Int) -> ArraySlice<UInt8>? {
            guard index >= 0, index < recordCount, offsets[index] <= offsets[index + 1] else {
                return nil
            }
            return bytes[offsets[index]..<offsets[index + 1]]
        }

        guard let record0Slice = record(0) else {
            throw ParseError("missing record 0")
        }
        let record0 = BinaryReader(Array(record0Slice))

        // MOBI header follows the 16-byte PalmDOC header.
        let mobi = 16
        guard record0.ascii(mobi..<mobi + 4) == "MOBI",
              let headerLength = record0.u32(mobi + 4),
              let encodingCode = record0.u32(mobi + 12) else {
            throw ParseError("missing MOBI header in record 0")
        }
        let encoding: String.Encoding = encodingCode == 1252 ? .windowsCP1252 : .utf8

        var meta = EmbeddedMetadata()

        // Full book name (fallback title).
        if let nameOffset = record0.u32(mobi + 68),
           let nameLength = record0.u32(mobi + 72),
           let fullName = record0.string(nameOffset..<nameOffset + nameLength, encoding: encoding),
           !fullName.isEmpty {
            meta.title = fullName
        }

        let firstImageIndex = record0.u32(mobi + 92)
        var coverOffset: Int?

        // EXTH block, when flagged (bit 0x40 at MOBI header +112).
        if let exthFlags = record0.u32(mobi + 112), exthFlags & 0x40 != 0 {
            let exth = mobi + Int(headerLength)
            if record0.ascii(exth..<exth + 4) == "EXTH",
               let exthCount = record0.u32(exth + 8) {
                var cursor = exth + 12
                for _ in 0..<exthCount {
                    guard let type = record0.u32(cursor),
                          let length = record0.u32(cursor + 4),
                          length >= 8 else { break }
                    let dataRange = (cursor + 8)..<(cursor + length)
                    switch EXTHType(rawValue: type) {
                    case .author:
                        if let author = record0.string(dataRange, encoding: encoding) {
                            meta.authors.append(author)
                        }
                    case .publisher:
                        meta.publisher = record0.string(dataRange, encoding: encoding)
                    case .description:
                        meta.description = record0.string(dataRange, encoding: encoding)
                    case .isbn:
                        if let raw = record0.string(dataRange, encoding: encoding) {
                            meta.isbn = Normalizer.extractISBN(raw) ?? raw
                        }
                    case .subject:
                        if let subject = record0.string(dataRange, encoding: encoding) {
                            meta.subjects.append(subject)
                        }
                    case .publishDate:
                        if let date = record0.string(dataRange, encoding: encoding) {
                            meta.year = EmbeddedMetadata.year(fromDateString: date)
                        }
                    case .updatedTitle:
                        meta.title = record0.string(dataRange, encoding: encoding) ?? meta.title
                    case .language:
                        meta.language = record0.string(dataRange, encoding: encoding)
                    case .coverOffset:
                        coverOffset = record0.u32(cursor + 8)
                    case nil:
                        break
                    }
                    cursor += length
                }
            }
        }

        // Cover: record at firstImageIndex + EXTH 201 offset.
        if let firstImage = firstImageIndex, firstImage != 0xFFFFFFFF,
           let offset = coverOffset,
           let coverSlice = record(firstImage + offset) {
            let data = Data(coverSlice)
            // Sanity check: JPEG, PNG, or GIF magic.
            let magics: [[UInt8]] = [[0xFF, 0xD8], [0x89, 0x50], [0x47, 0x49]]
            if magics.contains(where: { data.starts(with: $0) }) {
                meta.coverData = data
            }
        }

        return meta
    }
}

/// Bounds-checked big-endian binary reads.
struct BinaryReader {
    private let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func u16(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    func u32(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    func ascii(_ range: Range<Int>) -> String? {
        string(range, encoding: .ascii)
    }

    func string(_ range: Range<Int>, encoding: String.Encoding) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, !range.isEmpty else {
            return nil
        }
        return String(bytes: bytes[range], encoding: encoding)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
