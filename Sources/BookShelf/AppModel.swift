import Foundation
import AppKit
import Observation
import GRDB
import BookShelfKit

/// One row in the library: a logical book plus its files.
struct BookListItem: Identifiable, Equatable {
    var book: Book
    var files: [BookFile]

    var id: Int64 { book.id ?? 0 }

    var formats: [BookFormat] {
        var seen: Set<BookFormat> = []
        return files.compactMap { seen.insert($0.format).inserted ? $0.format : nil }
    }

    var totalSizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    var hasMissingFiles: Bool { files.contains(where: \.missingFlag) }
    var allFilesMissing: Bool { !files.isEmpty && files.allSatisfy(\.missingFlag) }
    var isAutoGrouped: Bool { book.groupMethod == .filename && files.count > 1 }
}

enum ViewMode: String {
    case grid, table
}

enum SortKey: String, CaseIterable, Identifiable {
    case title, author, year, dateAdded, size
    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .author: return "Author"
        case .year: return "Year"
        case .dateAdded: return "Date Added"
        case .size: return "File Size"
        }
    }
}

/// Metadata-status / disk-state filters (FR-6.3).
enum LibraryFilter: Hashable {
    case format(BookFormat)
    case status(MetadataStatus)
    case missingOnDisk
    case autoGrouped
    case tag(String)
}

@Observable
@MainActor
final class AppModel {
    let database: AppDatabase
    let coverCache: CoverCache

    private(set) var items: [BookListItem] = []
    private(set) var libraryFolder: URL?
    private(set) var scanProgress: ScanProgress?
    private(set) var lastScanResult: ScanResult?
    var errorMessage: String?
    var viewMode: ViewMode = .grid
    var selection: Set<Int64> = []

    // Search / filter / sort (FR-6.2, FR-6.3, FR-6.4)
    var searchText = ""
    var activeFilters: Set<LibraryFilter> = []
    var sortKey: SortKey = .title
    var sortAscending = true

    private var observationTask: Task<Void, Never>?

    init(database: AppDatabase? = nil) throws {
        self.database = try database ?? AppDatabase.open(at: AppDatabase.defaultURL())
        self.coverCache = try CoverCache.default()
        self.libraryFolder = try? FolderAccess.restore(from: self.database)
        if let raw = try? self.database.setting("viewMode"), let mode = ViewMode(rawValue: raw) {
            self.viewMode = mode
        }
        startObservation()
    }

    // MARK: - Live query

    private func startObservation() {
        let observation = ValueObservation.tracking { db -> [BookListItem] in
            let books = try Book.order(Book.Columns.titleSort).fetchAll(db)
            let files = try BookFile.fetchAll(db)
            let filesByBook = Dictionary(grouping: files, by: \.bookId)
            return books.map { book in
                BookListItem(book: book, files: filesByBook[book.id ?? -1] ?? [])
            }
        }
        let writer = database.writer
        observationTask = Task { [weak self] in
            do {
                for try await items in observation.values(in: writer) {
                    self?.items = items
                }
            } catch {
                self?.errorMessage = "Library observation failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Folder & scan

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your books folder. Files are read in place and never moved."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FolderAccess.persist(url: url, in: database)
            libraryFolder = url
            Task { await self.scan() }
        } catch {
            errorMessage = "Could not save folder access: \(error.localizedDescription)"
        }
    }

    var isScanning: Bool {
        if let progress = scanProgress, progress.phase != .finished { return true }
        return false
    }

    func scan() async {
        guard let root = libraryFolder, !isScanning else { return }
        scanProgress = ScanProgress(phase: .enumerating, processed: 0, total: 0)
        let pipeline = ScanPipeline(database: database, coverCache: coverCache)
        do {
            let result = try await pipeline.scan(root: root) { progress in
                Task { @MainActor [weak self] in
                    self?.scanProgress = progress
                }
            }
            lastScanResult = result
        } catch {
            errorMessage = "Scan failed: \(error.localizedDescription)"
        }
        scanProgress = nil
    }

    func purgeMissing() async {
        do {
            _ = try await LibraryScanner(database: database).purgeMissing()
        } catch {
            errorMessage = "Purge failed: \(error.localizedDescription)"
        }
    }

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        try? database.setSetting("viewMode", mode.rawValue)
    }

