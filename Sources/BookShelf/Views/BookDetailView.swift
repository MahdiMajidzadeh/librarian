import SwiftUI
import BookShelfKit

/// Detail pane: metadata, status, and the underlying files with per-file
/// actions (FR-2.3), plus split (FR-2.4).
@MainActor
struct BookDetailView: View {
    @Environment(AppModel.self) private var model
    let item: BookListItem

    @State private var provenance: [String: ProvenanceSource] = [:]
    @State private var showEditSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionRow
                Divider()
                metadataGrid
                if let description = item.book.bookDescription {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }
                if !item.book.tags.isEmpty {
                    tagRow
                }
                Divider()
                filesSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: item.id) {
            provenance = model.provenance(for: item.id)
        }
        .task(id: item.book.updatedAt) {
            provenance = model.provenance(for: item.id)
        }
        .sheet(isPresented: $showEditSheet) {
            BookEditSheet(item: item)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.resolveMetadata(ids: [item.id]) }
            } label: {
                Label("Resolve Online", systemImage: "globe")
            }
            .disabled(model.isResolving)
            .help("Look up metadata and cover on Open Library / Google Books")

            Button {
                showEditSheet = true
            } label: {
                Label("Edit…", systemImage: "pencil")
            }

            if item.files.count > 1 {
                Button {
                    Task { await model.ungroup(bookId: item.id) }
                } label: {
                    Label("Ungroup", systemImage: "square.split.diagonal")
                }
                .help("Split every file of this book into its own entry — use when files were grouped wrongly")
            }
        }
        .controlSize(.small)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverView(path: item.book.coverCachePath, title: item.book.title)
                .frame(width: 90, height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .shadow(radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.book.title)
                    .font(.title3.weight(.semibold))
                if !item.book.authors.isEmpty {
                    Text(item.book.authors.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                if let series = item.book.series {
                    Text(seriesLabel(series))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                FormatBadges(formats: item.formats)
                    .padding(.top, 2)
                statusLine
            }
        }
    }

    private func seriesLabel(_ series: String) -> String {
        if let index = item.book.seriesIndex {
            let formatted = index.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(index)) : String(index)
            return "\(series) #\(formatted)"
        }
        return series
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch item.book.metadataStatus {
            case .complete:
                Label("Complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .partial:
                Label("Partial metadata", systemImage: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
            case .unresolved:
                Label(item.book.parseErrorNote ?? "Unresolved", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            if item.isAutoGrouped {
                Label("Auto-grouped", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
                    .help("Grouped by filename similarity only — split if wrong")
            }
        }
        .font(.caption)
    }

    private var metadataGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            metadataRow("Title", item.book.title, field: "title")
            metadataRow("Authors", item.book.authors.joined(separator: ", "), field: "authors")
            metadataRow("Publisher", item.book.publisher, field: "publisher")
            metadataRow("Year", item.book.year.map(String.init), field: "year")
            metadataRow("Language", item.book.language, field: "language")
            metadataRow("ISBN-13", item.book.isbn13, field: "isbn")
            metadataRow("ISBN-10", item.book.isbn10, field: "isbn")
        }
        .font(.callout)
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String?, field: String) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                HStack(spacing: 6) {
                    Text(value)
                        .textSelection(.enabled)
                    if let source = provenance[field] {
                        ProvenanceTag(source: source)
                    }
                }
            }
        }
    }

    private var tagRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(item.book.tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files")
                .font(.headline)
            ForEach(item.files, id: \.path) { file in
                FileRow(file: file, canSplit: item.files.count > 1)
            }
        }
    }
}

/// Left-to-right wrapping layout for chip rows — a paragraph-length tag can
/// never stretch a chip vertically the way an HStack + multiline Text could.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, slot) in arrangement.slots.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + slot.origin.x, y: bounds.minY + slot.origin.y),
                proposal: ProposedViewSize(width: slot.width, height: slot.height))
        }
    }

    private func arrange(
        maxWidth: CGFloat, subviews: Subviews
    ) -> (slots: [(origin: CGPoint, width: CGFloat, height: CGFloat)], size: CGSize) {
        var slots: [(origin: CGPoint, width: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            // A single chip wider than the container truncates instead of
            // overflowing the row.
            let width = min(ideal.width, maxWidth)
            if x > 0, x + width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            slots.append((CGPoint(x: x, y: y), width, ideal.height))
            x += width + spacing
            rowHeight = max(rowHeight, ideal.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (slots, CGSize(width: usedWidth, height: y + rowHeight))
    }
}

/// Field-level provenance chip (FR-3.3): where a value came from.
@MainActor
struct ProvenanceTag: View {
    let source: ProvenanceSource

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .help("Source: \(label)")
    }

    private var label: String {
        switch source {
        case .embedded: return "embedded"
        case .openLibrary: return "open library"
        case .googleBooks: return "google books"
        case .manual: return "manual"
        case .filename: return "filename"
        }
    }

    private var color: Color {
        switch source {
        case .manual: return .purple
        case .embedded: return .blue
        case .openLibrary, .googleBooks: return .teal
        case .filename: return .gray
        }
    }
}

@MainActor
private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: BookFile
    let canSplit: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.missingFlag {
                        Text("missing")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(file.format.rawValue.uppercased()) · \(file.sizeBytes.formattedFileSize) · \(file.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    model.openFile(file)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Open with the default app")
                .disabled(file.missingFlag)

                Button {
                    model.revealInFinder(file)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Reveal in Finder")
                .disabled(file.missingFlag)

                if canSplit {
                    Button {
                        Task { await model.split(fileId: file.id ?? -1) }
                    } label: {
                        Image(systemName: "square.split.diagonal")
                    }
                    .help("Split this file into its own book")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        .opacity(file.missingFlag ? 0.6 : 1)
    }
}
