import Foundation

/// Persists access to the user's library folder via a security-scoped
/// bookmark (FR-1.1, NFR-5). Degrades gracefully when the app runs
/// unsandboxed (bookmark creation without security scope, or plain path).
public enum FolderAccess {
    /// Saves bookmark + display path into settings.
    public static func persist(_ url: URL, in database: AppDatabase) throws {
        let bookmark: Data?
        if let scoped = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmark = scoped
        } else {
            // Unsandboxed fallback: a plain bookmark still tracks folder moves.
            bookmark = try? url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        try database.setSetting(SettingKey.libraryBookmark, to: bookmark?.base64EncodedString())
        try database.setSetting(SettingKey.libraryPath, to: url.path)
    }

    public struct Resolved {
        public let url: URL
        /// True when `startAccessingSecurityScopedResource` succeeded and the
        /// caller must balance with `stopAccessing…` when done.
        public let isSecurityScoped: Bool

        public func stopAccessing() {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// Resolves the stored folder. Returns nil when nothing is stored; throws
    /// when a stored folder can no longer be found (§9: re-select prompt).
    public static func resolve(from database: AppDatabase) throws -> Resolved? {
        guard let path = try database.setting(SettingKey.libraryPath) else { return nil }

        if let base64 = try database.setting(SettingKey.libraryBookmark),
           let data = Data(base64Encoded: base64) {
            var stale = false
            for options in [URL.BookmarkResolutionOptions.withSecurityScope, []] {
                if let url = try? URL(
                    resolvingBookmarkData: data, options: options,
                    relativeTo: nil, bookmarkDataIsStale: &stale) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    if stale {
                        try? persist(url, in: database)
                    }
                    return Resolved(url: url, isSecurityScoped: scoped)
                }
            }
        }

        // Bookmark failed — fall back to the stored path if it still exists.
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AccessError.folderNotFound(path)
        }
        return Resolved(url: url, isSecurityScoped: false)
    }

    public enum AccessError: Error, LocalizedError {
        case folderNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .folderNotFound(let path):
                return "Library folder not found at \(path). Please re-select it."
            }
        }
    }
}
