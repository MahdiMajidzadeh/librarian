import SwiftUI
import LibrarianKit

/// Table view (FR-6.1): title, author, formats, year, size, status columns.
/// Sorting is driven by the shared sort controls in the filter bar, so grid
/// and table stay consistent.
struct LibraryTableView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Table(model.visibleEntries, selection: $model.selection) {
            TableColumn("Title") { entry in
                HStack(spacing: 6) {
                    Text(entry.book.title)
                        .foregroundStyle(entry.allFilesMissing ? .secondary : .primary)
                    StatusChips(entry: entry)
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Author") { entry in
                Text(entry.book.authors.joined(separator: ", "))
            }
            .width(min: 120, ideal: 200)

            TableColumn("Formats") { entry in
                FormatBadges(formats: entry.formats)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Year") { entry in
                Text(entry.book.year.map(String.init) ?? "—")
                    .monospacedDigit()
            }
            .width(52)

            TableColumn("Size") { entry in
                Text(ByteCountFormatter.string(
                    fromByteCount: entry.totalSizeBytes, countStyle: .file))
                    .monospacedDigit()
            }
            .width(76)

            TableColumn("Status") { entry in
                Text(entry.book.metadataStatus.rawValue.capitalized)
                    .foregroundStyle(entry.book.metadataStatus == .complete
                        ? Color.secondary : Color.orange)
            }
            .width(84)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let entry = model.entries.first(where: { $0.id == id }) {
                EntryContextMenu(entry: entry)
            }
        } primaryAction: { ids in
            if let id = ids.first, let entry = model.entries.first(where: { $0.id == id }) {
                model.openSelected(entry: entry)
            }
        }
    }
}
