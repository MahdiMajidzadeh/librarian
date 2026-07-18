import SwiftUI
import AppKit
import BookShelfKit

@main
struct BookShelfApp: App {
    @State private var model: AppModel

    init() {
        // Running as a bare SPM binary (no app bundle): claim regular-app
        // status so the window and menu bar appear.
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        do {
            _model = State(initialValue: try AppModel())
        } catch {
            fatalError("Failed to open database: \(error)")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Librarian") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(after: .undoRedo) {
                Button("Undo Last Rename Batch") {
                    Task { await model.undoLastRename() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.undoableBatch == nil)
            }
            CommandMenu("Library") {
                Button("Rescan Folder") {
                    Task { await model.scan() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.libraryFolder == nil || model.isScanning)

                Button("Re-extract Embedded Metadata") {
                    Task { await model.reextractMetadata() }
                }
                .disabled(model.items.isEmpty || model.isScanning)

                Divider()

                Menu("Export") {
                    Button("JSON…") {
                        Task { await model.export(.json(includeCovers: false)) }
                    }
                    Button("JSON with Covers…") {
                        Task { await model.export(.json(includeCovers: true)) }
                    }
                    Divider()
                    Button("CSV…") {
                        Task { await model.export(.csv()) }
                    }
                    Button("CSV — One Row per File…") {
                        Task { await model.export(.csv(mode: .perFile)) }
                    }
                }
                .disabled(model.items.isEmpty)

                Divider()

                Button("Purge Missing Files") {
                    Task { await model.purgeMissing() }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
