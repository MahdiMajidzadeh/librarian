import Foundation
import ImageIO
import BookShelfKit

func epubParserTests(_ runner: TestRunner) async {
    await runner.run("epub: full Dublin Core metadata extraction") {
        try await withTempDirectory { dir in
            let url = dir.appendingPathComponent("dune.epub")
            try Fixtures.makeEpub(at: url)

            let meta = try EpubParser.parse(url: url)
            expectEqual(meta.title, "Dune")
            expectEqual(meta.authors, ["Frank Herbert"])
            expectEqual(meta.publisher, "Chilton Books")
            expectEqual(meta.language, "en")
            expectEqual(meta.isbn, "9780441172719")
            expectEqual(meta.year, 1965)
            expectEqual(meta.description, "Melange is everything.")
            expectEqual(meta.subjects, ["Science Fiction"])
        }
    }

    await runner.run("epub: epub3 cover-image property extraction") {
        try await withTempDirectory { dir in
            let url = dir.appendingPathComponent("book.epub")
            try Fixtures.makeEpub(at: url)
            let meta = try EpubParser.parse(url: url)
            expect(meta.coverData != nil, "cover data should be extracted")
            expect((meta.coverData?.count ?? 0) > 100, "cover should be a real JPEG")
        }
    }

    await runner.run("epub: epub2 meta name=cover fallback") {
        try await withTempDirectory { dir in
            var spec = Fixtures.EpubSpec()
            spec.epub2StyleCover = true
            let url = dir.appendingPathComponent("book2.epub")
            try Fixtures.makeEpub(at: url, spec: spec)
            let meta = try EpubParser.parse(url: url)
            expect(meta.coverData != nil, "epub2-style cover should be found")
        }
    }

    await runner.run("epub: unicode metadata (Persian) survives") {
        try await withTempDirectory { dir in
            var spec = Fixtures.EpubSpec()
            spec.title = "بوف کور"
            spec.authors = ["صادق هدایت"]
            spec.language = "fa"
            spec.isbn = nil
            let url = dir.appendingPathComponent("boofekoor.epub")
            try Fixtures.makeEpub(at: url, spec: spec)
            let meta = try EpubParser.parse(url: url)
            expectEqual(meta.title, "بوف کور")
            expectEqual(meta.authors, ["صادق هدایت"])
        }
    }

    await runner.run("epub: corrupt file throws ParseError, not crash") {
        try await withTempDirectory { dir in
            let url = dir.appendingPathComponent("broken.epub")
            try Data("this is not a zip".utf8).write(to: url)
            expectThrows("corrupt epub must throw") {
                _ = try EpubParser.parse(url: url)
            }
        }
    }

    await runner.run("cover cache: grid rendition capped at 600px, original kept") {
        try await withTempDirectory { dir in
            let cache = try CoverCache(directory: dir.appendingPathComponent("covers"))
            let big = Fixtures.jpegData(width: 900, height: 1400)
            let gridURL = try cache.store(imageData: big, bookId: 42)

            expect(FileManager.default.fileExists(atPath: gridURL.path))
            expect(FileManager.default.fileExists(atPath: cache.originalURL(bookId: 42).path))

            if let source = CGImageSourceCreateWithURL(gridURL as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = props[kCGImagePropertyPixelWidth] as? Int,
               let height = props[kCGImagePropertyPixelHeight] as? Int {
                expect(max(width, height) <= 600, "grid cover must be ≤600px, got \(width)x\(height)")
            } else {
                expect(false, "grid cover not decodable")
            }

            expect(cache.totalSizeBytes() > 0)
            try cache.clear()
            expectEqual(cache.totalSizeBytes(), 0)
        }
    }
}
