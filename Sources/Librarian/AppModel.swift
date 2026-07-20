import AppKit
import Foundation
import SwiftUI
import LibrarianKit

/// One row of the library list: a logical book plus its files.
struct LibraryEntry: Identifiable, Hashable {
    var book: Book
    var files: [BookFile]

    var id: Int64 { book.id ?? -1 }
    var formats: [BookFormat] {
        Array(Set(files.map(\.format))).sorted { $0.rawValue < $1.rawValue }
    }
    /// User deviation: filter for groups holding >1 file of the same format.
    var hasDuplicateFormats: Bool {
        Dictionary(grouping: files, by: \.format).values.contains { $0.count > 1 }
    }
    var hasMissingFiles: Bool { files.contains(where: \.missingFlag) }
    var allFilesMissing: Bool { !files.isEmpty && files.allSatisfy(\.missingFlag) }
    var totalSizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    var isAutoGrouped: Bool { book.groupMethod == .filename }
}

enum ViewMode: String, CaseIterable {
    case grid, table
}

enum SortField: String, CaseIterable, Identifiable {
    case title = "Title"
    case author = "Author"
    case year = "Year"
    case dateAdded = "Date Added"
    case fileSize = "File Size"

    var id: String { rawValue }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case complete = "Complete"
    case partial = "Partial"
    case unresolved = "Unresolved"

    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    // Kit services.
    let database: AppDatabase
    let coverCache: CoverCache
    let pipeline: ScanPipeline
    let lookup: LookupService
    let groupCommands: GroupCommands
    let renameExecutor: RenameExecutor
    private var watcher: FolderWatcher?

    // Library state.
    @Published var entries: [LibraryEntry] = []
    @Published var libraryPath: String?
    @Published var selection = Set<Int64>()

    // View state.
    @Published var viewMode: ViewMode = .grid
    @Published var searchText = ""
    @Published var sortField: SortField = .title
    @Published var sortAscending = true
    @Published var formatFilter: BookFormat?
    @Published var statusFilter: StatusFilter = .all
    @Published var missingOnlyFilter = false
    @Published var autoGroupedFilter = false
    @Published var duplicateFormatFilter = false

    // Activity state.
    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?
    @Published var lookupProgress: (done: Int, total: Int)?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    // Sheets.
    @Published var candidatePicker: CandidatePickerState?
    @Published var renamePlanRows: [RenamePlanRow]?
    @Published var editingBook: Book?

    struct CandidatePickerState: Identifiable {
        var id: Int64 { entry.id }
        var entry: LibraryEntry
        var candidates: [LookupCandidate]
        /// Remaining book ids when the picker runs inside a batch resolve.
        var remainingQueue: [Int64] = []
    }

    init() {
        do {
            let database = try AppDatabase.onDisk()
            let coverCache = try CoverCache.standard()
            self.database = database
            self.coverCache = coverCache
            self.pipeline = ScanPipeline(
                scanner: LibraryScanner(database: database, coverCache: coverCache))
            self.lookup = LookupService(database: database, coverCache: coverCache)
            self.groupCommands = GroupCommands(database: database, coverCache: coverCache)
            self.renameExecutor = RenameExecutor(database: database)
        } catch {
            fatalError("Cannot open the Librarian database: \(error)")
        }
        libraryPath = try? database.setting(SettingKey.libraryPath)
        reload()
        startWatcherIfPossible()
    }

    // MARK: - Library loading

