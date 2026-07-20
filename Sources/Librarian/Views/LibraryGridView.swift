import SwiftUI
import LibrarianKit

/// Cover-first grid (FR-6.1) with format badges and status chips (FR-6.6).
struct LibraryGridView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(model.visibleEntries) { entry in
                    GridCell(entry: entry, isSelected: model.selection.contains(entry.id))
                        .onTapGesture(count: 2) {
                            model.openSelected(entry: entry)
                        }
                        .onTapGesture {
                            handleTap(entry)
                        }
                        .contextMenu {
                            EntryContextMenu(entry: entry)
                        }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onTapGesture {
            model.selection.removeAll()
        }
    }

    private func handleTap(_ entry: LibraryEntry) {
        if NSEvent.modifierFlags.contains(.command) {
            if model.selection.contains(entry.id) {
                model.selection.remove(entry.id)
            } else {
                model.selection.insert(entry.id)
            }
        } else if NSEvent.modifierFlags.contains(.shift),
                  let anchor = model.selection.first,
                  let anchorIndex = model.visibleEntries.firstIndex(where: { $0.id == anchor }),
                  let targetIndex = model.visibleEntries.firstIndex(where: { $0.id == entry.id }) {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            model.selection = Set(model.visibleEntries[range].map(\.id))
        } else {
            model.selection = [entry.id]
        }
    }
}

private struct GridCell: View {
    @EnvironmentObject private var model: AppModel
    let entry: LibraryEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(entry: entry)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isSelected ? Color.accentColor : .clear, lineWidth: 3))
                .opacity(entry.allFilesMissing ? 0.4 : 1)

            Text(entry.book.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            if !entry.book.authors.isEmpty {
                Text(entry.book.authors.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                FormatBadges(formats: entry.formats)
                Spacer(minLength: 0)
                StatusChips(entry: entry)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear))
        .contentShape(Rectangle())
    }
}

/// Cover image or a titled placeholder.
struct CoverView: View {
    @EnvironmentObject private var model: AppModel
    let entry: LibraryEntry
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                Text(entry.book.title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .task(id: taskKey) {
            image = await loadCover()
        }
    }

    /// Re-runs the loader when the cached cover path changes (in-place cover
    /// swaps must re-render the grid cell).
    private var taskKey: String {
        "\(entry.id)-\(entry.book.coverCachePath ?? "none")"
    }

    private func loadCover() async -> NSImage? {
        guard let url = model.coverURL(for: entry) else { return nil }
        return await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
    }
}

struct FormatBadges: View {
    let formats: [BookFormat]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(formats, id: \.self) { format in
                Text(format.badge)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }
}

/// Status chips (FR-6.6): metadata state, auto-grouped, missing files.
struct StatusChips: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: 3) {
            if entry.book.metadataStatus == .unresolved {
                chip("questionmark.circle", .orange, "Metadata unresolved")
            }
            if entry.isAutoGrouped {
                chip("link", .purple, "Auto-grouped by filename — review")
            }
            if entry.hasMissingFiles {
                chip("exclamationmark.triangle", .red, "File(s) missing on disk")
            }
            if entry.book.parseErrorNote != nil {
                chip("doc.badge.ellipsis", .gray, entry.book.parseErrorNote ?? "")
            }
        }
    }

    private func chip(_ symbol: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .help(help)
    }
}

/// Shared context menu for grid cells and table rows.
struct EntryContextMenu: View {
    @EnvironmentObject private var model: AppModel
    let entry: LibraryEntry

    var body: some View {
        Button("Open") { model.openSelected(entry: entry) }
        Button("Reveal in Finder") {
            if let file = entry.files.first(where: { !$0.missingFlag }) {
                model.revealInFinder(file: file)
            }
        }
        Divider()
        Button("Resolve Metadata Online") {
            model.resolveOnline(entryIds: [entry.id])
        }
        Button("Edit Metadata…") {
            model.editingBook = entry.book
        }
        Divider()
        if model.selection.count >= 2, model.selection.contains(entry.id) {
            Button("Merge \(model.selection.count) Books Into One") {
                model.mergeSelection()
            }
        }
        if entry.files.count >= 2 {
            Button("Ungroup — One Book per File") {
                model.ungroup(entry: entry)
            }
        }
        Divider()
        Button("Rename…") {
            if !model.selection.contains(entry.id) {
                model.selection = [entry.id]
            }
            model.prepareRename()
        }
    }
}
