import SwiftUI
import BookShelfKit

@MainActor
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.libraryFolder == nil {
                emptyState
            } else {
                libraryView
            }
        }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if let progress = model.scanProgress {
                ScanProgressBar(progress: progress)
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
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
            if let folder = model.libraryFolder {
                Text(folder.lastPathComponent)
                    .foregroundStyle(.secondary)
            }
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

            Picker("View", selection: viewModeBinding) {
                Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                Label("Table", systemImage: "list.bullet").tag(ViewMode.table)
            }
            .pickerStyle(.segmented)
        }
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
