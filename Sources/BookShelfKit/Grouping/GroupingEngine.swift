import Foundation
import GRDB

/// Metadata known about a file at grouping time. Embedded fields are filled
/// by the format parsers when available; the filename stem is always present.
public struct GroupingSeed: Sendable {
    public var isbn: String?
    public var title: String?
    public var authors: [String]
    public var rawStem: String

    public init(isbn: String? = nil, title: String? = nil, authors: [String] = [], rawStem: String) {
        self.isbn = isbn
        self.title = title
        self.authors = authors
        self.rawStem = rawStem
    }

    public static func fromFilename(_ url: URL) -> GroupingSeed {
        GroupingSeed(rawStem: url.deletingPathExtension().lastPathComponent)
    }
}

/// Groups multi-format copies of the same work into one logical book (FR-2.1).
///
/// Rule priority: identical ISBN → normalized (title, author set) →
/// normalized filename stem with author-token agreement. Books created or
/// split manually are never auto-joined (FR-2.4).
public final class GroupingEngine: @unchecked Sendable {
    /// A (titleKey, authorTokens) pair a file's name can be read as.
    /// "Dune - Frank Herbert" yields the full stem plus both split orders.
    struct StemCandidate {
        let titleKey: String
        let authorTokens: Set<String>
    }

    private struct StemEntry {
        let bookId: Int64
        let authorTokens: Set<String>
    }

    private let lock = NSLock()
    private var byISBN: [String: Int64] = [:]
    private var byMetadataKey: [String: Int64] = [:]
    private var stemIndex: [String: [StemEntry]] = [:]
    private var manualBookIds: Set<Int64> = []

    public init() {}

    // MARK: - Loading existing state

    /// Builds the in-memory index from all known books and files.
    public static func load(_ db: Database) throws -> GroupingEngine {
        let engine = GroupingEngine()
        let books = try Book.fetchAll(db)
        let files = try BookFile.fetchAll(db)
        let filesByBook = Dictionary(grouping: files, by: \.bookId)

        for book in books {
            guard let bookId = book.id else { continue }
            if book.manualGroup {
                engine.manualBookIds.insert(bookId)
                continue
            }
            engine.register(
                bookId: bookId,
                isbn: book.isbn13 ?? book.isbn10,
                title: book.title,
                authors: book.authors,
                stems: (filesByBook[bookId] ?? []).map {
                    URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent
                }
            )
        }
        return engine
    }

    // MARK: - Decisions

    public enum Decision: Equatable {
        case join(bookId: Int64, method: GroupMethod)
        case createNew
    }

