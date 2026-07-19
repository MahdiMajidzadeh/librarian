import Foundation
import BookShelfKit

/// Metadata infrastructure shared by all parsers: EmbeddedMetadata helpers,
/// the MetadataExtractor format dispatch, TagSanitizer limits, and CoverCache
/// maintenance. Per-format parsing lives in Epub/Pdf/MobiParserTests.
func metadataTests(_ runner: TestRunner) async {
    await runner.run("embedded metadata: year parsed from date string variants") {
        expectEqual(EmbeddedMetadata.year(fromDateString: "1965"), 1965)
        expectEqual(EmbeddedMetadata.year(fromDateString: "1965-08-01"), 1965)
        expectEqual(EmbeddedMetadata.year(fromDateString: "August 1965"), 1965)
        expectNil(EmbeddedMetadata.year(fromDateString: "12"), "two digits are not a year")
        expectNil(EmbeddedMetadata.year(fromDateString: ""), "empty string")
        expectNil(EmbeddedMetadata.year(fromDateString: "no digits here"))
        expectNil(EmbeddedMetadata.year(fromDateString: "2500"), "outside the plausible range")
    }

    await runner.run("embedded metadata: isEmpty and populatedFields track every field") {
        let empty = EmbeddedMetadata()
        expect(empty.isEmpty, "default metadata must be empty")
        expectEqual(empty.populatedFields, [])

        var partial = EmbeddedMetadata()
        partial.title = "Dune"
        partial.authors = ["Frank Herbert"]
        partial.coverData = Data([0xFF])
        expect(!partial.isEmpty)
        expect(partial.populatedFields.contains("title"), "title should be listed")
        expect(partial.populatedFields.contains("authors"), "authors should be listed")
        expect(partial.populatedFields.contains("cover"), "cover should be listed")
        expect(!partial.populatedFields.contains("publisher"), "unset fields stay out")
    }

    await runner.run("extractor dispatch: nil for non-embedded formats, failure for corrupt file") {
        try await withTempDirectory { dir in
            let comic = dir.appendingPathComponent("comic.cbz")
            try Data("zipish".utf8).write(to: comic)
            expectNil(MetadataExtractor.extract(url: comic, format: .cbz),
                      "cbz has no embedded-metadata parser")
            let text = dir.appendingPathComponent("notes.txt")
            try Data("plain".utf8).write(to: text)
            expectNil(MetadataExtractor.extract(url: text, format: .txt))

            let corrupt = dir.appendingPathComponent("broken.epub")
            try Data("this is not a zip".utf8).write(to: corrupt)
            switch MetadataExtractor.extract(url: corrupt, format: .epub) {
            case .failure:
                break // expected: dispatched to EpubParser, error captured
            case .success, nil:
                expect(false, "corrupt epub must yield .failure, not nil or success")
            }
        }
    }

    await runner.run("embedded metadata: junk filename and isbn titles detected, real titles kept") {
        // Filename-shaped, ISBN-shaped, and tool-artifact titles are junk.
        expect(EmbeddedMetadata.isJunkTitle("0071501126.pdf"), "filename with extension")
        expect(EmbeddedMetadata.isJunkTitle("chapter_final.DOCX"), "extension check is case-insensitive")
        expect(EmbeddedMetadata.isJunkTitle("0071501126"), "bare ISBN-10")
        expect(EmbeddedMetadata.isJunkTitle("978-0-07-150112-6"), "hyphenated ISBN-13")
        expect(EmbeddedMetadata.isJunkTitle("Microsoft Word - thesis v3"), "authoring-tool artifact")
        expect(EmbeddedMetadata.isJunkTitle("untitled"), "placeholder text")
        expect(EmbeddedMetadata.isJunkTitle("   "), "whitespace only")
        expect(EmbeddedMetadata.isJunkTitle("---"), "punctuation only")

        // Real titles — including short numeric and non-Latin ones — pass.
        expect(!EmbeddedMetadata.isJunkTitle("Dune"))
        expect(!EmbeddedMetadata.isJunkTitle("1984"), "short numeric titles are real")
        expect(!EmbeddedMetadata.isJunkTitle("Catch-22"))
        expect(!EmbeddedMetadata.isJunkTitle("C++ Primer"))
        expect(!EmbeddedMetadata.isJunkTitle("دنیای سوفی"), "Persian titles are letters too")
        expect(!EmbeddedMetadata.isJunkTitle("Fahrenheit 451"))
    }

    await runner.run("extractor: junk pdf title dropped, isbn salvaged from it") {
        try await withTempDirectory { dir in
            let url = dir.appendingPathComponent("What_Customers_Want.pdf")
            try Fixtures.makePDF(at: url, title: "0071501126.pdf", author: "Anthony W. Ulwick")
            guard case .success(let meta)? = MetadataExtractor.extract(url: url, format: .pdf) else {
                expect(false, "fixture PDF must parse"); return
            }
            expectNil(meta.title, "junk title must not survive extraction")
            expectEqual(meta.isbn, "0071501126", "ISBN inside the junk title is salvaged")
            expectEqual(meta.authors, ["Anthony W. Ulwick"], "other fields untouched")

            let real = dir.appendingPathComponent("dune.pdf")
            try Fixtures.makePDF(at: real, title: "Dune")
            guard case .success(let good)? = MetadataExtractor.extract(url: real, format: .pdf) else {
                expect(false, "fixture PDF must parse"); return
            }
            expectEqual(good.title, "Dune", "real titles pass through unchanged")
        }
    }

    await runner.run("tag sanitizer: count capped at 15, over-length and duplicates dropped") {
        let many = (1...20).map { "tag\($0)" }
        expectEqual(TagSanitizer.sanitize(many).count, TagSanitizer.maxTagCount)

        let long = String(repeating: "x", count: TagSanitizer.maxTagLength + 1)
        let edge = String(repeating: "y", count: TagSanitizer.maxTagLength)
        expectEqual(TagSanitizer.sanitize([long, edge]), [edge],
                    "49-char tag dropped, 48-char tag kept")

        expectEqual(TagSanitizer.sanitize(["SF", "sf", " SF "]), ["SF"],
                    "case-insensitive dedupe after trimming")
        expect(!TagSanitizer.isValid([long]), "over-length tag invalidates a stored list")
        expect(TagSanitizer.isValid(["sf", "classic"]))
    }

    await runner.run("cover cache: removeCover deletes both renditions, garbage data throws") {
        try await withTempDirectory { dir in
            let cache = try CoverCache(directory: dir.appendingPathComponent("covers"))
            let gridURL = try cache.store(imageData: Fixtures.jpegData(), bookId: 7)
            expectEqual(gridURL.path, cache.gridURL(bookId: 7).path)
            expect(cache.totalSizeBytes() > 0)

            cache.removeCover(bookId: 7)
            expect(!FileManager.default.fileExists(atPath: cache.gridURL(bookId: 7).path),
                   "grid rendition must be deleted")
            expect(!FileManager.default.fileExists(atPath: cache.originalURL(bookId: 7).path),
                   "original must be deleted")
            expectEqual(cache.totalSizeBytes(), 0)

            expectThrows("non-image data must throw ParseError") {
                try cache.store(imageData: Data("notanimage".utf8), bookId: 8)
            }
        }
    }
}