    // MARK: - Derived list

    /// Items after search, filters, and sort — what the views render.
    var displayedItems: [BookListItem] {
        var result = items

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { matches($0, query: query) }
        }
        for filter in activeFilters {
            switch filter {
            case .format(let format):
                result = result.filter { $0.formats.contains(format) }
            case .status(let status):
                result = result.filter { $0.book.metadataStatus == status }
            case .missingOnDisk:
                result = result.filter(\.hasMissingFiles)
            case .autoGrouped:
                result = result.filter(\.isAutoGrouped)
            case .tag(let tag):
                result = result.filter { $0.book.tags.contains(tag) }
            }
        }

        result.sort { a, b in
            let ordered: Bool
            switch sortKey {
            case .title:
                ordered = a.book.titleSort < b.book.titleSort
            case .author:
                ordered = (a.book.authorSort ?? "~") < (b.book.authorSort ?? "~")
            case .year:
                ordered = (a.book.year ?? Int.min) < (b.book.year ?? Int.min)
            case .dateAdded:
                ordered = a.book.createdAt < b.book.createdAt
            case .size:
                ordered = a.totalSizeBytes < b.totalSizeBytes
            }
            return sortAscending ? ordered : !ordered
        }
        return result
    }

    /// Search across title, author, series, ISBN, tags, and filename (FR-6.2).
    private func matches(_ item: BookListItem, query: String) -> Bool {
        if item.book.title.lowercased().contains(query) { return true }
        if item.book.authors.contains(where: { $0.lowercased().contains(query) }) { return true }
        if let series = item.book.series, series.lowercased().contains(query) { return true }
        if let isbn = item.book.isbn13, isbn.contains(query) { return true }
        if let isbn = item.book.isbn10, isbn.contains(query) { return true }
        if item.book.tags.contains(where: { $0.lowercased().contains(query) }) { return true }
        if item.files.contains(where: {
            URL(fileURLWithPath: $0.path).lastPathComponent.lowercased().contains(query)
        }) { return true }
        return false
    }

    var allTags: [String] {
        var seen: Set<String> = []
        var tags: [String] = []
        for item in items {
            for tag in item.book.tags where seen.insert(tag).inserted {
                tags.append(tag)
            }
        }
        return tags.sorted()
    }

    var selectedItems: [BookListItem] {
        items.filter { selection.contains($0.id) }
    }

    var detailItem: BookListItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: - Merge / split (FR-2.4)

    func mergeSelection() async {
        let ids = Array(selection)
        guard ids.count >= 2 else { return }
        // Target: the entry with the most complete metadata.
        let ranked = selectedItems.sorted { a, b in
            rank(a.book.metadataStatus) > rank(b.book.metadataStatus)
        }
        guard let target = ranked.first?.id else { return }
        let sources = ids.filter { $0 != target }
        do {
            try await database.writer.write { db in
                try GroupingOperations.merge(db, sourceIds: sources, into: target)
            }
            selection = [target]
        } catch {
            errorMessage = "Merge failed: \(error.localizedDescription)"
        }
    }

    func split(fileId: Int64) async {
        do {
            let newBookId = try await database.writer.write { db in
                try GroupingOperations.split(db, fileId: fileId)
            }
            selection = [newBookId]
        } catch {
            errorMessage = "Split failed: \(error.localizedDescription)"
        }
    }

    private func rank(_ status: MetadataStatus) -> Int {
        switch status {
        case .complete: return 2
        case .partial: return 1
        case .unresolved: return 0
        }
    }

    // MARK: - File actions

    func openFile(_ file: BookFile) {
        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
    }

    func revealInFinder(_ file: BookFile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
    }
}

extension Int64 {
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