    public func decide(_ seed: GroupingSeed) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        return decideLocked(seed)
    }

    private func decideLocked(_ seed: GroupingSeed) -> Decision {
        // Rule 1: identical ISBN.
        if let raw = seed.isbn, let isbn = Normalizer.extractISBN(raw), let bookId = byISBN[isbn] {
            return .join(bookId: bookId, method: .isbn)
        }
        // Rule 2: normalized (title, author set) from embedded metadata.
        if let key = Self.metadataKey(title: seed.title, authors: seed.authors),
           let bookId = byMetadataKey[key] {
            return .join(bookId: bookId, method: .metadata)
        }
        // Rule 3: filename stem candidates with author-token agreement (§9).
        for candidate in Self.stemCandidates(seed.rawStem) {
            guard let entries = stemIndex[candidate.titleKey] else { continue }
            for entry in entries {
                let bothHaveAuthors = !entry.authorTokens.isEmpty && !candidate.authorTokens.isEmpty
                let agree = !bothHaveAuthors
                    || !entry.authorTokens.intersection(candidate.authorTokens).isEmpty
                if agree {
                    return .join(bookId: entry.bookId, method: .filename)
                }
            }
        }
        return .createNew
    }

    // MARK: - Assignment (runs inside the scanner's write transaction)

    /// Decides, creates/joins, and indexes in one atomic step. Suitable as a
    /// `LibraryScanner.BookAssigner` once wrapped with a seed provider.
    public func assignBook(_ db: Database, seed: GroupingSeed) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        switch decideLocked(seed) {
        case .join(let bookId, let method):
            if var book = try Book.fetchOne(db, key: bookId) {
                if Self.methodRank(method) > Self.methodRank(book.groupMethod) {
                    book.groupMethod = method
                }
                book.updatedAt = Date()
                try book.update(db)
            }
            registerLocked(bookId: bookId, isbn: seed.isbn, title: seed.title,
                           authors: seed.authors, stems: [seed.rawStem])
            return bookId

        case .createNew:
            let inferred = Self.inferTitleAuthors(fromStem: seed.rawStem)
            var book = Book(
                title: seed.title ?? inferred.title,
                authors: seed.authors.isEmpty ? inferred.authors : seed.authors,
                isbn10: seed.isbn.flatMap { Normalizer.extractISBN($0)?.count == 10 ? $0 : nil },
                isbn13: seed.isbn.flatMap { Normalizer.extractISBN($0)?.count == 13 ? $0 : nil },
                metadataStatus: seed.title == nil ? .unresolved : .partial,
                groupMethod: .single
            )
            try book.insert(db)
            registerLocked(bookId: book.id!, isbn: seed.isbn, title: seed.title,
                           authors: seed.authors, stems: [seed.rawStem])
            return book.id!
        }
    }

    /// Wraps this engine as a scanner assigner, grouping on the prepared seed.
    public func makeAssigner() -> LibraryScanner.BookAssigner {
        { db, prepared in
            try self.assignBook(db, seed: prepared.seed)
        }
    }

    // MARK: - Index registration

    func register(bookId: Int64, isbn: String?, title: String?, authors: [String], stems: [String]) {
        lock.lock()
        defer { lock.unlock() }
        registerLocked(bookId: bookId, isbn: isbn, title: title, authors: authors, stems: stems)
    }

    private func registerLocked(bookId: Int64, isbn: String?, title: String?, authors: [String], stems: [String]) {
        guard !manualBookIds.contains(bookId) else { return }
        if let raw = isbn, let normalized = Normalizer.extractISBN(raw) {
            byISBN[normalized] = bookId
        }
        if let key = Self.metadataKey(title: title, authors: authors) {
            byMetadataKey[key] = bookId
        }
        for stem in stems {
            for candidate in Self.stemCandidates(stem) {
                stemIndex[candidate.titleKey, default: []].append(
                    StemEntry(bookId: bookId, authorTokens: candidate.authorTokens))
            }
        }
    }

    // MARK: - Keys & inference

    static func metadataKey(title: String?, authors: [String]) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let titleKey = Normalizer.normalizeTitle(title)
        guard !titleKey.isEmpty else { return nil }
        let authorKey = Normalizer.authorTokenSet(authors).sorted().joined(separator: " ")
        return "\(titleKey)|\(authorKey)"
    }

    /// Tokens that must never establish a match on their own — years glued
    /// whole download collections into one book ("X - 2007", "Y - 2007"),
    /// and stopword overlap faked author agreement.
    static let weakTokens: Set<String> = [
        "the", "a", "an", "of", "to", "and", "or", "in", "on", "for", "by",
        "with", "at", "from", "etc", "et", "al", "vol", "volume", "edition", "ed",
    ]

    /// A title key is viable only if it contains at least one meaningful
    /// token (≥2 chars, not a number, not a stopword). "2007" or "the" can
    /// never identify a work.
    public static func isViableTitleKey(_ key: String) -> Bool {
        key.split(separator: " ").contains { token in
            token.count >= 2 && !token.allSatisfy(\.isNumber) && !weakTokens.contains(String(token))
        }
    }

    /// Author tokens reduced to the ones that can actually attest agreement.
    public static func meaningfulTokens(_ key: String) -> Set<String> {
        Set(key.split(separator: " ").map(String.init).filter { token in
            token.count >= 2 && !token.allSatisfy(\.isNumber) && !weakTokens.contains(token)
        })
    }

    /// All (titleKey, authorTokens) readings of a filename stem: the full
    /// normalized stem, plus both orders of a two-part " - " split.
    static func stemCandidates(_ rawStem: String) -> [StemCandidate] {
        let full = Normalizer.normalizeFilenameStem(rawStem)
        guard isViableTitleKey(full) else { return [] }
        var candidates = [StemCandidate(titleKey: full, authorTokens: [])]

        let spaced = rawStem.replacingOccurrences(of: "_", with: " ")
        let parts = spaced
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.count == 2 {
            let key0 = Normalizer.normalizeFilenameStem(parts[0])
            let key1 = Normalizer.normalizeFilenameStem(parts[1])
            let tokens0 = meaningfulTokens(key0)
            let tokens1 = meaningfulTokens(key1)
            if isViableTitleKey(key0) && !tokens1.isEmpty {
                candidates.append(StemCandidate(titleKey: key0, authorTokens: tokens1))
            }
            if isViableTitleKey(key1) && !tokens0.isEmpty {
                candidates.append(StemCandidate(titleKey: key1, authorTokens: tokens0))
            }
        }
        return candidates
    }

    /// Best-effort display title/authors for a book created from a filename.
    /// Assumes "Author - Title" when the author side looks like a person name
    /// (≤ 3 words, no digits); refined later by metadata resolution (FR-3).
    public static func inferTitleAuthors(fromStem rawStem: String) -> (title: String, authors: [String]) {
        let spaced = rawStem
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let parts = spaced
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2 else { return (spaced, []) }

        func looksLikeName(_ s: String) -> Bool {
            let words = s.split(separator: " ")
            return words.count <= 3 && !words.isEmpty && !s.contains(where: \.isNumber)
        }

        if looksLikeName(parts[0]) && !looksLikeName(parts[1]) {
            return (parts[1], [parts[0]])
        }
        if looksLikeName(parts[1]) && !looksLikeName(parts[0]) {
            return (parts[0], [parts[1]])
        }
        // Both plausible: spec lists "Author - Title" first; prefer it.
        if looksLikeName(parts[0]) {
            return (parts[1], [parts[0]])
        }
        return (spaced, [])
    }

    static func methodRank(_ method: GroupMethod) -> Int {
        switch method {
        case .manual: return 5
        case .isbn: return 4
        case .metadata: return 3
        case .filename: return 2
        case .single: return 1
        }
    }
}

