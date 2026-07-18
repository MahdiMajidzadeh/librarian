import Foundation
import BookShelfKit

extension Fixtures {
    struct MobiSpec {
        var fullName = "Dune"
        var exthTitle: String? = nil          // EXTH 503 overrides fullName
        var authors: [String] = ["Frank Herbert"]
        var publisher: String? = "Ace"
        var isbn: String? = "9780441172719"
        var publishDate: String? = "1965-08-01"
        var subjects: [String] = ["Science Fiction"]
        var includeCover = true
    }

    /// Builds a structurally valid MOBI file byte-by-byte.
    static func makeMobi(at url: URL, spec: MobiSpec = MobiSpec()) throws {
        func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] {
            [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }

        // --- EXTH records ---
        var exthRecords: [[UInt8]] = []
        func addEXTH(_ type: Int, _ payload: [UInt8]) {
            exthRecords.append(u32(type) + u32(payload.count + 8) + payload)
        }
        for author in spec.authors { addEXTH(100, Array(author.utf8)) }
        if let p = spec.publisher { addEXTH(101, Array(p.utf8)) }
        if let i = spec.isbn { addEXTH(104, Array(i.utf8)) }
        for s in spec.subjects { addEXTH(105, Array(s.utf8)) }
        if let d = spec.publishDate { addEXTH(106, Array(d.utf8)) }
        if let t = spec.exthTitle { addEXTH(503, Array(t.utf8)) }
        if spec.includeCover { addEXTH(201, u32(0)) } // cover = firstImageIndex + 0

        let exthBody = exthRecords.flatMap { $0 }
        let exth: [UInt8] = Array("EXTH".utf8) + u32(exthBody.count + 12) + u32(exthRecords.count) + exthBody

        // --- Record 0: PalmDOC(16) + MOBI(232) + EXTH + full name ---
        let mobiHeaderLength = 232
        let fullNameBytes = Array(spec.fullName.utf8)
        let fullNameOffset = 16 + mobiHeaderLength + exth.count
        let firstImageIndex = 2

        var mobiHeader = [UInt8](repeating: 0, count: mobiHeaderLength)
        mobiHeader.replaceSubrange(0..<4, with: Array("MOBI".utf8))
        mobiHeader.replaceSubrange(4..<8, with: u32(mobiHeaderLength))
        mobiHeader.replaceSubrange(8..<12, with: u32(2))        // mobi type: book
        mobiHeader.replaceSubrange(12..<16, with: u32(65001))   // utf-8
        mobiHeader.replaceSubrange(68..<72, with: u32(fullNameOffset))
        mobiHeader.replaceSubrange(72..<76, with: u32(fullNameBytes.count))
        mobiHeader.replaceSubrange(92..<96, with: u32(spec.includeCover ? firstImageIndex : 0xFFFFFFFF))
        mobiHeader.replaceSubrange(112..<116, with: u32(0x40))  // EXTH present

        let text = Array("It was a dark and spicy night.".utf8)
        var palmdoc = [UInt8]()
        palmdoc += u16(1)                 // compression: none
        palmdoc += u16(0)
        palmdoc += u32(text.count)        // text length
        palmdoc += u16(1)                 // record count
        palmdoc += u16(4096)              // record size
        palmdoc += u32(0)                 // encryption + unknown

        let record0 = palmdoc + mobiHeader + exth + fullNameBytes
        let record1 = text
        let record2 = spec.includeCover ? [UInt8](jpegData()) : []

        let records = spec.includeCover ? [record0, record1, record2] : [record0, record1]

        // --- PalmDB header + record directory ---
        var header = [UInt8](repeating: 0, count: 78)
        let name = Array("BookShelfFixture".utf8)
        header.replaceSubrange(0..<name.count, with: name)
        header.replaceSubrange(60..<68, with: Array("BOOKMOBI".utf8))
        header.replaceSubrange(76..<78, with: u16(records.count))

        var directory = [UInt8]()
        var offset = 78 + records.count * 8
        for (i, record) in records.enumerated() {
            directory += u32(offset)
            directory += [0, 0, 0, UInt8(truncatingIfNeeded: 2 * i)]
            offset += record.count
        }

        let fileBytes = header + directory + records.flatMap { $0 }
        try Data(fileBytes).write(to: url)
    }
}

func mobiParserTests(_ runner: TestRunner) async {
    await runner.run("mobi: EXTH metadata extraction") {
        try await withTempDirectory { dir in
            let url = dir.appendingPathComponent("dune.mobi")
            try Fixtures.makeMobi(at: url)

            let meta = try MobiParser.parse(url: url)
            expectEqual(meta.title, "Dune")
            expectEqual(meta.authors, ["Frank Herbert"])
            expectEqual(meta.publisher, "Ace")
            expectEqual(meta.isbn, "9780441172719")
            expectEqual(meta.year, 1965)
            expectEqual(meta.subjects, ["Science Fiction"])
        }
    }

    await runner.run("mobi: EXTH 503 updated title overrides full name") {
        try await withTempDirectory { dir in
            var spec = Fixtures.MobiSpec()
            spec.fullName = "dune_v2_final_OCR"
            spec.exthTitle = "Dune"
            let url = dir.appendingPathComponent("dune2.mobi")
            try Fixtures.makeMobi(at: url, spec: spec)
            let meta = try MobiParser.parse(url: url)
            expectEqual(meta.title, "Dune")
        }
    }

    await runner.run("mobi: cover record extraction via EXTH 201") {
        try await withTempDirectory { dir in
            let url = dir.appendingPathComponent("cover.mobi")
            try Fixtures.makeMobi(at: url)
            let meta = try MobiParser.parse(url: url)
            guard let cover = expectNotNil(meta.coverData, "cover missing") else { return }
            expectEqual(cover.prefix(2), Data([0xFF, 0xD8]), "cover should be the JPEG record")
        }
    }

    await runner.run("mobi: no cover flag yields nil coverData") {
        try await withTempDirectory { dir in
            var spec = Fixtures.MobiSpec()
            spec.includeCover = false
            let url = dir.appendingPathComponent("nocover.mobi")
            try Fixtures.makeMobi(at: url, spec: spec)
            let meta = try MobiParser.parse(url: url)
            expectNil(meta.coverData)
        }
    }

    await runner.run("mobi: unicode author/title survive UTF-8 EXTH") {
        try await withTempDirectory { dir in
            var spec = Fixtures.MobiSpec()
            spec.fullName = "بوف کور"
            spec.authors = ["صادق هدایت"]
            spec.isbn = nil
            let url = dir.appendingPathComponent("fa.mobi")
            try Fixtures.makeMobi(at: url, spec: spec)
            let meta = try MobiParser.parse(url: url)
            expectEqual(meta.title, "بوف کور")
            expectEqual(meta.authors, ["صادق هدایت"])
        }
    }

    await runner.run("mobi: garbage and truncated files throw, never crash") {
        try await withTempDirectory { dir in
            let garbage = dir.appendingPathComponent("junk.mobi")
            try Data("BOOKMOBI but not really".utf8).write(to: garbage)
            expectThrows("garbage must throw") { _ = try MobiParser.parse(url: garbage) }

            // Valid file truncated halfway.
            let full = dir.appendingPathComponent("full.mobi")
            try Fixtures.makeMobi(at: full)
            let data = try Data(contentsOf: full)
            let truncated = dir.appendingPathComponent("half.mobi")
            try data.prefix(100).write(to: truncated)
            expectThrows("truncated must throw") { _ = try MobiParser.parse(url: truncated) }
        }
    }
}
