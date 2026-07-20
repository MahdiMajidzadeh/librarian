import SwiftUI
import LibrarianKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HSplitView {
            mainPane
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            // Detail sidebar is ALWAYS visible (user deviation: no layout
            // shift when selecting/deselecting).
            detailSidebar
                .frame(minWidth: 290, idealWidth: 320, maxWidth: 420)
        }
        .toolbar { toolbarContent }
        .searchable(text: $model.searchText, prompt: "Title, author, series, ISBN, filename")
        .sheet(item: $model.candidatePicker) { state in
            CandidatePickerSheet(state: state)
        }
        .sheet(isPresented: Binding(
            get: { model.renamePlanRows != nil },
            set: { if !$0 { model.renamePlanRows = nil } }
        )) {
            if let rows = model.renamePlanRows {
                RenamePreviewSheet(rows: rows)
            }
        }
        .sheet(item: $model.editingBook) { book in
            BookEditSheet(book: book)
        }
        .alert(
            "Error", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Main pane

    @ViewBuilder
    private var mainPane: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if model.libraryPath == nil {
                emptyLibraryPlaceholder
            } else if model.visibleEntries.isEmpty && !model.isScanning {
                ContentUnavailableView(
                    model.entries.isEmpty ? "No books found" : "No books match the filters",
                    systemImage: "books.vertical",
                    description: Text(model.entries.isEmpty
                        ? "Scan your library folder to populate the shelf."
                        : "Adjust search or filters."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.viewMode {
                case .grid: LibraryGridView()
                case .table: LibraryTableView()
                }
            }
            Divider()
            statusBar
        }
    }

    private var emptyLibraryPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Welcome to Librarian")
                .font(.title2)
            Text("Point Librarian at your ebooks folder. Files are cataloged\nin place — never moved or copied.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose Library Folder…") {
                model.chooseLibraryFolder()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter bar (§6.6 FR-6.3)

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Format", selection: $model.formatFilter) {
                Text("All Formats").tag(BookFormat?.none)
                ForEach(BookFormat.allCases, id: \.self) { format in
                    Text(format.badge).tag(BookFormat?.some(format))
                }
            }
            .fixedSize()

            Picker("Status", selection: $model.statusFilter) {
                ForEach(StatusFilter.allCases) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .fixedSize()

            Toggle("Missing", isOn: $model.missingOnlyFilter)
                .toggleStyle(.checkbox)
                .help("Show only books with files missing on disk")
            Toggle("Auto-grouped", isOn: $model.autoGroupedFilter)
                .toggleStyle(.checkbox)
                .help("Show only books grouped by filename similarity (review)")
            Toggle("Duplicate formats", isOn: $model.duplicateFormatFilter)
                .toggleStyle(.checkbox)
                .help("Show only books with more than one file of the same format")

            Spacer()

            Picker("Sort", selection: $model.sortField) {
                ForEach(SortField.allCases) { field in
                    Text(field.rawValue).tag(field)
                }
            }
            .fixedSize()
            Button {
                model.sortAscending.toggle()
            } label: {
                Image(systemName: model.sortAscending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help("Toggle sort direction")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let progress = model.scanProgress, model.isScanning {
                ProgressView(value: progress.total > 0
                    ? Double(progress.processed) / Double(progress.total) : 0)
                    .frame(width: 160)
                Text("Scanning \(progress.processed)/\(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let lookup = model.lookupProgress {
                ProgressView(value: lookup.total > 0
                    ? Double(lookup.done) / Double(lookup.total) : 0)
                    .frame(width: 160)
                Text("Resolving \(lookup.done)/\(lookup.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let message = model.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(model.visibleEntries.count) of \(model.entries.count) books")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !model.selection.isEmpty {
                Text("· \(model.selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: - Detail sidebar (always open)

    @ViewBuilder
    private var detailSidebar: some View {
        Group {
            if model.selection.count > 1 {
                MultiSelectionPanel()
            } else if let entry = model.singleSelection {
                BookDetailView(entry: entry)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Select a book to see its details")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .background(.background.secondary)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.scan()
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .disabled(model.libraryPath == nil || model.isScanning)
            .help("Rescan the library folder (⌘R)")

            Picker("View", selection: $model.viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                Image(systemName: "list.bullet").tag(ViewMode.table)
            }
            .pickerStyle(.segmented)
            .help("Grid or table view")

            Menu {
                Button("Resolve Metadata for Selection") {
                    model.resolveOnline(entryIds: Array(model.selection))
                }
                .disabled(model.selection.isEmpty)
                Button("Resolve All Missing Metadata") {
                    model.resolveAllMissing()
                }
                Divider()
                Button("Rename Selection…") { model.prepareRename() }
                    .disabled(model.selection.isEmpty)
                Button("Undo Last Rename Batch") { model.undoLastRename() }
                    .disabled(!model.canUndoRename)
                Divider()
                Button("Export Selection as JSON…") { model.exportJSON(selectionOnly: true) }
                    .disabled(model.selection.isEmpty)
                Button("Export Selection as CSV…") { model.exportCSV(selectionOnly: true) }
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Purge Missing Entries") { model.purgeMissing() }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }
    }
}
