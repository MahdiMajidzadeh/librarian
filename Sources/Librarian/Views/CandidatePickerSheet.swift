import SwiftUI
import LibrarianKit

/// Candidate picker for ambiguous online lookups (FR-3.4). Per user request,
/// the local book (cover, title, author, filename) is shown side by side
/// with the online candidates so the match can be verified before applying.
struct CandidatePickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let state: AppModel.CandidatePickerState
    @State private var selectedCandidateId: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Confirm Online Match")
                .font(.title3.weight(.semibold))
                .padding(.top, 16)
            Text("Compare your local book with the online candidates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 0) {
                localPane
                    .frame(width: 230)
                    .padding(14)
                    .background(.background.secondary)
                Divider()
                candidateList
                    .frame(minWidth: 380)
            }
            .frame(height: 380)

            Divider()
            HStack {
                Button("Skip This Book") {
                    model.skipCandidatePicker()
                    dismiss()
                }
                Spacer()
                Button("Cancel") {
                    model.skipCandidatePicker()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply Selected") {
                    if let candidate = state.candidates.first(where: { $0.id == selectedCandidateId }) {
                        model.applyCandidate(candidate, to: state.entry)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCandidateId == nil)
            }
            .padding(14)
        }
        .frame(width: 680)
        .onAppear {
            selectedCandidateId = state.candidates.first?.id
        }
    }

    // MARK: - Local side (the user's file)

    private var localPane: some View {
        VStack(alignment: .center, spacing: 10) {
            Text("Your File")
                .font(.headline)
            CoverView(entry: state.entry)
                .frame(width: 120, height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 2)
            VStack(alignment: .center, spacing: 3) {
                Text(state.entry.book.title)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if !state.entry.book.authors.isEmpty {
                    Text(state.entry.book.authors.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.entry.files) { file in
                    Text(file.filename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Online candidates

    private var candidateList: some View {
        List(state.candidates, selection: $selectedCandidateId) { candidate in
            HStack(alignment: .top, spacing: 10) {
                CandidateCoverThumb(url: candidate.coverURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.metadata.title ?? "Untitled")
                        .font(.callout.weight(.medium))
                    if !candidate.metadata.authors.isEmpty {
                        Text(candidate.metadata.authors.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if let year = candidate.metadata.year {
                            Text(String(year))
                        }
                        if let publisher = candidate.metadata.publisher {
                            Text(publisher)
                                .lineLimit(1)
                        }
                        if let isbn = candidate.metadata.isbn13 ?? candidate.metadata.isbn10 {
                            Text("ISBN \(isbn)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    HStack(spacing: 6) {
                        ProvenanceTag(source: candidate.source)
                        // Title similarity, so wrong ISBN matches are
                        // rejectable at a glance (§9).
                        Text("similarity \(Int(candidate.titleSimilarity * 100))%")
                            .font(.system(size: 9))
                            .foregroundStyle(
                                candidate.titleSimilarity >= 0.6 ? Color.green : .orange)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .tag(candidate.id)
        }
    }
}

private struct CandidateCoverThumb: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fit)
            default:
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .overlay(
                        Image(systemName: "book.closed")
                            .foregroundStyle(.tertiary))
            }
        }
        .frame(width: 46, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
