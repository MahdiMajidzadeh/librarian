import SwiftUI
import LibrarianKit

/// App settings (§6.7): library folder, rename template with live preview
/// (FR-4.3), metadata precedence + provider order, ignore list, CSV options,
/// cover cache size + clear.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            RenameSettings()
                .tabItem { Label("Rename", systemImage: "character.cursor.ibeam") }
            MetadataSettings()
                .tabItem { Label("Metadata", systemImage: "network") }
            ExportSettings()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .frame(width: 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var ignoreList = ""
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            LabeledContent("Library Folder") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(model.libraryPath ?? "Not set")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change… (re-scans)") {
                        model.chooseLibraryFolder()
                    }
                }
            }

            TextField("Ignored extensions", text: $ignoreList, prompt: Text("zip, rar, iso"))
                .help("Comma-separated file extensions the scanner skips (§4)")
                .onSubmit(saveIgnoreList)

            LabeledContent("Cover Cache") {
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                    Button("Clear Cache") {
                        try? model.coverCache.clear()
                        try? model.database.writer.write { db in
                            try db.execute(sql: "UPDATE book SET coverCachePath = NULL")
                        }
                        model.reload()
                        cacheSize = model.coverCache.totalSizeBytes()
                    }
                }
            }
        }
        .padding(20)
        .onAppear {
            ignoreList = (try? model.database.setting(SettingKey.ignoreExtensions)) ?? "" ?? ""
            cacheSize = model.coverCache.totalSizeBytes()
        }
        .onDisappear(perform: saveIgnoreList)
    }

    private func saveIgnoreList() {
        try? model.database.setSetting(SettingKey.ignoreExtensions, to: ignoreList)
    }
}

// MARK: - Rename template (FR-4.1, FR-4.3)

private struct RenameSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var template = RenameTemplate.defaultTemplate
    @State private var validationError: String?

    var body: some View {
        Form {
            TextField("Template", text: $template)
                .font(.body.monospaced())
                .onChange(of: template) { _, newValue in
                    validationError = RenameTemplate.validate(newValue)
                    if validationError == nil {
                        try? model.database.setSetting(SettingKey.renameTemplate, to: newValue)
                    }
                }

            if let error = validationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Tokens: " + RenameTemplate.knownTokens.sorted()
                .map { "{\($0)}" }.joined(separator: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Conditionals render only when data exists: {series? ({series} #{series_index})}")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Live preview from three real library books (FR-4.3).
            Section("Preview (from your library)") {
                if previewEntries.isEmpty {
                    Text("Scan a library to see live previews")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(previewEntries) { entry in
                        if let file = entry.files.first {
                            let ext = (file.path as NSString).pathExtension
                            let rendered = (try? RenameTemplate.render(
                                template: template, book: entry.book, fileExtension: ext))
                            HStack {
                                Text(file.filename)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.tertiary)
                                Text(rendered.map { result in
                                    result.missingRequiredTokens.isEmpty
                                        ? result.filename
                                        : "⚠︎ missing \(result.missingRequiredTokens.map { "{\($0)}" }.joined(separator: ", "))"
                                } ?? "—")
                                    .lineLimit(1)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .padding(20)
        .onAppear {
            template = (try? model.database.setting(SettingKey.renameTemplate))
                ?? RenameTemplate.defaultTemplate ?? RenameTemplate.defaultTemplate
        }
    }

    private var previewEntries: [LibraryEntry] {
        Array(model.entries.filter { !$0.files.isEmpty }.prefix(3))
    }
}

// MARK: - Metadata (FR-3.2, provider order)

private struct MetadataSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var overwrite = false
    @State private var googleFirst = true

    var body: some View {
        Form {
            Picker("Field precedence", selection: $overwrite) {
                Text("Online fills empty fields only").tag(false)
                Text("Online overwrites embedded data").tag(true)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: overwrite) { _, newValue in
                try? model.database.setSetting(
                    SettingKey.metadataOverwrite,
                    to: newValue ? MergePolicy.overwrite.rawValue : MergePolicy.fillEmpty.rawValue)
            }
            Text("Manual edits always win, regardless of this setting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Picker("Provider order", selection: $googleFirst) {
                Text("Google Books, then Open Library").tag(true)
                Text("Open Library, then Google Books").tag(false)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: googleFirst) { _, newValue in
                try? model.database.setSetting(
                    SettingKey.providerOrder,
                    to: newValue
                        ? "google_books,open_library"
                        : "open_library,google_books")
            }
        }
        .padding(20)
        .onAppear {
            let policy = (try? model.database.setting(SettingKey.metadataOverwrite)) ?? nil
            overwrite = policy == MergePolicy.overwrite.rawValue
            let order = (try? model.database.setting(SettingKey.providerOrder)) ?? nil
            googleFirst = order?.hasPrefix("open_library") != true
        }
    }
}

// MARK: - Export (§6.7 CSV options)

private struct ExportSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var delimiter = ","
    @State private var separator = "; "

    var body: some View {
        Form {
            Picker("CSV delimiter", selection: $delimiter) {
                Text("Comma ( , )").tag(",")
                Text("Semicolon ( ; )").tag(";")
                Text("Tab").tag("\\t")
            }
            .onChange(of: delimiter) { _, newValue in
                try? model.database.setSetting(SettingKey.csvDelimiter, to: newValue)
            }

            TextField("Multi-value separator", text: $separator)
                .help("Joins multiple authors/files in one CSV cell")
                .onChange(of: separator) { _, newValue in
                    try? model.database.setSetting(SettingKey.csvMultiValueSeparator, to: newValue)
                }

            Text("CSV exports use UTF-8 with BOM so Excel renders Persian and other Unicode text correctly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            delimiter = (try? model.database.setting(SettingKey.csvDelimiter)) ?? "," ?? ","
            separator = (try? model.database.setting(SettingKey.csvMultiValueSeparator)) ?? "; " ?? "; "
        }
    }
}