// MARK: - Manual merge / split (FR-2.4)

public enum GroupingOperations {
    /// Merges all files of `sourceIds` into `targetId`. The target keeps its
    /// metadata, is flagged manual (so rescans never undo the decision), and
    /// emptied source books are deleted.
    public static func merge(_ db: Database, sourceIds: [Int64], into targetId: Int64) throws {
        guard var target = try Book.fetchOne(db, key: targetId) else {
            throw DatabaseError(message: "merge target \(targetId) not found")
        }
        for sourceId in sourceIds where sourceId != targetId {
            let files = try BookFile
                .filter(BookFile.Columns.bookId == sourceId)
                .fetchAll(db)
            for var file in files {
                file.bookId = targetId
                try file.update(db)
            }
            _ = try Book.deleteOne(db, key: sourceId)
        }
        target.groupMethod = .manual
        target.manualGroup = true
        target.updatedAt = Date()
        try target.update(db)
    }

    /// Splits one file out into its own (manual) book and returns its id.
    /// If the source book has no files left, it is deleted.
    @discardableResult
    public static func split(_ db: Database, fileId: Int64) throws -> Int64 {
        guard var file = try BookFile.fetchOne(db, key: fileId) else {
            throw DatabaseError(message: "file \(fileId) not found")
        }
        let sourceBookId = file.bookId
        let stem = URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
        let inferred = GroupingEngine.inferTitleAuthors(fromStem: stem)

        var book = Book(
            title: inferred.title,
            authors: inferred.authors,
            metadataStatus: .unresolved,
            groupMethod: .manual,
            manualGroup: true
        )
        try book.insert(db)
        file.bookId = book.id!
        try file.update(db)

        let remaining = try BookFile
            .filter(BookFile.Columns.bookId == sourceBookId)
            .fetchCount(db)
        if remaining == 0 {
            _ = try Book.deleteOne(db, key: sourceBookId)
        }
        return book.id!
    }
}
