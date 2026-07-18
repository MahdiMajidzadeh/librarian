import SwiftUI
import BookShelfKit

/// Detail pane: metadata, status, and the underlying files with per-file
/// actions (FR-2.3), plus split (FR-2.4).
@MainActor
struct BookDetailView: View {
    @Environment(AppModel.self) private var model
    let item: BookListItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
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
            metadataRow("Publisher", item.book.publisher)
            metadataRow("Year", item.book.year.map(String.init))
            metadataRow("Language", item.book.language)
            metadataRow("ISBN-13", item.book.isbn13)
            metadataRow("ISBN-10", item.book.isbn10)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(value)
                    .textSelection(.enabled)
            }
        }
    }

    private var tagRow: some View {
        HStack(spacing: 6) {
            ForEach(item.book.tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
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
