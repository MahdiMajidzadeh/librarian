import Foundation

/// Persists access to the library folder. Sandbox-compatible: prefers
/// security-scoped bookmarks, degrading to plain bookmarks and finally a raw
/// path when the entitlement is absent (NFR-5; unsandboxed dev builds).
public enum FolderAccess {
    public static let bookmarkSettingKey = "libraryBookmark"
    public static let pathSettingKey = "libraryPath"

    public static func persist(url: URL, in database: AppDatabase) throws {
        var bookmark: Data?
        do {
            bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            bookmark = try? url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        try database.setSetting(bookmarkSettingKey, bookmark?.base64EncodedString())
        try database.setSetting(pathSettingKey, url.path)
    }

    /// Restores the saved folder. Starts security-scoped access when the
    /// bookmark carries it; falls back to the raw path (§9: graceful when the
    /// folder moved — returns nil so the UI can re-prompt).
    public static func restore(from database: AppDatabase) throws -> URL? {
        if let base64 = try database.setting(bookmarkSettingKey),
           let data = Data(base64Encoded: base64) {
            for options in [URL.BookmarkResolutionOptions.withSecurityScope, []] {
                var stale = false
                if let url = try? URL(
                    resolvingBookmarkData: data, options: options,
                    relativeTo: nil, bookmarkDataIsStale: &stale) {
                    _ = url.startAccessingSecurityScopedResource()
                    if FileManager.default.fileExists(atPath: url.path) {
                        return url
                    }
                }
            }
        }
        if let path = try database.setting(pathSettingKey),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
