import SwiftUI
import LibrarianKit
import UniformTypeIdentifiers

/// Detail sidebar for one book (FR-2.3, FR-3.3, FR-3.7): fields with
/// provenance, the file list with per-file actions, cover actions including
/// "use cover from this file" (user deviation), merge/ungroup entry points.
struct BookDetailView: View {
    @EnvironmentObject private var model: AppModel
    let entry: LibraryEntry

    @State private var provenance: [String: Provenance] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                coverSection
                titleSection
                Divider()
                fieldsSection
                if let note = entry.book.parseErrorNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Divider()
                filesSection
                Divider()
                actionsSection
                if let description = entry.book.bookDescription, !description.isEmpty {
                    Divider()
                    Text("Description")
                        .font(.headline)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: entry.id) {
            provenance = (try? model.database.provenance(forBook: entry.id)) ?? [:]
        }
    }

    // MARK: - Cover

    private var coverSection: some View {
        HStack {
            Spacer()
            CoverView(entry: entry)
                .frame(width: 140, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 2)
                .contextMenu {
                    coverMenuItems
                }
            Spacer()
        }
        .overlay(alignment: .bottomTrailing) {
            Menu {
                coverMenuItems
            } label: {
                Image(systemName: "photo.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Change cover")
        }
    }

    @ViewBuilder
    private var coverMenuItems: some View {
        // User deviation: pick the cover from any file in the group.
        ForEach(entry.files) { file in
            if file.format.hasEmbeddedSupport, !file.missingFlag {
                Button("Use Cover from \(file.filename)") {
                    model.setCover(for: entry, fromFile: file)
                }
            }
        }
        Divider()
        Button("Replace from Image File…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .heic]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                model.setCover(for: entry, fromImageAt: url)
            }
        }
        Button("Re-fetch Cover Online") {
            model.resolveOnline(entryIds: [entry.id])
        }
    }

    // MARK: - Title & fields

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(entry.book.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    model.editingBook = entry.book
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit metadata")
            }
            if !entry.book.authors.isEmpty {
                Text(entry.book.authors.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                FormatBadges(formats: entry.formats)
                if entry.isAutoGrouped {
                    Label("Auto-grouped", systemImage: "link")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                        .help("Grouped by filename similarity only — review and split if wrong")
                }
            }
        }
    }

    private var fieldsSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            field("Series", entry.book.series.map { series in
                entry.book.seriesIndex.map { "\(series) #\(Exporters.seriesIndexString($0))" }
                    ?? series
            }, provenanceKey: "series")
            field("Publisher", entry.book.publisher, provenanceKey: "publisher")
            field("Year", entry.book.year.map(String.init), provenanceKey: "year")
            field("Language", entry.book.language, provenanceKey: "language")
            field("ISBN-13", entry.book.isbn13, provenanceKey: "isbn13")
            field("ISBN-10", entry.book.isbn10, provenanceKey: "isbn10")
            GridRow {
                Text("Status")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(entry.book.metadataStatus.rawValue.capitalized)
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String?, provenanceKey: String) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                HStack(spacing: 5) {
                    Text(value)
                        .textSelection(.enabled)
                    ProvenanceTag(source: provenance[provenanceKey]?.source)
                }
            }
            .font(.callout)
        }
    }

    // MARK: - Files (FR-2.3)

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files (\(entry.files.count))")
                .font(.headline)
            ForEach(entry.files) { file in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(file.format.badge)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.filename)
                            .font(.callout)
                            .strikethrough(file.missingFlag)
                            .foregroundStyle(file.missingFlag ? .secondary : .primary)
                            .textSelection(.enabled)
                            .help(file.path)
                        Text(file.missingFlag
                            ? "Missing on disk"
                            : "\(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)) · \(file.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2)
                            .foregroundStyle(file.missingFlag ? Color.red : .secondary)
                    }
                    Spacer()
                    if entry.files.count >= 2 {
                        Button {
                            model.splitFile(file)
                        } label: {
                            Image(systemName: "scissors")
                        }
                        .buttonStyle(.borderless)
                        .help("Split this file into its own book")
                    }
                    if !file.missingFlag {
                        Button {
                            model.open(file: file)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Open in default app")
                        Button {
                            model.revealInFinder(file: file)
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.resolveOnline(entryIds: [entry.id])
            } label: {
                Label("Resolve Metadata Online", systemImage: "network")
            }
            Button {
                model.selection = [entry.id]
                model.prepareRename()
            } label: {
                Label("Rename Files…", systemImage: "character.cursor.ibeam")
            }
            if entry.files.count >= 2 {
                Button {
                    model.ungroup(entry: entry)
                } label: {
                    Label("Ungroup — One Book per File", systemImage: "square.split.2x1")
                }
            }
        }
        .buttonStyle(.link)
    }
}

/// Small provenance label (FR-3.3), e.g. "embedded", "google_books", "manual".
struct ProvenanceTag: View {
    let source: MetadataSource?

    var body: some View {
        if let source {
            Text(label)
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color.opacity(0.15))
                .foregroundStyle(color)
                .clipShape(Capsule())
                .help("Source: \(label)")
        }
    }

    private var label: String {
        switch source {
        case .embedded: return "embedded"
        case .googleBooks: return "Google Books"
        case .openLibrary: return "Open Library"
        case .manual: return "manual"
        case .filename: return "filename"
        case nil: return ""
        }
    }

    private var color: Color {
        switch source {
        case .manual: return .blue
        case .googleBooks, .openLibrary: return .green
        case .filename: return .orange
        case .embedded, nil: return .gray
        }
    }
}
