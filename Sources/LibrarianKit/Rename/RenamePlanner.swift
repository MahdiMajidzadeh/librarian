import Foundation

/// One row of the mandatory rename preview (FR-4.6).
public struct RenamePlanRow: Sendable, Identifiable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Renames cleanly.
        case ready
        /// Proposed name equals the current name — nothing to do.
        case noOp
        /// Target collided; the shown name already carries the " (n)" suffix
        /// (FR-4.5) and the row is highlighted in the preview.
        case collision
        /// Not renamable; carries the reason (FR-4.9: unresolved required
        /// token, or the file is missing on disk).
        case excluded(String)
    }

    public var id: Int64          // file id
    public var bookId: Int64
    public var bookTitle: String
    public var currentPath: String
    public var proposedName: String
    public var status: Status
    /// Preview checkbox (FR-4.6); excluded rows are never included.
    public var included: Bool

    public var currentName: String { (currentPath as NSString).lastPathComponent }
    public var targetPath: String {
        ((currentPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(proposedName)
    }
    public var isActionable: Bool {
        included && (status == .ready || status == .collision)
    }
}

/// Builds a rename plan for a selection of books (FR-4.5, FR-4.6, FR-4.9).
/// Multi-format books rename all their files consistently in one batch.
/// Collision handling is same-directory only (§9): cross-folder duplicates
/// never conflict.
public enum RenamePlanner {
    public static func plan(
        template: String,
        selection: [(book: Book, files: [BookFile])],
        fileManager: FileManager = .default
    ) throws -> [RenamePlanRow] {
        _ = try RenameTemplate.parse(template) // fail fast on a bad template

        var rows: [RenamePlanRow] = []
        // Names already claimed per directory (case-folded: APFS default is
        // case-insensitive). Seeded lazily from disk, minus batch members'
        // current names (their old names free up when the batch executes).
        var claimed: [String: Set<String>] = [:]
        var batchCurrentNames: [String: Set<String>] = [:]

        let allFiles = selection.flatMap { pair in
            pair.files.map { (book: pair.book, file: $0) }
        }
        for (_, file) in allFiles {
            let dir = (file.path as NSString).deletingLastPathComponent
            batchCurrentNames[dir, default: []].insert(file.filename.lowercased())
        }

        func claimedNames(inDirectory dir: String) -> Set<String> {
            if let cached = claimed[dir] { return cached }
            let onDisk = (try? fileManager.contentsOfDirectory(atPath: dir)) ?? []
            var names = Set(onDisk.map { $0.lowercased() })
            // Batch members' current names are not obstacles — they move away.
            names.subtract(batchCurrentNames[dir] ?? [])
            claimed[dir] = names
            return names
        }

        for (book, file) in allFiles.sorted(by: { $0.file.path < $1.file.path }) {
            guard let fileId = file.id, let bookId = book.id else { continue }

            func row(_ name: String, _ status: RenamePlanRow.Status) -> RenamePlanRow {
                RenamePlanRow(
                    id: fileId, bookId: bookId, bookTitle: book.title,
                    currentPath: file.path, proposedName: name,
                    status: status,
                    included: {
                        if case .excluded = status { return false }
                        if status == .noOp { return false }
                        return true
                    }())
            }

            if file.missingFlag {
                rows.append(row(file.filename, .excluded("File is missing on disk")))
                continue
            }

            let ext = (file.path as NSString).pathExtension
            let render = try RenameTemplate.render(
                template: template, book: book, fileExtension: ext)
            if !render.missingRequiredTokens.isEmpty {
                let tokens = render.missingRequiredTokens
                    .map { "{\($0)}" }.joined(separator: ", ")
                rows.append(row(file.filename, .excluded("Missing value for \(tokens)")))
                continue
            }

            let dir = (file.path as NSString).deletingLastPathComponent
            let proposed = render.filename

            if proposed.lowercased() == file.filename.lowercased() {
                if proposed == file.filename {
                    rows.append(row(proposed, .noOp))
                } else {
                    // Case-only rename: valid on APFS, never a collision with itself.
                    rows.append(row(proposed, .ready))
                    var names = claimedNames(inDirectory: dir)
                    names.insert(proposed.lowercased())
                    claimed[dir] = names
                }
                continue
            }

            var names = claimedNames(inDirectory: dir)
            var final = proposed
            var collided = false
            if names.contains(final.lowercased()) {
                collided = true
                final = Self.suffixed(proposed, avoiding: names)
            }
            names.insert(final.lowercased())
            claimed[dir] = names

            rows.append(row(final, collided ? .collision : .ready))
        }
        return rows
    }

    /// Appends " (2)", " (3)"… before the extension until the name is free.
    /// The 255-byte cap is enforced on the stem *before* appending the
    /// suffix, so a max-length name never has its counter truncated away
    /// (FR-4.5, FR-4.4).
    static func suffixed(_ name: String, avoiding taken: Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let dotExt = ext.isEmpty ? "" : ".\(ext)"
        var counter = 2
        while true {
            let marker = " (\(counter))"
            let budget = 255 - dotExt.utf8.count - marker.utf8.count
            let candidate = RenameTemplate.trimToBytes(stem, budget) + marker + dotExt
            if !taken.contains(candidate.lowercased()) {
                return candidate
            }
            counter += 1
        }
    }
}
