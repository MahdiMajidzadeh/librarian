import SwiftUI
import BookShelfKit

/// App settings (§6.7): library folder, rename template with live preview,
/// metadata precedence + provider key, ignore list, CSV options, cover cache.
@MainActor
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var template = ""
    @State private var overwritePolicy = false
    @State private var googleKey = ""
    @State private var ignoreList = ""
    @State private var csvDelimiter = ","
    @State private var csvSeparator = "; "
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            librarySection
            renameSection
            metadataSection
            scanSection
            exportSection
            cacheSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .onAppear(perform: load)
    }

    private func load() {
        template = model.renameTemplateRaw
        overwritePolicy = model.settingValue("applyPolicy") == ApplyPolicy.overwrite.rawValue
        googleKey = model.settingValue("googleBooksAPIKey")
        ignoreList = model.settingValue("ignoreList")
        csvDelimiter = model.settingValue("csvDelimiter", default: ",")
        csvSeparator = model.settingValue("csvMultiValueSeparator", default: "; ")
        cacheSize = model.coverCache.totalSizeBytes()
    }

    // MARK: Sections

    private var librarySection: some View {
        Section("Library") {
            LabeledContent("Folder") {
                HStack {
                    Text(model.libraryFolder?.path ?? "Not set")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change…") { model.chooseLibraryFolder() }
                }
            }
        }
    }

    private var renameSection: some View {
        Section {
            TextField("Template", text: $template)
                .fontDesign(.monospaced)
                .onChange(of: template) {
                    model.setSettingValue("renameTemplate", template)
                }
            templatePreview
        } header: {
            Text("Rename Template")
        } footer: {
            Text("Tokens: {title} {author} {authors} {author_sort} {year} {series} {series_index} {isbn} {language} {publisher} {ext}. Conditional: {series? ({series} #{series_index})}")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Live preview using up to three real books from the library (FR-4.3).
    @ViewBuilder
    private var templatePreview: some View {
        switch previewResult {
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case .success(let lines) where lines.isEmpty:
            Text("Scan a library to see a live preview with your actual books.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .success(let lines):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private enum PreviewOutcome {
        case success([String])
        case failure(String)
    }

    private var previewResult: PreviewOutcome {
        let parsed: RenameTemplate
        do {
            parsed = try RenameTemplate.parse(template)
        } catch {
            return .failure("\(error)")
        }
        // Prefer books with rich metadata for a representative preview.
        let samples = model.items
            .sorted { rank($0.book.metadataStatus) > rank($1.book.metadataStatus) }
            .prefix(3)
        let lines = samples.map { item in
            let ext = item.files.first.map {
                URL(fileURLWithPath: $0.path).pathExtension
            } ?? "epub"
            let result = parsed.render(book: item.book, fileExtension: ext)
            if let name = result.name {
                return name
            }
            let missing = result.missingTokens.map { "{\($0.rawValue)}" }.joined(separator: ", ")
            return "⚠︎ \(item.book.title): missing \(missing)"
        }
        return .success(Array(lines))
    }

    private func rank(_ status: MetadataStatus) -> Int {
        switch status {
        case .complete: return 2
        case .partial: return 1
        case .unresolved: return 0
        }
    }

    private var metadataSection: some View {
        Section("Online Metadata") {
            Toggle("Online results overwrite embedded metadata", isOn: $overwritePolicy)
                .onChange(of: overwritePolicy) {
                    model.setSettingValue("applyPolicy",
                        overwritePolicy ? ApplyPolicy.overwrite.rawValue : ApplyPolicy.fillEmpty.rawValue)
                }
            Text("Off: online data only fills empty fields. Manual edits always win either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Google Books API key (optional)", text: $googleKey)
                .onChange(of: googleKey) {
                    model.setSettingValue("googleBooksAPIKey", googleKey)
                }
            Text("Open Library is used by default and needs no key. Add a key to also query Google Books.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var scanSection: some View {
        Section("Scanning") {
            TextField("Ignored extensions", text: $ignoreList,
                      prompt: Text("e.g. txt, cbr"))
                .onChange(of: ignoreList) {
                    model.setSettingValue("ignoreList", ignoreList)
                }
            Text("Comma-separated. These file types are skipped on the next scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var exportSection: some View {
        Section("CSV Export") {
            Picker("Delimiter", selection: $csvDelimiter) {
                Text("Comma (,)").tag(",")
                Text("Semicolon (;)").tag(";")
                Text("Tab").tag("\t")
            }
            .onChange(of: csvDelimiter) {
                model.setSettingValue("csvDelimiter", csvDelimiter)
            }
            TextField("Multi-value separator", text: $csvSeparator)
                .frame(width: 200)
                .onChange(of: csvSeparator) {
                    model.setSettingValue("csvMultiValueSeparator", csvSeparator)
                }
        }
    }

    private var cacheSection: some View {
        Section("Cover Cache") {
            LabeledContent("Size", value: cacheSize.formattedFileSize)
            Button("Clear Cache") {
                try? model.coverCache.clear()
                cacheSize = model.coverCache.totalSizeBytes()
            }
        }
    }
}
