import SwiftUI
import LibrarianKit

/// Manual metadata editing (FR-3.7). Saved fields get `manual` provenance and
/// are never overwritten by scans or online lookups (FR-3.2).
struct BookEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let book: Book

    @State private var title = ""
    @State private var authors = ""
    @State private var series = ""
    @State private var seriesIndex = ""
    @State private var publisher = ""
    @State private var year = ""
    @State private var language = ""
    @State private var isbn10 = ""
    @State private var isbn13 = ""
    @State private var descriptionText = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Title", text: $title)
                TextField("Authors (comma-separated)", text: $authors)
                HStack {
                    TextField("Series", text: $series)
                    TextField("Series #", text: $seriesIndex)
                        .frame(width: 90)
                }
                TextField("Publisher", text: $publisher)
                HStack {
                    TextField("Year", text: $year)
                    TextField("Language", text: $language)
                }
                TextField("ISBN-13", text: $isbn13)
                TextField("ISBN-10", text: $isbn10)
                TextField("Description", text: $descriptionText, axis: .vertical)
                    .lineLimit(3...8)
            }
            .padding(20)

            Divider()
            HStack {
                Text("Manual edits always win and are never overwritten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private func load() {
        title = book.title
        authors = book.authors.joined(separator: ", ")
        series = book.series ?? ""
        seriesIndex = book.seriesIndex.map { Exporters.seriesIndexString($0) } ?? ""
        publisher = book.publisher ?? ""
        year = book.year.map(String.init) ?? ""
        language = book.language ?? ""
        isbn10 = book.isbn10 ?? ""
        isbn13 = book.isbn13 ?? ""
        descriptionText = book.bookDescription ?? ""
    }

    private func save() {
        var edited = book
        edited.title = title.trimmingCharacters(in: .whitespaces)
        edited.authors = authors
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        edited.series = series.isEmpty ? nil : series
        edited.seriesIndex = Double(seriesIndex.replacingOccurrences(of: ",", with: "."))
        edited.publisher = publisher.isEmpty ? nil : publisher
        edited.year = Int(year)
        edited.language = language.isEmpty ? nil : language
        edited.isbn10 = isbn10.isEmpty ? nil : ISBN.normalize(isbn10) ?? isbn10
        edited.isbn13 = isbn13.isEmpty ? nil : ISBN.normalize(isbn13) ?? isbn13
        edited.bookDescription = descriptionText.isEmpty ? nil : descriptionText
        model.saveManualEdits(edited, originalBook: book)
    }
}
