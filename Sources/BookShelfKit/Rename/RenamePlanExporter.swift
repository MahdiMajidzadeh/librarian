import Foundation

/// Dry-run export of a rename plan (P1 backlog / spec Open Question 4):
/// lets users audit very large batches in a spreadsheet before committing.
public enum RenamePlanExporter {
    static let header = [
        "book_title", "current_name", "proposed_name", "status", "included",
        "current_path", "new_path",
    ]

    public static func exportCSV(
        plan: [RenamePlanItem],
        to url: URL,
        options: CSVExporter.Options = .init()
    ) throws {
        var out = header
            .map { CSVExporter.escape($0, options) }
            .joined(separator: options.delimiter) + "\r\n"

        for item in plan {
            let fields = [
                item.bookTitle,
                item.currentName,
                item.proposedName ?? "",
                statusLabel(item.status),
                item.included ? "yes" : "no",
                item.currentPath,
                item.newPath ?? "",
            ]
            out += fields
                .map { CSVExporter.escape($0, options) }
                .joined(separator: options.delimiter) + "\r\n"
        }

        var data = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM, same as library CSV
        data.append(Data(out.utf8))
        try data.write(to: url, options: .atomic)
    }

    static func statusLabel(_ status: RenamePlanItem.Status) -> String {
        switch status {
        case .ready: return "ready"
        case .noOp: return "no_change"
        case .collisionResolved: return "collision_suffixed"
        case .missingTokens(let tokens): return "excluded_missing_\(tokens.joined(separator: "+"))"
        case .missingOnDisk: return "excluded_missing_on_disk"
        }
    }
}
