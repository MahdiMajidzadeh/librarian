import SwiftUI
import BookShelfKit

@MainActor
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.libraryFolder == nil {
                emptyState
            } else {
                libraryView
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar,
                    prompt: "Title, author, series, ISBN, tag, filename")
        .inspector(isPresented: detailShownBinding) {
            if let item = model.detailItem {
                BookDetailView(item: item)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
            }
        }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if let progress = model.scanProgress {
                ScanProgressBar(progress: progress)
            } else {
                statusBar
            }
        }
        .sheet(item: $model.pendingPicker) { request in
            CandidatePickerSheet(request: request)
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @MainActor
    private var detailShownBinding: Binding<Bool> {
        let model = self.model
        return Binding(
            get: { model.detailItem != nil },
            set: { if !$0 { model.selection = [] } }
        )
    }

    private var statusBar: some View {
        HStack {
            Text(statusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let summary = model.lastResolveSummary {
                Text("· \(summary)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let progress = model.resolveProgress {
                HStack(spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 120)
                    Text("Resolving \(progress.done)/\(progress.total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if !model.selection.isEmpty && !model.isResolving {
                Button("Resolve \(model.selection.count) Online") {
                    Task { await model.resolveMetadata(ids: Array(model.selection)) }
                }
                .controlSize(.small)
            }
            if model.selection.count >= 2 {
                Button("Merge \(model.selection.count) Books") {
                    Task { await model.mergeSelection() }
                }
                .controlSize(.small)
            }
            if model.items.contains(where: \.hasMissingFiles) {
                Button("Purge Missing") {
                    Task { await model.purgeMissing() }
                }
                .controlSize(.small)
                .help("Remove entries whose files no longer exist on disk")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusSummary: String {
        let total = model.items.count
        let shown = model.displayedItems.count
        let files = model.items.reduce(0) { $0 + $1.files.count }
        if shown == total {
            return "\(total) books · \(files) files"
        }
        return "\(shown) of \(total) books"
    }

    @MainActor
    private var errorBinding: Binding<Bool> {
        let model = self.model
        return Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Library Folder", systemImage: "books.vertical")
        } description: {
            Text("Point Book Shelf at your books folder. Files are read in place — nothing is moved or copied.")
        } actions: {
            Button("Choose Folder…") { model.chooseLibraryFolder() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var libraryView: some View {
        if model.items.isEmpty && !model.isScanning {
            ContentUnavailableView {
                Label("No Books Found", systemImage: "book.closed")
            } description: {
                Text("No supported book files in \(model.libraryFolder?.lastPathComponent ?? "the folder") yet.")
            } actions: {
                Button("Rescan") { Task { await model.scan() } }
            }
        } else {
            switch model.viewMode {
            case .grid: LibraryGridView()
            case .table: LibraryTableView()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.chooseLibraryFolder()
            } label: {
                Label("Choose Folder", systemImage: "folder")
            }
            .help("Choose the library folder")

            Button {
                Task { await model.scan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.libraryFolder == nil || model.isScanning)
            .help("Rescan the library folder")

            Button {
                Task { await model.resolveMetadata(ids: model.unresolvedBookIds) }
            } label: {
                Label("Resolve Missing", systemImage: "globe")
            }
            .disabled(model.unresolvedBookIds.isEmpty || model.isResolving)
            .help("Fetch metadata and covers online for all incomplete books")

            filterMenu
            sortMenu

            Picker("View", selection: viewModeBinding) {
                Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                Label("Table", systemImage: "list.bullet").tag(ViewMode.table)
            }
            .pickerStyle(.segmented)
        }
    }

    private var filterMenu: some View {
        Menu {
            Menu("Format") {
                ForEach(BookFormat.allCases, id: \.self) { format in
                    filterToggle(.format(format), label: format.rawValue.uppercased())
                }
            }
            Menu("Metadata") {
                filterToggle(.status(.complete), label: "Complete")
                filterToggle(.status(.partial), label: "Partial")
                filterToggle(.status(.unresolved), label: "Unresolved")
            }
            filterToggle(.missingOnDisk, label: "Missing on Disk")
            filterToggle(.autoGrouped, label: "Auto-grouped")
            if !model.allTags.isEmpty {
                Menu("Tag") {
                    ForEach(model.allTags, id: \.self) { tag in
                        filterToggle(.tag(tag), label: tag)
                    }
                }
            }
            if !model.activeFilters.isEmpty {
                Divider()
                Button("Clear Filters") { model.activeFilters = [] }
            }
        } label: {
            Label("Filter", systemImage: model.activeFilters.isEmpty
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter the library")
    }

    private func filterToggle(_ filter: LibraryFilter, label: String) -> some View {
        Button {
            if model.activeFilters.contains(filter) {
                model.activeFilters.remove(filter)
            } else {
                model.activeFilters.insert(filter)
            }
        } label: {
            if model.activeFilters.contains(filter) {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortKey.allCases) { key in
                Button {
                    if model.sortKey == key {
                        model.sortAscending.toggle()
                    } else {
                        model.sortKey = key
                        model.sortAscending = true
                    }
                } label: {
                    if model.sortKey == key {
                        Label(key.label, systemImage: model.sortAscending ? "chevron.up" : "chevron.down")
                    } else {
                        Text(key.label)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort the library")
    }

    private var viewModeBinding: Binding<ViewMode> {
        Binding(get: { model.viewMode }, set: { model.setViewMode($0) })
    }
}

@MainActor
struct ScanProgressBar: View {
    let progress: ScanProgress

    var body: some View {
        HStack(spacing: 12) {
            if progress.total > 0 {
                ProgressView(value: Double(progress.processed), total: Double(progress.total))
                Text("\(progress.processed) / \(progress.total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Enumerating files…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
