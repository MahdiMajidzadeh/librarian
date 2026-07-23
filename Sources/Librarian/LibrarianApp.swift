import SwiftUI
import LibrarianKit

@main
struct LibrarianApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Library Folder…") { model.chooseLibraryFolder() }
                    .keyboardShortcut("O", modifiers: [.command, .shift])
                Button("Rescan Library") { model.scan() }
                    .keyboardShortcut("R", modifiers: .command)
                    .disabled(model.libraryPath == nil || model.isScanning)
                Divider()
                Button("Rename All Books…") { model.prepareRenameAll() }
                    .keyboardShortcut("R", modifiers: [.command, .shift])
                    .disabled(model.entries.isEmpty)
                Divider()
                Button("Export Library as JSON…") { model.exportJSON(selectionOnly: false) }
                Button("Export Library as CSV…") { model.exportCSV(selectionOnly: false) }
            }
            CommandGroup(after: .undoRedo) {
                Button("Undo Last Rename Batch") { model.undoLastRename() }
                    .keyboardShortcut("Z", modifiers: [.command, .option])
                    .disabled(!model.canUndoRename)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
