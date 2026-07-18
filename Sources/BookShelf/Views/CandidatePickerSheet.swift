import SwiftUI
import BookShelfKit

/// Presented when online lookup finds multiple plausible matches (FR-3.4).
/// Shows each candidate with its title-similarity score so wrong embedded
/// ISBNs can be spotted and rejected (§9).
@MainActor
struct CandidatePickerSheet: View {
    @Environment(AppModel.self) private var model
    let request: AppModel.PickerRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Which book is “\(request.bookTitle)”?")
                    .font(.headline)
                Text("Multiple matches were found. Pick one, or skip to leave the book unchanged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(request.candidates) { candidate in
                        CandidateRow(candidate: candidate) {
                            Task { await model.applyCandidate(candidate, to: request.id) }
                        }
                    }
                }
                .padding(12)
            }
            .frame(minHeight: 240, maxHeight: 380)

            Divider()

            HStack {
                Text(sourceSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Skip This Book") { model.advancePicker() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 520)
    }

    private var sourceSummary: String {
        let sources = Set(request.candidates.map(\.source)).map(label(for:)).sorted()
        return "Results from \(sources.joined(separator: ", "))"
    }

    private func label(for source: ProvenanceSource) -> String {
        switch source {
        case .openLibrary: return "Open Library"
        case .googleBooks: return "Google Books"
        default: return source.rawValue
        }
    }
}

@MainActor
private struct CandidateRow: View {
    let candidate: LookupCandidate
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: candidate.coverURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
                    }
                }
                .frame(width: 44, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if !candidate.authors.isEmpty {
                        Text(candidate.authors.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if let year = candidate.year {
                            Text(String(year))
                        }
                        if let publisher = candidate.publisher {
                            Text(publisher).lineLimit(1)
                        }
                        if let isbn = candidate.isbn13 ?? candidate.isbn10 {
                            Text(isbn).monospaced()
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                similarityBadge
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var similarityBadge: some View {
        VStack(spacing: 2) {
            Text("\(Int(candidate.similarity * 100))%")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(similarityColor)
            Text("match")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var similarityColor: Color {
        if candidate.similarity >= 0.75 { return .green }
        if candidate.similarity >= 0.55 { return .orange }
        return .red
    }
}
