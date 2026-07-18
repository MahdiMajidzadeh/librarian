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

    // Online resolution (FR-3)
    private(set) var resolveProgress: (done: Int, total: Int)?
    var pendingPicker: PickerRequest?
    private var pickerQueue: [PickerRequest] = []
    private(set) var lastResolveSummary: String?

    struct PickerRequest: Identifiable {
        let id: Int64          // book id
        let bookTitle: String
        let candidates: [LookupCandidate]
    }

    // Rename (FR-4)
    var renamePlan: [RenamePlanItem]?
    private(set) var undoableBatch: (batchId: String, count: Int)?
    private(set) var lastRenameSummary: String?

    private var observationTask: Task<Void, Never>?

    init(database: AppDatabase? = nil) throws {
        self.database = try database ?? AppDatabase.open(at: AppDatabase.defaultURL())
        self.coverCache = try CoverCache.default()
        self.libraryFolder = try? FolderAccess.restore(from: self.database)
        if let raw = try? self.database.setting("viewMode"), let mode = ViewMode(rawValue: raw) {
            self.viewMode = mode
        }
        startObservation()
        Task { await refreshUndoState() }
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
            let result = try await pipeline.scan(root: root, ignoredExtensions: ignoredExtensions) { progress in
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

    // MARK: - Online resolution (FR-3)

    var applyPolicy: ApplyPolicy {
        let raw = (try? database.setting("applyPolicy")) ?? nil
        return raw.flatMap(ApplyPolicy.init(rawValue:)) ?? .fillEmpty
    }

    private func makeLookupService() -> LookupService {
        let googleKey = (try? database.setting("googleBooksAPIKey")) ?? nil
        return LookupService(
            database: database,
            coverCache: coverCache,
            providers: LookupService.standardProviders(googleAPIKey: googleKey))
    }

    var isResolving: Bool { resolveProgress != nil }

    /// Books worth resolving in a "resolve all missing" pass.
    var unresolvedBookIds: [Int64] {
        items.filter { $0.book.metadataStatus != .complete }.map(\.id)
    }

    func resolveMetadata(ids: [Int64]) async {
        guard !ids.isEmpty, !isResolving else { return }
        let service = makeLookupService()
        resolveProgress = (0, ids.count)
        let outcome = await service.resolveBatch(bookIds: ids, policy: applyPolicy) { done, total in
            Task { @MainActor [weak self] in
                self?.resolveProgress = (done, total)
            }
        }
        resolveProgress = nil

        // Queue ambiguous books for the candidate picker (FR-3.4).
        for (bookId, candidates) in outcome.ambiguous.sorted(by: { $0.key < $1.key }) {
            let title = items.first { $0.id == bookId }?.book.title ?? "Book \(bookId)"
            pickerQueue.append(PickerRequest(id: bookId, bookTitle: title, candidates: candidates))
        }
        advancePicker()

        var parts: [String] = []
        if !outcome.resolved.isEmpty { parts.append("\(outcome.resolved.count) resolved") }
        if !outcome.ambiguous.isEmpty { parts.append("\(outcome.ambiguous.count) need review") }
        if !outcome.noMatch.isEmpty { parts.append("\(outcome.noMatch.count) no match") }
        if !outcome.failed.isEmpty { parts.append("\(outcome.failed.count) failed") }
        lastResolveSummary = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func advancePicker() {
        pendingPicker = pickerQueue.isEmpty ? nil : pickerQueue.removeFirst()
    }

    func applyCandidate(_ candidate: LookupCandidate, to bookId: Int64) async {
        do {
            try await makeLookupService().apply(candidate, to: bookId, policy: applyPolicy)
        } catch {
            errorMessage = "Applying metadata failed: \(error.localizedDescription)"
        }
        advancePicker()
    }

    // MARK: - Provenance & manual edits (FR-3.3, FR-3.7)

    func provenance(for bookId: Int64) -> [String: ProvenanceSource] {
        (try? database.provenance(forBook: bookId)) ?? [:]
    }

    struct ManualEdits: Sendable {
        var title: String
        var authors: String        // comma-separated in the form
        var series: String
        var seriesIndex: String
        var publisher: String
        var year: String
        var language: String
        var isbn: String
        var tags: String           // comma-separated
        var description: String

        init(book: Book) {
            title = book.title
            authors = book.authors.joined(separator: ", ")
            series = book.series ?? ""
            seriesIndex = book.seriesIndex.map {
                $0.truncatingRemainder(dividingBy: 1) == 0 ? String(Int($0)) : String($0)
            } ?? ""
            publisher = book.publisher ?? ""
            year = book.year.map(String.init) ?? ""
            language = book.language ?? ""
            isbn = book.isbn13 ?? book.isbn10 ?? ""
            tags = book.tags.joined(separator: ", ")
            description = book.bookDescription ?? ""
        }
    }

    /// Saves user edits; every changed field gets `.manual` provenance so no
    /// later automatic pass can overwrite it (FR-3.2).
    func saveManualEdits(_ edits: ManualEdits, bookId: Int64) async {
        do {
            try await database.writer.write { db in
                guard var book = try Book.fetchOne(db, key: bookId) else { return }
                var changed: [String] = []

                func splitList(_ raw: String) -> [String] {
                    raw.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }

                let title = edits.title.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty, title != book.title {
                    book.title = title
                    book.titleSort = Book.sortKey(forTitle: title)
                    changed.append("title")
                }
                let authors = splitList(edits.authors)
                if authors != book.authors {
                    book.authors = authors
                    book.authorSort = Book.sortKey(forAuthors: authors)
                    changed.append("authors")
                }
                let series = edits.series.trimmingCharacters(in: .whitespaces)
                if (series.isEmpty ? nil : series) != book.series {
                    book.series = series.isEmpty ? nil : series
                    changed.append("series")
                }
                let seriesIndex = Double(edits.seriesIndex.trimmingCharacters(in: .whitespaces))
                if seriesIndex != book.seriesIndex {
                    book.seriesIndex = seriesIndex
                    if !changed.contains("series") { changed.append("series") }
                }
                let publisher = edits.publisher.trimmingCharacters(in: .whitespaces)
                if (publisher.isEmpty ? nil : publisher) != book.publisher {
                    book.publisher = publisher.isEmpty ? nil : publisher
                    changed.append("publisher")
                }
                let year = Int(edits.year.trimmingCharacters(in: .whitespaces))
                if year != book.year {
                    book.year = year
                    changed.append("year")
                }
                let language = edits.language.trimmingCharacters(in: .whitespaces)
                if (language.isEmpty ? nil : language) != book.language {
                    book.language = language.isEmpty ? nil : language
                    changed.append("language")
                }
                let isbnRaw = edits.isbn.trimmingCharacters(in: .whitespaces)
                let isbn = isbnRaw.isEmpty ? nil : (Normalizer.extractISBN(isbnRaw) ?? isbnRaw)
                if isbn != (book.isbn13 ?? book.isbn10) {
                    if let isbn, isbn.count == 10 {
                        book.isbn10 = isbn
                        book.isbn13 = nil
                    } else {
                        book.isbn13 = isbn
                        book.isbn10 = nil
                    }
                    changed.append("isbn")
                }
                let tags = splitList(edits.tags)
                if tags != book.tags {
                    book.tags = tags
                    changed.append("tags")
                }
                let description = edits.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if (description.isEmpty ? nil : description) != book.bookDescription {
                    book.bookDescription = description.isEmpty ? nil : description
                    changed.append("description")
                }

                guard !changed.isEmpty else { return }
                book.metadataStatus = ScanPipeline.status(for: book)
                book.updatedAt = Date()
                try book.update(db)
                for field in changed {
                    try ProvenanceRecord(bookId: bookId, field: field, source: .manual).save(db)
                }
            }
        } catch {
            errorMessage = "Saving edits failed: \(error.localizedDescription)"
        }
    }

    /// Replaces the cover from a user-chosen image file (.manual provenance).
    func replaceCover(bookId: Int64) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        Task {
            do {
                let coverCache = self.coverCache
                let gridURL = try coverCache.store(imageData: data, bookId: bookId)
                try await database.writer.write { db in
                    guard var book = try Book.fetchOne(db, key: bookId) else { return }
                    book.coverCachePath = gridURL.path
                    book.metadataStatus = ScanPipeline.status(for: book)
                    book.updatedAt = Date()
                    try book.update(db)
                    try ProvenanceRecord(bookId: bookId, field: "cover", source: .manual).save(db)
                }
                CoverImageLoader.shared.invalidate(path: gridURL.path)
            } catch {
                errorMessage = "Replacing cover failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Settings access

    func settingValue(_ key: String, default defaultValue: String = "") -> String {
        ((try? database.setting(key)) ?? nil) ?? defaultValue
    }

    func setSettingValue(_ key: String, _ value: String) {
        try? database.setSetting(key, value.isEmpty ? nil : value)
    }

    var renameTemplateRaw: String {
        settingValue("renameTemplate", default: RenameTemplate.defaultRaw)
    }

    var ignoredExtensions: Set<String> {
        Set(settingValue("ignoreList")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    // MARK: - Rename (FR-4)

    /// Builds the plan and opens the mandatory preview sheet (FR-4.6).
    func prepareRename(ids: [Int64]) {
        do {
            let template = try RenameTemplate.parse(renameTemplateRaw)
            let chosen = items.filter { ids.contains($0.id) }
            let plan = RenamePlanner.plan(
                items: chosen.map { ($0.book, $0.files) },
                template: template)
            guard !plan.isEmpty else { return }
            renamePlan = plan
        } catch {
            errorMessage = "Rename template is invalid: \(error)"
        }
    }

    func executeRename() async {
        guard let plan = renamePlan else { return }
        renamePlan = nil
        do {
            let result = try await RenameExecutor.execute(plan: plan, database: database)
            var parts = ["\(result.renamed) renamed"]
            if result.skipped > 0 { parts.append("\(result.skipped) skipped") }
            if !result.failures.isEmpty { parts.append("\(result.failures.count) failed") }
            lastRenameSummary = parts.joined(separator: " · ")
            await refreshUndoState()
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    func refreshUndoState() async {
        undoableBatch = try? await RenameExecutor.lastUndoableBatch(database: database)
            .map { ($0.batchId, $0.entries) }
    }

    func undoLastRename() async {
        do {
            let restored = try await RenameExecutor.undoLastBatch(database: database)
            lastRenameSummary = "Undo restored \(restored) file\(restored == 1 ? "" : "s")"
            await refreshUndoState()
        } catch {
            errorMessage = "Undo failed: \(error.localizedDescription)"
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
