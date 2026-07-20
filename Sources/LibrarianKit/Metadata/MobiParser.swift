import Foundation

/// Parses MOBI / AZW3 (PalmDB "BOOKMOBI") embedded metadata: the EXTH header
/// records and the embedded cover record (§6.3 step 1).
///
/// Layout reference (mobileread wiki):
/// - PalmDB header: 78 bytes; record count at offset 76 (u16 BE), then
///   8-byte record-info entries (offset u32, attributes+uniqueID u32).
/// - Record 0: PalmDOC header (16 bytes), then MOBI header ("MOBI" magic).
///   Within the MOBI header: +0x04 header length, +0x0C text encoding,
///   +0x54 full-name offset (from record-0 start), +0x58 full-name length,
///   +0x6C first image record index, +0x80 EXTH flags (bit 0x40 = present).
/// - EXTH header directly follows the MOBI header: "EXTH", length, count,
///   then records of (type u32, length u32, payload).
public enum MobiParser {
    public enum ParseError: Error, LocalizedError, Equatable {
        case notPalmDatabase
        case truncated

        public var errorDescription: String? {
            switch self {
            case .notPalmDatabase: return "Not a MOBI/AZW3 (BOOKMOBI) file"
            case .truncated: return "Truncated or corrupt MOBI file"
            }
        }
    }

    // EXTH record types.
    private enum EXTHType: UInt32 {
        case author = 100
        case publisher = 101
        case description = 103
        case isbn = 104
        case publishDate = 106
        case coverOffset = 201
        case language = 524
        case updatedTitle = 503
    }

    public static func parse(url: URL) throws -> BookMetadata {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> BookMetadata {
        guard data.count > 78 + 8,
              string(in: data, at: 60, length: 8, encoding: .ascii) == "BOOKMOBI"
        else { throw ParseError.notPalmDatabase }

        let recordCount = Int(u16(data, 76))
        guard recordCount > 0, data.count >= 78 + recordCount * 8 else {
            throw ParseError.truncated
        }
        var recordOffsets: [Int] = []
        recordOffsets.reserveCapacity(recordCount + 1)
        for i in 0..<recordCount {
            recordOffsets.append(Int(u32(data, 78 + i * 8)))
        }
        recordOffsets.append(data.count)

        func record(_ index: Int) -> Data? {
            guard index >= 0, index < recordCount,
                  recordOffsets[index] <= recordOffsets[index + 1],
                  recordOffsets[index + 1] <= data.count
            else { return nil }
            return data.subdata(in: recordOffsets[index]..<recordOffsets[index + 1])
        }

        guard let record0 = record(0), record0.count >= 16 + 8,
              string(in: record0, at: 16, length: 4, encoding: .ascii) == "MOBI"
        else { throw ParseError.notPalmDatabase }

        let mobiStart = 16
        let mobiHeaderLength = Int(u32(record0, mobiStart + 0x04))
        let textEncoding = u32(record0, mobiStart + 0x0C)
        let encoding: String.Encoding = textEncoding == 65001 ? .utf8 : .windowsCP1252

        var metadata = BookMetadata()

        // Full title from the name offset/length fields.
        if record0.count >= mobiStart + 0x5C {
            let nameOffset = Int(u32(record0, mobiStart + 0x54))
            let nameLength = Int(u32(record0, mobiStart + 0x58))
            if nameLength > 0, nameOffset + nameLength <= record0.count,
               let title = string(in: record0, at: nameOffset, length: nameLength, encoding: encoding) {
                metadata.title = title
            }
        }

        var firstImageIndex: Int?
        if record0.count >= mobiStart + 0x70 {
            let raw = u32(record0, mobiStart + 0x6C)
            if raw != 0xFFFF_FFFF { firstImageIndex = Int(raw) }
        }

        // EXTH header, when flagged.
        var coverOffset: Int?
        let exthFlagsOffset = mobiStart + 0x80
        if record0.count >= exthFlagsOffset + 4,
           u32(record0, exthFlagsOffset) & 0x40 != 0 {
            let exthStart = mobiStart + mobiHeaderLength
            if record0.count >= exthStart + 12,
               string(in: record0, at: exthStart, length: 4, encoding: .ascii) == "EXTH" {
                let count = Int(u32(record0, exthStart + 8))
                var cursor = exthStart + 12
                for _ in 0..<count {
                    guard record0.count >= cursor + 8 else { break }
                    let type = u32(record0, cursor)
                    let length = Int(u32(record0, cursor + 4))
                    // Malformed records (length < 8 or overrun) end the walk.
                    guard length >= 8, cursor + length <= record0.count else { break }
                    let payload = record0.subdata(in: (cursor + 8)..<(cursor + length))
                    apply(type: type, payload: payload, encoding: encoding,
                          to: &metadata, coverOffset: &coverOffset)
                    cursor += length
                }
            }
        }

        if let firstImageIndex, let coverOffset,
           let cover = record(firstImageIndex + coverOffset),
           looksLikeImage(cover) {
            metadata.coverData = cover
        }
        return metadata
    }

    private static func apply(
        type: UInt32, payload: Data, encoding: String.Encoding,
        to metadata: inout BookMetadata, coverOffset: inout Int?
    ) {
        func text() -> String? {
            guard let s = String(data: payload, encoding: encoding) else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        switch EXTHType(rawValue: type) {
        case .author:
            if let author = text() { metadata.authors.append(author) }
        case .publisher:
            if metadata.publisher == nil { metadata.publisher = text() }
        case .description:
            if metadata.description == nil { metadata.description = text() }
        case .isbn:
            if let isbn = text() { ISBN.assign(isbn, to: &metadata) }
        case .publishDate:
            if metadata.year == nil { metadata.year = parseYear(text()) }
        case .coverOffset:
            if payload.count == 4 {
                let value = payload.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                if value != 0xFFFF_FFFF { coverOffset = Int(value) }
            }
        case .language:
            if metadata.language == nil { metadata.language = text() }
        case .updatedTitle:
            if let title = text() { metadata.title = title }
        case nil:
            break
        }
    }

    private static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count > 4 else { return false }
        let jpeg: [UInt8] = [0xFF, 0xD8]
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let gif: [UInt8] = [0x47, 0x49, 0x46]
        let head = [UInt8](data.prefix(4))
        return head.starts(with: jpeg) || head.starts(with: png) || head.starts(with: gif)
    }

    // MARK: - Big-endian readers (bounds-checked)

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return data.subdata(in: offset..<offset + 2).withUnsafeBytes {
            $0.load(as: UInt16.self).bigEndian
        }
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.subdata(in: offset..<offset + 4).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
    }

    private static func string(
        in data: Data, at offset: Int, length: Int, encoding: String.Encoding
    ) -> String? {
        guard offset >= 0, length > 0, offset + length <= data.count else { return nil }
        return String(data: data.subdata(in: offset..<offset + length), encoding: encoding)
    }
}
