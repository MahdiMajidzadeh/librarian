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
        self.watchFolderEnabled = (try? self.database.setting("watchFolder")) == "1"
        if let raw = try? self.database.setting("viewMode"), let mode = ViewMode(rawValue: raw) {
            self.viewMode = mode
        }
        startObservation()
        Task { await refreshUndoState() }
        restartFolderWatcher()
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
            restartFolderWatcher()
            let rootPath = url.standardizedFileURL.path
            Task {
                // Files from a previously chosen folder are no longer part of
                // this library — flag them missing (the scanner only diffs
                // under the current root) so Purge Missing can remove them.
                try? await database.writer.write { db in
                    let outside = try BookFile.fetchAll(db).filter {
                        !$0.missingFlag && !$0.path.hasPrefix(rootPath + "/")
                    }
                    for var file in outside {
                        file.missingFlag = true
                        try file.update(db)
                    }
                }
                await self.scan()
            }
        } catch {
            errorMessage = "Could not save folder access: \(error.localizedDescription)"
        }
    }

    var isScanning: Bool {
        if let progress = scanProgress, progress.phase != .finished { return true }
        return false
    }

    /// Progress callbacks hop to the main actor via unstructured Tasks; a
    /// late-arriving one must not resurrect progress after the reset (which
    /// would leave `isScanning` stuck true). Bumping the generation at start
    /// and at reset invalidates stragglers from the previous run.
    private var scanGeneration = 0

    /// Set when the folder watcher fires mid-scan — handled when the current
    /// scan finishes instead of being dropped.
    private var rescanPending = false

    func scan() async {
        Self.logAction("scan folder=\(libraryFolder?.lastPathComponent ?? "nil") isScanning=\(isScanning)")
        guard let root = libraryFolder, !isScanning else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanProgress = ScanProgress(phase: .enumerating, processed: 0, total: 0)
        let pipeline = ScanPipeline(database: database, coverCache: coverCache)
        do {
            let result = try await pipeline.scan(root: root, ignoredExtensions: ignoredExtensions) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.scanProgress = progress
                }
            }
            lastScanResult = result
        } catch {
            errorMessage = "Scan failed: \(error.localizedDescription)"
        }
        scanGeneration += 1
        scanProgress = nil
        if rescanPending {
            rescanPending = false
            Task { await self.scan() }
        }
    }

    // MARK: - Folder watching (FR-1.6, P1)

    private(set) var watchFolderEnabled = false
    private var folderWatcher: FolderWatcher?

    func setWatchFolder(_ enabled: Bool) {
        watchFolderEnabled = enabled
        try? database.setSetting("watchFolder", enabled ? "1" : "0")
        restartFolderWatcher()
    }

    /// Called at launch (after init) and whenever the folder or toggle changes.
    func restartFolderWatcher() {
        folderWatcher?.stop()
        folderWatcher = nil
        guard watchFolderEnabled, let root = libraryFolder else { return }
        let watcher = FolderWatcher { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't drop changes that land mid-scan (e.g. files still
                // being copied in) — queue one follow-up scan instead.
                if self.isScanning {
                    self.rescanPending = true
                } else {
                    await self.scan()
                }
            }
        }
        watcher.start(watching: root)
        folderWatcher = watcher
    }

    /// Re-reads embedded metadata from every present file (fill-empty; covers
    /// upgrade per source ranking). Useful after parser improvements — normal
    /// rescans skip unchanged files.
    func reextractMetadata() async {
        Self.logAction("reextractMetadata isScanning=\(isScanning)")
        guard !isScanning else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanProgress = ScanProgress(phase: .processing, processed: 0, total: 0)
        let pipeline = ScanPipeline(database: database, coverCache: coverCache)
        do {
            let count = try await pipeline.reextractEmbedded { done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.scanProgress = ScanProgress(phase: .processing, processed: done, total: total)
                }
            }
            lastResolveSummary = "Re-extracted embedded metadata from \(count) files"
        } catch {
            errorMessage = "Re-extract failed: \(error.localizedDescription)"
        }
        scanGeneration += 1
        scanProgress = nil
    }

    /// Re-partitions automatic groups with the current rules (manual
    /// merges/splits untouched; unchanged groups keep their book rows).
    func rebuildGroups() async {
        Self.logAction("rebuildGroups isScanning=\(isScanning)")
        guard !isScanning else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanProgress = ScanProgress(phase: .processing, processed: 0, total: 0)
        let pipeline = ScanPipeline(database: database, coverCache: coverCache)
        do {
            let summary = try await pipeline.rebuildGroups { done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.scanProgress = ScanProgress(phase: .processing, processed: done, total: total)
                }
            }
            lastResolveSummary =
                "Regrouped: \(summary.groupsKept) kept, \(summary.booksRebuilt) rebuilt, \(summary.booksDissolved) removed"
        } catch {
            errorMessage = "Rebuild groups failed: \(error.localizedDescription)"
        }
        scanGeneration += 1
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

        // Descending swaps the operands rather than negating `<` — negation
        // returns true for equal keys, which violates strict weak ordering
        // (undefined sort behavior once ties exist, e.g. many nil years).
        // Ties fall back to the title so the order is deterministic.
        result.sort { first, second in
            let (a, b) = sortAscending ? (first, second) : (second, first)
            switch sortKey {
            case .title:
                break
            case .author:
                let x = a.book.authorSort ?? "~", y = b.book.authorSort ?? "~"
                if x != y { return x < y }
            case .year:
                let x = a.book.year ?? Int.min, y = b.book.year ?? Int.min
                if x != y { return x < y }
            case .dateAdded:
                if a.book.createdAt != b.book.createdAt { return a.book.createdAt < b.book.createdAt }
            case .size:
                if a.totalSizeBytes != b.totalSizeBytes { return a.totalSizeBytes < b.totalSizeBytes }
            }
            return a.book.titleSort < b.book.titleSort
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

    // MARK: - Action log

    /// Appends one line per user action to Application Support/BookShelf/
    /// actions.log — the first thing to read when someone reports a control
    /// "doing nothing".
    nonisolated static func logAction(_ name: String) {
        guard let dir = try? AppDatabase.defaultURL().deletingLastPathComponent() else { return }
        let url = dir.appendingPathComponent("actions.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(name)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Merge / split (FR-2.4)

    private(set) var lastGroupSummary: String?

    func mergeSelection() async {
        Self.logAction("mergeSelection count=\(selection.count)")
        let ids = Array(selection)
        guard ids.count >= 2 else { return }
        // Target: the entry with the most complete metadata.
        let ranked = selectedItems.sorted { a, b in
            rank(a.book.metadataStatus) > rank(b.book.metadataStatus)
        }
        guard let targetItem = ranked.first else { return }
        let target = targetItem.id
        let sources = ids.filter { $0 != target }
        do {
            try await database.writer.write { db in
                try GroupingOperations.merge(db, sourceIds: sources, into: target)
            }
            selection = [target]
            // Merging makes the book a manual group; under the Auto-grouped
            // filter it leaves the visible list — say so, or it reads as
            // the books disappearing.
            var note = "Merged \(ids.count) books into “\(targetItem.book.title)”"
            if activeFilters.contains(.autoGrouped) {
                note += " — now hidden by the Auto-grouped filter"
            }
            lastGroupSummary = note
        } catch {
            errorMessage = "Merge failed: \(error.localizedDescription)"
        }
    }

    /// Dissolves a whole group: every file becomes its own book.
    func ungroup(bookId: Int64) async {
        Self.logAction("ungroup book=\(bookId)")
        let title = items.first { $0.id == bookId }?.book.title ?? "book"
        do {
            let newIds = try await database.writer.write { db in
                try GroupingOperations.ungroup(db, bookId: bookId)
            }
            selection = [bookId]
            var note = "Ungrouped “\(title)” into \(newIds.count + 1) books"
            if activeFilters.contains(.autoGrouped) {
                note += " — now hidden by the Auto-grouped filter"
            }
            lastGroupSummary = note
        } catch {
            errorMessage = "Ungroup failed: \(error.localizedDescription)"
        }
    }

    func split(fileId: Int64) async {
        Self.logAction("split file=\(fileId)")
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

    private var resolveGeneration = 0

    func resolveMetadata(ids: [Int64]) async {
        guard !ids.isEmpty, !isResolving else { return }
        let service = makeLookupService()
        resolveGeneration += 1
        let generation = resolveGeneration
        resolveProgress = (0, ids.count)
        let outcome = await service.resolveBatch(bookIds: ids, policy: applyPolicy) { done, total in
            Task { @MainActor [weak self] in
                guard let self, self.resolveGeneration == generation else { return }
                self.resolveProgress = (done, total)
            }
        }
        resolveGeneration += 1
        resolveProgress = nil

        // Queue ambiguous books for the candidate picker (FR-3.4).
        for (bookId, candidates) in outcome.ambiguous.sorted(by: { $0.key < $1.key }) {
            let title = items.first { $0.id == bookId }?.book.title ?? "Book \(bookId)"
            pickerQueue.append(PickerRequest(id: bookId, bookTitle: title, candidates: candidates))
        }
        // Don't clobber a picker sheet the user currently has open (possible
        // when resolving from a second window); the queue drains as the open
        // one is answered.
        if pendingPicker == nil {
            advancePicker()
        }

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

    /// Clears the cover cache AND detaches every book from its now-deleted
    /// cover file. Leaving the dangling paths in place would keep their
    /// cover rank, silently blocking re-extraction from ever restoring a
    /// cover; clearing the provenance rows lets embedded covers re-apply.
    func clearCoverCache() async {
        Self.logAction("clearCoverCache")
        do {
            try coverCache.clear()
            try await database.writer.write { db in
                let books = try Book.fetchAll(db).filter { $0.coverCachePath != nil }
                for var book in books {
                    book.coverCachePath = nil
                    book.coverSourceFormat = nil
                    book.metadataStatus = ScanPipeline.status(for: book)
                    book.updatedAt = Date()
                    try book.update(db)
                }
                try ProvenanceRecord
                    .filter(ProvenanceRecord.Columns.field == "cover")
                    .deleteAll(db)
            }
        } catch {
            errorMessage = "Clearing cover cache failed: \(error.localizedDescription)"
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

    // MARK: - Export (FR-5)

    private(set) var exportProgress: (done: Int, total: Int)?
    private(set) var lastExportSummary: String?
    private var exportGeneration = 0

    enum ExportKind {
        case json(includeCovers: Bool)
        case csv(mode: CSVExporter.Mode = .perBook)
    }

    /// Export scope (FR-5.1): the selection when present, otherwise the
    /// current filter result.
    private var exportBookIds: [Int64] {
        selection.isEmpty ? displayedItems.map(\.id) : Array(selection)
    }

    func export(_ kind: ExportKind) async {
        let ids = exportBookIds
        guard !ids.isEmpty else { return }

        let panel = NSSavePanel()
        switch kind {
        case .json:
            panel.nameFieldStringValue = "library.json"
        case .csv:
            panel.nameFieldStringValue = "library.csv"
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        exportGeneration += 1
        let generation = exportGeneration
        exportProgress = (0, ids.count)
        defer {
            exportGeneration += 1
            exportProgress = nil
        }
        do {
            let records = try await ExportRecord.fetch(from: database, bookIds: ids)
            let progress: @Sendable (Int, Int) -> Void = { done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.exportGeneration == generation else { return }
                    self.exportProgress = (done, total)
                }
            }
            let coverCache = self.coverCache
            let delimiter = settingValue("csvDelimiter", default: ",")
            let separator = settingValue("csvMultiValueSeparator", default: "; ")
            try await Task.detached(priority: .userInitiated) {
                switch kind {
                case .json(let includeCovers):
                    try JSONExporter.export(
                        records: records, to: url,
                        includeCovers: includeCovers, coverCache: coverCache,
                        onProgress: progress)
                case .csv(let mode):
                    try CSVExporter.export(
                        records: records, to: url,
                        options: .init(delimiter: delimiter, multiValueSeparator: separator, mode: mode),
                        onProgress: progress)
                }
            }.value
            lastExportSummary = "Exported \(records.count) books to \(url.lastPathComponent)"
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
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
