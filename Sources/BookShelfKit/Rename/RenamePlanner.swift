import Foundation

/// One row of the mandatory preview sheet (FR-4.6).
public struct RenamePlanItem: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case ready
        /// Name already matches the template.
        case noOp
        /// Target existed; suffixed name was assigned (FR-4.5).
        case collisionResolved
        /// Required template tokens missing → excluded with reason (FR-4.9).
        case missingTokens([String])
        /// File is flagged missing on disk.
        case missingOnDisk
    }

    public let id: Int64            // file id
    public let bookId: Int64
    public let bookTitle: String
    public let currentPath: String
    public let proposedName: String?
    public let status: Status
    /// User can exclude individual rows in the preview.
    public var included: Bool

    public init(id: Int64, bookId: Int64, bookTitle: String, currentPath: String,
                proposedName: String?, status: Status, included: Bool) {
        self.id = id
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.currentPath = currentPath
        self.proposedName = proposedName
        self.status = status
        self.included = included
    }

    public var currentName: String {
        URL(fileURLWithPath: currentPath).lastPathComponent
    }

    public var newPath: String? {
        guard let proposedName else { return nil }
        return URL(fileURLWithPath: currentPath)
            .deletingLastPathComponent()
            .appendingPathComponent(proposedName).path
    }
}

/// Builds the rename plan: renders the template per book, applies it to every
/// file of the book consistently (FR-4.6), and resolves collisions per
/// directory against both the disk and the rest of the batch (FR-4.5).
public enum RenamePlanner {
    public static func plan(
        items: [(book: Book, files: [BookFile])],
        template: RenameTemplate,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [RenamePlanItem] {
        var rows: [RenamePlanItem] = []
        // Names already claimed in each directory by this batch.
        var claimed: [String: Set<String>] = [:]

        for (book, files) in items {
            guard let bookId = book.id else { continue }
            for file in files {
                guard let fileId = file.id else { continue }
                if file.missingFlag {
                    rows.append(RenamePlanItem(
                        id: fileId, bookId: bookId, bookTitle: book.title,
                        currentPath: file.path, proposedName: nil,
                        status: .missingOnDisk, included: false))
                    continue
                }

                let ext = URL(fileURLWithPath: file.path).pathExtension
                let result = template.render(book: book, fileExtension: ext)
                guard let baseName = result.name else {
                    rows.append(RenamePlanItem(
                        id: fileId, bookId: bookId, bookTitle: book.title,
                        currentPath: file.path, proposedName: nil,
                        status: .missingTokens(result.missingTokens.map { "{\($0.rawValue)}" }),
                        included: false))
                    continue
                }

                let directory = URL(fileURLWithPath: file.path)
                    .deletingLastPathComponent().path
                let currentName = URL(fileURLWithPath: file.path).lastPathComponent

                if baseName == currentName {
                    rows.append(RenamePlanItem(
                        id: fileId, bookId: bookId, bookTitle: book.title,
                        currentPath: file.path, proposedName: baseName,
                        status: .noOp, included: false))
                    claimed[directory, default: []].insert(baseName.lowercased())
                    continue
                }

                // Collision resolution: never overwrite (FR-4.5).
                func isTaken(_ name: String) -> Bool {
                    if claimed[directory, default: []].contains(name.lowercased()) {
                        return true
                    }
                    let candidatePath = directory + "/" + name
                    return candidatePath != file.path && fileExists(candidatePath)
                }

                var finalName = baseName
                var counter = 2
                var collided = false
                while isTaken(finalName) {
                    collided = true
                    let url = URL(fileURLWithPath: baseName)
                    let stem = url.deletingPathExtension().lastPathComponent
                    let ext = url.pathExtension
                    finalName = ext.isEmpty
                        ? "\(stem) (\(counter))"
                        : "\(stem) (\(counter)).\(ext)"
                    counter += 1
                }
                claimed[directory, default: []].insert(finalName.lowercased())

                rows.append(RenamePlanItem(
                    id: fileId, bookId: bookId, bookTitle: book.title,
                    currentPath: file.path, proposedName: finalName,
                    status: collided ? .collisionResolved : .ready,
                    included: true))
            }
        }
        return rows
    }
}
