import SwiftUI
import BookShelfKit

/// Manual metadata editing (FR-3.7). Saved fields get `.manual` provenance
/// and are never overwritten by automatic resolution.
@MainActor
struct BookEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let bookId: Int64
    @State private var edits: AppModel.ManualEdits

    init(item: BookListItem) {
        self.bookId = item.id
        self._edits = State(initialValue: AppModel.ManualEdits(book: item.book))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Title", text: $edits.title)
                TextField("Authors", text: $edits.authors, prompt: Text("Comma-separated"))
                HStack {
                    TextField("Series", text: $edits.series)
                    TextField("#", text: $edits.seriesIndex)
                        .frame(width: 60)
                }
                TextField("Publisher", text: $edits.publisher)
                HStack {
                    TextField("Year", text: $edits.year)
                    TextField("Language", text: $edits.language, prompt: Text("e.g. en, fa"))
                }
                TextField("ISBN", text: $edits.isbn)
                TextField("Tags", text: $edits.tags, prompt: Text("Comma-separated"))
                TextField("Description", text: $edits.description, axis: .vertical)
                    .lineLimit(4...8)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Replace Cover…") { model.replaceCover(bookId: bookId) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        await model.saveManualEdits(edits, bookId: bookId)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 480)
    }
}
