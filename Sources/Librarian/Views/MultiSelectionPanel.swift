import SwiftUI
import LibrarianKit

/// Sidebar content when several books are selected (FR-6.5): bulk actions —
/// resolve metadata, rename, export selection, merge into one book.
struct MultiSelectionPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.selection.count) books selected")
                    .font(.title3.weight(.semibold))
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    model.resolveOnline(entryIds: Array(model.selection))
                } label: {
                    Label("Resolve Metadata Online", systemImage: "network")
                }
                Button {
                    model.prepareRename()
                } label: {
                    Label("Rename Files…", systemImage: "character.cursor.ibeam")
                }
                Button {
                    model.mergeSelection()
                } label: {
                    Label("Merge Into One Book", systemImage: "arrow.triangle.merge")
                }
                .help("Combine the selected books into a single entry; this choice persists across rescans")
                Divider()
                Button {
                    model.exportJSON(selectionOnly: true)
                } label: {
                    Label("Export Selection as JSON…", systemImage: "square.and.arrow.up")
                }
                Button {
                    model.exportCSV(selectionOnly: true)
                } label: {
                    Label("Export Selection as CSV…", systemImage: "tablecells")
                }
            }
            .buttonStyle(.link)

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var summaryLine: String {
        let entries = model.selectedEntries
        let fileCount = entries.reduce(0) { $0 + $1.files.count }
        let size = entries.reduce(Int64(0)) { $0 + $1.totalSizeBytes }
        return "\(fileCount) files · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }
}
