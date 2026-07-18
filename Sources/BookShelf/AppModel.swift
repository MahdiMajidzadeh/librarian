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
