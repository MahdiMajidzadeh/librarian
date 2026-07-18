import SwiftUI
import BookShelfKit

/// Inspector content while several books are selected: shows what's in the
/// selection and offers the group action directly, so multi-select never
/// feels like the detail panel "closing".
@MainActor
struct MultiSelectionPanel: View {
    @Environment(AppModel.self) private var model

    private var selected: [BookListItem] {
        model.items.filter { model.selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(selected.count) Books Selected")
                .font(.headline)

            Text("⌘-click to add or remove books.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    Task { await model.mergeSelection() }
                } label: {
                    Label("Merge into One Book", systemImage: "arrow.triangle.merge")
                }
                .help("Group these as one book with a badge per format. The entry with the most complete metadata keeps its details.")

                Button {
                    Task { await model.resolveMetadata(ids: Array(model.selection)) }
                } label: {
                    Label("Resolve Online", systemImage: "globe")
                }
                .disabled(model.isResolving)
            }
            .controlSize(.small)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(selected) { item in
                        HStack(spacing: 8) {
                            CoverView(path: item.book.coverCachePath, title: item.book.title)
                                .frame(width: 26, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.book.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(item.formats.map { $0.rawValue.uppercased() }.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
