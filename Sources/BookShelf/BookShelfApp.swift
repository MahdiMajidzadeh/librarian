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
        WindowGroup("Book Shelf") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
        }
    }
}
