import Foundation
import CoreGraphics
import BookShelfKit

extension Fixtures {
    /// A one-page PDF with an Info dictionary, drawn via CoreGraphics.
    static func makePDF(at url: URL, title: String? = "Dune",
                        author: String? = "Frank Herbert",
                        subject: String? = "Spice and sand",
                        keywords: String? = "Science Fiction; Classics") throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 450)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let author { info[kCGPDFContextAuthor] = author }
        if let subject { info[kCGPDFContextSubject] = subject }
        if let keywords { info[kCGPDFContextKeywords] = keywords }

        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ParseError("could not create PDF context")
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
        context.endPDFPage()
        context.closePDF()
    }
}

func pdfParserTests(_ runner: TestRunner) async {
    await runner.run("pdf: info dictionary metadata extraction") {
        try await withTempDirectory { dir in
            let url = dir.appendingPathComponent("dune.pdf")
            try Fixtures.makePDF(at: url)

            let meta = try PdfParser.parse(url: url)
            expectEqual(meta.title, "Dune")
            expectEqual(meta.authors, ["Frank Herbert"])
            expectEqual(meta.description, "Spice and sand")
            expectEqual(meta.subjects, ["Science Fiction", "Classics"])
            expect((meta.year ?? 0) >= 2020, "auto creation date should yield a recent year")
        }
    }

    await runner.run("pdf: first page renders as cover jpeg") {
        try await withTempDirectory { dir in
            let url = dir.appendingPathComponent("cover.pdf")
            try Fixtures.makePDF(at: url)
            let meta = try PdfParser.parse(url: url)
            guard let data = expectNotNil(meta.coverData, "cover render missing") else { return }
            expect(data.count > 500, "rendered cover should be non-trivial JPEG")
            // JPEG magic bytes.
            expectEqual(data.prefix(2), Data([0xFF, 0xD8]))
        }
    }

    await runner.run("pdf: author splitting variants") {
        expectEqual(PdfParser.splitAuthors("A. Uthor; B. Writer"), ["A. Uthor", "B. Writer"])
        expectEqual(PdfParser.splitAuthors("Jane Doe and John Smith"), ["Jane Doe", "John Smith"])
        expectEqual(PdfParser.splitAuthors("Jane Doe & John Smith"), ["Jane Doe", "John Smith"])
        expectEqual(PdfParser.splitAuthors("Jane Doe, John Smith"), ["Jane Doe", "John Smith"])
        expectEqual(PdfParser.splitAuthors("Herbert, Frank"), ["Herbert, Frank"],
                    "Last, First must not split")
    }

    await runner.run("pdf: non-pdf throws ParseError") {
        try await withTempDirectory { dir in
            let url = dir.appendingPathComponent("fake.pdf")
            try Data("not a pdf at all".utf8).write(to: url)
            expectThrows("garbage must throw") {
                _ = try PdfParser.parse(url: url)
            }
        }
    }
}
