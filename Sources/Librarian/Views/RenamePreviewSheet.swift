import SwiftUI
import LibrarianKit

/// Mandatory rename preview (FR-4.6): current → new name per file, per-row
/// include checkboxes, collision and no-op rows flagged, excluded rows listed
/// with reasons (FR-4.9). Nothing is renamed until Execute.
struct RenamePreviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State var rows: [RenamePlanRow]

    init(rows: [RenamePlanRow]) {
        _rows = State(initialValue: rows)
    }

    private var actionableCount: Int { rows.filter(\.isActionable).count }
    private var collisionCount: Int { rows.filter { $0.status == .collision }.count }
    private var excludedRows: [RenamePlanRow] {
        rows.filter { if case .excluded = $0.status { return true } else { return false } }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("Rename Preview")
                    .font(.title3.weight(.semibold))
                Text("\(actionableCount) files will be renamed"
                    + (collisionCount > 0 ? " · \(collisionCount) collisions auto-suffixed" : "")
                    + (excludedRows.isEmpty ? "" : " · \(excludedRows.count) excluded"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)

            Table($rows) {
                TableColumn("") { $row in
                    Toggle("", isOn: $row.included)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(!isTogglable(row))
                }
                .width(24)

                TableColumn("Current Name") { $row in
                    Text(row.currentName)
                        .foregroundStyle(rowDimmed(row) ? .secondary : .primary)
                        .help(row.currentPath)
                }
                .width(min: 180, ideal: 260)

                TableColumn("") { _ in
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                }
                .width(20)

                TableColumn("New Name") { $row in
                    HStack(spacing: 6) {
                        Text(row.proposedName)
                            .foregroundStyle(rowDimmed(row) ? .secondary : .primary)
                        statusBadge(row)
                    }
                }
                .width(min: 200, ideal: 280)

                TableColumn("Book") { $row in
                    Text(row.bookTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 160)
            }
            .frame(minHeight: 300)

            if !excludedRows.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(excludedRows.prefix(4)) { row in
                        if case .excluded(let reason) = row.status {
                            Label("\(row.currentName): \(reason)", systemImage: "slash.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if excludedRows.count > 4 {
                        Text("… and \(excludedRows.count - 4) more excluded")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Text("Files are renamed in place. The batch can be undone afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename \(rows.filter(\.isActionable).count) Files") {
                    model.executeRename(rows: rows)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rows.filter(\.isActionable).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 780, height: 520)
    }

    private func isTogglable(_ row: RenamePlanRow) -> Bool {
        switch row.status {
        case .ready, .collision: return true
        case .noOp, .excluded: return false
        }
    }

    private func rowDimmed(_ row: RenamePlanRow) -> Bool {
        !isTogglable(row)
    }

    @ViewBuilder
    private func statusBadge(_ row: RenamePlanRow) -> some View {
        switch row.status {
        case .collision:
            Label("collision", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("Target name existed — suffix appended, nothing is overwritten")
        case .noOp:
            Text("no change")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .excluded:
            Text("excluded")
                .font(.caption2)
                .foregroundStyle(.red)
        case .ready:
            EmptyView()
        }
    }
}