    func reload() {
        do {
            entries = try database.fetchLibrary().map { LibraryEntry(book: $0.book, files: $0.files) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Entries after search, filters, and sort (§6.6).
    var visibleEntries: [LibraryEntry] {
        var result = entries

        if !searchText.isEmpty {
            let needle = Normalizer.key(searchText)
            result = result.filter { entry in
                var haystack = [entry.book.title]
                haystack.append(contentsOf: entry.book.authors)
                if let series = entry.book.series { haystack.append(series) }
                if let isbn = entry.book.isbn13 { haystack.append(isbn) }
                if let isbn = entry.book.isbn10 { haystack.append(isbn) }
                haystack.append(contentsOf: entry.files.map(\.filename))
                return haystack.contains { Normalizer.key($0).contains(needle) }
            }
        }
        if let format = formatFilter {
            result = result.filter { $0.formats.contains(format) }
        }
        switch statusFilter {
        case .all: break
        case .complete: result = result.filter { $0.book.metadataStatus == .complete }
        case .partial: result = result.filter { $0.book.metadataStatus == .partial }
        case .unresolved: result = result.filter { $0.book.metadataStatus == .unresolved }
        }
        if missingOnlyFilter {
            result = result.filter(\.hasMissingFiles)
        }
        if autoGroupedFilter {
            result = result.filter(\.isAutoGrouped)
        }
        if duplicateFormatFilter {
            result = result.filter(\.hasDuplicateFormats)
        }

        result.sort { a, b in
            let ordered: Bool
            switch sortField {
            case .title:
                ordered = a.book.titleSort < b.book.titleSort
            case .author:
                ordered = (a.book.authorSort, a.book.titleSort) < (b.book.authorSort, b.book.titleSort)
            case .year:
                ordered = (a.book.year ?? 0, a.book.titleSort) < (b.book.year ?? 0, b.book.titleSort)
            case .dateAdded:
                ordered = a.book.createdAt < b.book.createdAt
            case .fileSize:
                ordered = a.totalSizeBytes < b.totalSizeBytes
            }
            return sortAscending ? ordered : !ordered
        }
        return result
    }

    var selectedEntries: [LibraryEntry] {
        visibleEntries.filter { selection.contains($0.id) }
    }

    var singleSelection: LibraryEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return entries.first { $0.id == id }
    }

    // MARK: - Folder & scan

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose your books folder. Files are read in place and never moved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FolderAccess.persist(url, in: database)
            libraryPath = url.path
            startWatcherIfPossible()
            scan()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scan() {
        guard !isScanning else { return }
        let resolved: FolderAccess.Resolved?
        do {
            resolved = try FolderAccess.resolve(from: database)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard let resolved else {
            chooseLibraryFolder()
            return
        }

        isScanning = true
        scanProgress = ScanProgress(processed: 0, total: 0)
        pipeline.requestScan(
            root: resolved.url,
            progress: { progress in
                Task { @MainActor [weak self] in
                    self?.scanProgress = progress
                }
            },
            completion: { result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    resolved.stopAccessing()
                    self.isScanning = false
                    self.scanProgress = nil
                    switch result {
                    case .success(let summary):
                        self.statusMessage = String(
                            format: "Scan finished: %d added, %d updated, %d missing (%.1fs)",
                            summary.added, summary.updated, summary.markedMissing,
                            summary.duration)
                        self.reload()
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            })
    }

    private func startWatcherIfPossible() {
        watcher?.stop()
        watcher = nil
        guard let path = libraryPath else { return }
        let watcher = FolderWatcher { [weak self] in
            Task { @MainActor in
                self?.scan()
            }
        }
        watcher.start(watching: URL(fileURLWithPath: path))
        self.watcher = watcher
    }

    func purgeMissing() {
        do {
            try database.purgeMissingFiles()
            reload()
            statusMessage = "Missing entries purged"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Metadata lookup (explicit, FR-3.1)

    func resolveOnline(entryIds: [Int64]) {
        guard lookupProgress == nil else { return }
        lookupProgress = (0, entryIds.count)
        Task {
            var queue = entryIds
            var done = 0
            while let bookId = queue.first {
                queue.removeFirst()
                let outcome = await lookup.resolve(bookId: bookId)
                done += 1
                lookupProgress = (done, entryIds.count)
                switch outcome {
                case .applied:
                    reload()
                case .noMatch:
                    statusMessage = "No online match found"
                case .failed(let message):
                    errorMessage = message
                case .needsConfirmation(let candidates):
                    if let entry = entries.first(where: { $0.id == bookId }) {
                        // Ambiguous: open the picker; the rest of the batch
                        // continues after the user decides (FR-3.4).
                        candidatePicker = CandidatePickerState(
                            entry: entry, candidates: candidates, remainingQueue: queue)
                        lookupProgress = nil
                        return
                    }
                }
            }
            lookupProgress = nil
        }
    }

    func resolveAllMissing() {
        let ids = entries
            .filter { $0.book.metadataStatus != .complete }
            .compactMap(\.book.id)
        guard !ids.isEmpty else {
            statusMessage = "Nothing to resolve — all books are complete"
            return
        }
        resolveOnline(entryIds: ids)
    }

    /// Called by the candidate picker on user confirmation.
    func applyCandidate(_ candidate: LookupCandidate, to entry: LibraryEntry) {
        let remaining = candidatePicker?.remainingQueue ?? []
        candidatePicker = nil
        Task {
            do {
                _ = try await lookup.apply(candidate: candidate, toBookId: entry.id)
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
            if !remaining.isEmpty {
                resolveOnline(entryIds: remaining)
            }
        }
    }

    func skipCandidatePicker() {
        let remaining = candidatePicker?.remainingQueue ?? []
        candidatePicker = nil
        if !remaining.isEmpty {
            resolveOnline(entryIds: remaining)
        }
    }

    // MARK: - Manual edits

    func saveManualEdits(_ edited: Book, originalBook: Book) {
        do {
            var book = edited
            var changed: [String] = []
            if book.title != originalBook.title {
                book.titleSort = Book.sortKey(forTitle: book.title)
                changed.append("title")
            }
            if book.authors != originalBook.authors {
                book.authorSort = Book.sortKey(forAuthors: book.authors)
                changed.append("authors")
            }
            if book.series != originalBook.series { changed.append("series") }
            if book.seriesIndex != originalBook.seriesIndex { changed.append("series_index") }
            if book.publisher != originalBook.publisher { changed.append("publisher") }
            if book.year != originalBook.year { changed.append("year") }
            if book.language != originalBook.language { changed.append("language") }
            if book.isbn10 != originalBook.isbn10 { changed.append("isbn10") }
            if book.isbn13 != originalBook.isbn13 { changed.append("isbn13") }
            if book.bookDescription != originalBook.bookDescription { changed.append("description") }

            book.refreshMetadataStatus()
            book.updatedAt = Date()
            try database.writer.write { db in
                try book.save(db)
            }
            if let bookId = book.id, !changed.isEmpty {
                // Manual edits win forever (FR-3.2).
                try database.recordProvenance(bookId: bookId, fields: changed, source: .manual)
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Grouping (FR-2.4 + user deviations)

    func mergeSelection() {
        let ids = selectedEntries.compactMap(\.book.id)
        guard ids.count >= 2 else { return }
        do {
            let survivor = try groupCommands.merge(bookIds: ids)
            reload()
            selection = [survivor]
            statusMessage = "Merged \(ids.count) books"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func ungroup(entry: LibraryEntry) {
        guard let bookId = entry.book.id else { return }
        do {
            let ids = try groupCommands.ungroup(bookId: bookId)
            reload()
            selection = Set(ids)
            statusMessage = "Split into \(ids.count) books"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setCover(for entry: LibraryEntry, fromFile file: BookFile) {
        guard let bookId = entry.book.id else { return }
        do {
            if try groupCommands.setCover(bookId: bookId, fromFile: file) {
                reload()
                statusMessage = "Cover updated from \(file.filename)"
            } else {
                statusMessage = "\(file.filename) has no embedded cover"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setCover(for entry: LibraryEntry, fromImageAt url: URL) {
        guard let bookId = entry.book.id else { return }
        do {
            let data = try Data(contentsOf: url)
            try groupCommands.setCover(bookId: bookId, imageData: data)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Rename (FR-4.x)

    func prepareRename() {
        let selected = selectedEntries
        guard !selected.isEmpty else { return }
        do {
            let template = try database.setting(SettingKey.renameTemplate)
                ?? RenameTemplate.defaultTemplate
            renamePlanRows = try RenamePlanner.plan(
                template: template,
                selection: selected.map { ($0.book, $0.files) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func executeRename(rows: [RenamePlanRow]) {
        renamePlanRows = nil
        do {
            let result = try renameExecutor.execute(rows: rows)
            reload()
            if result.failed.isEmpty {
                statusMessage = "Renamed \(result.renamed) files (undo available)"
            } else {
                errorMessage = "Renamed \(result.renamed), failed \(result.failed.count): "
                    + (result.failed.first?.error ?? "")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var canUndoRename: Bool {
        (try? renameExecutor.lastBatch()) != nil
    }

    func undoLastRename() {
        do {
            let result = try renameExecutor.undoLastBatch()
            reload()
            if result.failed.isEmpty {
                statusMessage = "Reverted \(result.reverted) files"
            } else {
                errorMessage = "Reverted \(result.reverted), failed \(result.failed.count)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export (FR-5.x)

    func exportJSON(selectionOnly: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "librarian-export.json"
        panel.allowedContentTypes = [.json]

        let includeCovers = NSButton(
            checkboxWithTitle: "Include cover images (covers/ folder)", target: nil, action: nil)
        panel.accessoryView = includeCovers

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = exportSource(selectionOnly: selectionOnly)
        let options = Exporters.JSONOptions(includeCovers: includeCovers.state == .on)

        Task.detached { [database, coverCache] in
            do {
                var provenance: [Int64: [String: Provenance]] = [:]
                for entry in source {
                    if let id = entry.book.id {
                        provenance[id] = try database.provenance(forBook: id)
                    }
                }
                try Exporters.exportJSON(
                    entries: source.map { ($0.book, $0.files) },
                    provenance: provenance,
                    to: url, options: options, coverCache: coverCache)
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Exported \(source.count) books to JSON"
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func exportCSV(selectionOnly: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "librarian-export.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let source = exportSource(selectionOnly: selectionOnly)
        let delimiterRaw = (try? database.setting(SettingKey.csvDelimiter)) ?? "," ?? ","
        let separator = (try? database.setting(SettingKey.csvMultiValueSeparator)) ?? "; " ?? "; "
        let options = Exporters.CSVOptions(
            delimiter: delimiterRaw == "\\t" ? "\t" : delimiterRaw,
            multiValueSeparator: separator)

        Task.detached { [weak self] in
            do {
                try Exporters.exportCSV(
                    entries: source.map { ($0.book, $0.files) }, to: url, options: options)
                Task { @MainActor in
                    self?.statusMessage = "Exported \(source.count) books to CSV"
                }
            } catch {
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// FR-5.1: entire library, or the current selection/filter result.
    private func exportSource(selectionOnly: Bool) -> [LibraryEntry] {
        if selectionOnly, !selection.isEmpty {
            return selectedEntries
        }
        return visibleEntries
    }

    // MARK: - File actions

    func open(file: BookFile) {
        NSWorkspace.shared.open(file.url)
    }

    func openSelected(entry: LibraryEntry) {
        // Double-click: open the "best" file in the default app (non-goal §3:
        // no reader view).
        if let file = entry.files.first(where: { !$0.missingFlag }) {
            open(file: file)
        }
    }

    func revealInFinder(file: BookFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func coverURL(for entry: LibraryEntry) -> URL? {
        entry.book.coverCachePath.map { coverCache.gridURL(forPath: $0) }
    }
}
