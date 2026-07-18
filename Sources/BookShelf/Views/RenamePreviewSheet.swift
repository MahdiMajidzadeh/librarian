import SwiftUI
import BookShelfKit

/// Mandatory pre-execution preview (FR-4.6): current → new name per file,
/// include/exclude checkboxes, collisions and no-ops flagged, exclusion
/// reasons listed.
@MainActor
struct RenamePreviewSheet: View {
    @Environment(AppModel.self) private var model
    @State private var plan: [RenamePlanItem]

    init(plan: [RenamePlanItem]) {
        self._plan = State(initialValue: plan)
    }

    private var actionable: [RenamePlanItem] {
        plan.filter { $0.included && ($0.status == .ready || $0.status == .collisionResolved) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename Preview")
                        .font(.headline)
                    Text("Files are renamed in place — nothing is moved or copied. The batch can be undone afterwards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(spacing: 4) {
                    ForEach($plan) { $item in
                        PlanRow(item: $item)
                    }
                }
                .padding(10)
            }
            .frame(minHeight: 260, maxHeight: 420)

            Divider()

            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.renamePlan = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename \(actionable.count) File\(actionable.count == 1 ? "" : "s")") {
                    model.renamePlan = plan   // carry include/exclude edits
                    Task { await model.executeRename() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(actionable.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 640)
    }

    private var summary: String {
        let collisions = plan.filter { $0.status == .collisionResolved }.count
        let noOps = plan.filter { $0.status == .noOp }.count
        let excluded = plan.filter {
            if case .missingTokens = $0.status { return true }
            if case .missingOnDisk = $0.status { return true }
            return false
        }.count
        var parts = ["\(plan.count) files"]
        if collisions > 0 { parts.append("\(collisions) collision\(collisions == 1 ? "" : "s") suffixed") }
        if noOps > 0 { parts.append("\(noOps) already correct") }
        if excluded > 0 { parts.append("\(excluded) excluded") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
private struct PlanRow: View {
    @Binding var item: RenamePlanItem

    private var togglable: Bool {
        item.status == .ready || item.status == .collisionResolved
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: $item.included)
                .labelsHidden()
                .disabled(!togglable)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.currentName)
                        .font(.callout)
                        .strikethrough(item.included && togglable, color: .secondary)
                        .foregroundStyle(togglable ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let proposed = item.proposedName, item.status != .noOp {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(proposed)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                statusLabel
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch item.status {
        case .ready:
            EmptyView()
        case .noOp:
            Text("Already matches the template")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .collisionResolved:
            Label("Name collision — suffix added", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .missingTokens(let tokens):
            Label("Excluded: missing \(tokens.joined(separator: ", "))",
                  systemImage: "slash.circle")
                .font(.caption2)
                .foregroundStyle(.red)
        case .missingOnDisk:
            Label("Excluded: file missing on disk", systemImage: "questionmark.folder")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private var backgroundColor: Color {
        switch item.status {
        case .collisionResolved: return .orange.opacity(0.08)
        case .missingTokens, .missingOnDisk: return .red.opacity(0.06)
        default: return .clear
        }
    }
}
