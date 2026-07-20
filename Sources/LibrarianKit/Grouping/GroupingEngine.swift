import Foundation

/// A file's grouping identity — everything the engine needs to decide which
/// logical book it belongs to (FR-2.1).
public struct FileIdentity: Sendable, Hashable {
    public var path: String
    public var format: BookFormat
    /// Filename without extension.
    public var stem: String
    /// Normalized embedded ISBN (13 preferred), when embedded metadata had one.
    public var isbn: String?
    /// Normalizer.key of the embedded title.
    public var titleKey: String?
    /// Normalizer.authorSetKey of embedded authors (order-independent, §9).
    public var authorKey: String?
    /// Manual grouping token (FR-2.4); pins the file to a user-chosen group.
    public var manualGroupId: String?

    public init(
        path: String, format: BookFormat, stem: String,
        isbn: String? = nil, titleKey: String? = nil, authorKey: String? = nil,
        manualGroupId: String? = nil
    ) {
        self.path = path
        self.format = format
        self.stem = stem
        self.isbn = isbn
        self.titleKey = titleKey?.isEmpty == true ? nil : titleKey
        self.authorKey = authorKey?.isEmpty == true ? nil : authorKey
        self.manualGroupId = manualGroupId
    }

    var stemKey: String { Normalizer.stemKey(stem) }
}

/// One proposed logical book.
public struct ProposedGroup: Sendable {
    public var files: [FileIdentity]
    /// Weakest evidence that was needed to form the group: `.filename` means at
    /// least one member joined only by filename similarity → shown as
    /// "auto-grouped" for review (FR-2.5). Manual always wins.
    public var method: GroupMethod
}

/// Groups files into logical books (FR-2.1):
///   1. identical embedded ISBN
///   2. normalized (title, author-set) embedded match
///   3. normalized filename stem match — requires author agreement when
///      authors are known (§9: two different "Rework"s stay separate)
/// Manual merge/ungroup decisions (manualGroupId) take absolute precedence
/// (FR-2.4) and are never joined with automatic groups.
public enum GroupingEngine {
    public static func propose(_ identities: [FileIdentity]) -> [ProposedGroup] {
        guard !identities.isEmpty else { return [] }

        var uf = UnionFind(count: identities.count)
        // Evidence used to form each group, keyed by union-find root. Flags of
        // an absorbed root are folded into the surviving root on every union.
        var evidence: [Int: Set<GroupMethod>] = [:]

        func union(_ a: Int, _ b: Int, method: GroupMethod) {
            let ra = uf.find(a), rb = uf.find(b)
            guard ra != rb else { return }
            uf.union(ra, rb)
            let survivor = uf.find(ra)
            let absorbed = survivor == ra ? rb : ra
            var merged = evidence[survivor, default: []]
            merged.formUnion(evidence[absorbed, default: []])
            merged.insert(method)
            evidence[survivor] = merged
            evidence.removeValue(forKey: absorbed)
        }

        let manualIndices = identities.indices.filter { identities[$0].manualGroupId != nil }
        let autoIndices = identities.indices.filter { identities[$0].manualGroupId == nil }

        // Stage 1 — manual groups: union by token, isolated from all automatic rules.
        var manualBuckets: [String: [Int]] = [:]
        for i in manualIndices {
            manualBuckets[identities[i].manualGroupId!, default: []].append(i)
        }
        for (_, indices) in manualBuckets {
            for other in indices.dropFirst() {
                union(indices[0], other, method: .manual)
            }
        }

        // Stage 2 — identical ISBN.
        var isbnBuckets: [String: [Int]] = [:]
        for i in autoIndices {
            if let isbn = identities[i].isbn {
                isbnBuckets[isbn, default: []].append(i)
            }
        }
        for (_, indices) in isbnBuckets where indices.count > 1 {
            for other in indices.dropFirst() {
                union(indices[0], other, method: .isbn)
            }
        }

        // Stage 3 — normalized (title, author-set) match.
        var metaBuckets: [String: [Int]] = [:]
        for i in autoIndices {
            if let title = identities[i].titleKey, let author = identities[i].authorKey {
                metaBuckets["\(title)::\(author)", default: []].append(i)
            }
        }
        for (_, indices) in metaBuckets where indices.count > 1 {
            for other in indices.dropFirst() {
                union(indices[0], other, method: .metadata)
            }
        }

        // Stage 4 — filename stem match, guarded by author agreement (§9).
        var stemBuckets: [String: [Int]] = [:]
        for i in autoIndices {
            let stem = identities[i].stemKey
            guard !stem.isEmpty else { continue }
            stemBuckets[stem, default: []].append(i)
        }
        for (_, indices) in stemBuckets where indices.count > 1 {
            let authorKeys = Set(indices.compactMap { identities[$0].authorKey })
            if authorKeys.count <= 1 {
                // No conflict: everything in the bucket is one book.
                for other in indices.dropFirst() {
                    union(indices[0], other, method: .filename)
                }
            } else {
                // Conflicting known authors: sub-group per author set; files
                // with unknown authors stay separate (user can merge, FR-2.4).
                var byAuthor: [String: [Int]] = [:]
                var unknown: [Int] = []
                for i in indices {
                    if let key = identities[i].authorKey {
                        byAuthor[key, default: []].append(i)
                    } else {
                        unknown.append(i)
                    }
                }
                for (_, sub) in byAuthor where sub.count > 1 {
                    for other in sub.dropFirst() {
                        union(sub[0], other, method: .filename)
                    }
                }
                if unknown.count > 1 {
                    for other in unknown.dropFirst() {
                        union(unknown[0], other, method: .filename)
                    }
                }
            }
        }

        // Collect groups.
        var groups: [Int: [Int]] = [:]
        for i in identities.indices {
            groups[uf.find(i), default: []].append(i)
        }

        return groups.map { root, indices in
            let files = indices.map { identities[$0] }
                .sorted { $0.path < $1.path }
            let used = evidence[root, default: []]
            let method: GroupMethod
            if identities[indices[0]].manualGroupId != nil {
                // Manual tokens mark the group even when it has one file
                // (an ungrouped singleton is still a user decision).
                method = .manual
            } else if files.count == 1 {
                method = .single
            } else if used.contains(.filename) {
                method = .filename   // weakest link needed → auto-grouped (FR-2.5)
            } else if used.contains(.metadata) {
                method = .metadata
            } else if used.contains(.isbn) {
                method = .isbn
            } else {
                method = .single
            }
            return ProposedGroup(files: files, method: method)
        }
        .sorted { ($0.files.first?.path ?? "") < ($1.files.first?.path ?? "") }
    }
}

/// Plain union-find with path compression. The "flag sets" above are keyed by
/// root; after any union the surviving root inherits flags of both sides.
struct UnionFind {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var current = x
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    /// Returns true when the two elements were in different sets.
    @discardableResult
    mutating func union(_ a: Int, _ b: Int) -> Bool {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return false }
        parent[rb] = ra
        return true
    }
}
