import SwiftUI
import BookShelfKit

@MainActor
struct LibraryTableView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Table(model.displayedItems, selection: $model.selection) {
            TableColumn("Title") { item in
                HStack(spacing: 6) {
                    Text(item.book.title)
                    StatusChips(item: item)
                }
                .opacity(item.allFilesMissing ? 0.5 : 1)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Author") { item in
                Text(item.book.authors.joined(separator: ", "))
                    .foregroundStyle(item.book.authors.isEmpty ? .tertiary : .primary)
            }
            .width(min: 120, ideal: 200)

            TableColumn("Formats") { item in
                FormatBadges(formats: item.formats)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Year") { item in
                Text(item.book.year.map(String.init) ?? "—")
                    .monospacedDigit()
            }
            .width(52)

            TableColumn("Size") { item in
                Text(item.totalSizeBytes.formattedFileSize)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("Status") { item in
                Text(statusLabel(item.book.metadataStatus))
                    .foregroundStyle(statusColor(item.book.metadataStatus))
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if ids.count >= 2 {
                Button("Merge \(ids.count) Books into One") {
                    model.selection = ids
                    Task { await model.mergeSelection() }
                }
            } else if let id = ids.first, let item = model.items.first(where: { $0.id == id }) {
                ForEach(item.files, id: \.path) { file in
                    Button("Reveal \(URL(fileURLWithPath: file.path).lastPathComponent)") {
                        model.revealInFinder(file)
                    }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first,
               let item = model.items.first(where: { $0.id == id }),
               let file = item.files.first(where: { !$0.missingFlag }) {
                model.openFile(file)
            }
        }
    }

    private func statusLabel(_ status: MetadataStatus) -> String {
        switch status {
        case .complete: return "Complete"
        case .partial: return "Partial"
        case .unresolved: return "Unresolved"
        }
    }

    private func statusColor(_ status: MetadataStatus) -> Color {
        switch status {
        case .complete: return .green
        case .partial: return .secondary
        case .unresolved: return .orange
        }
    }
}
