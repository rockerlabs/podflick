import SwiftUI

@main
struct PodFlickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The one app-wide model; the background entry points (Finder service,
    // podflick://) feed the same instance via AppDelegate → AppState.
    @StateObject private var model = SyncModel.shared
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        // A single-instance Window (not a WindowGroup): reopening from the
        // menu-bar item focuses the one window instead of spawning duplicates
        // that would share the one SyncModel.
        Window("PodFlick", id: "main") {
            ContentView(model: model)
        }

        // Shown only while a quiet background transfer is running (no window);
        // gives it progress and a way back to the full app.
        MenuBarExtra("PodFlick transfers", systemImage: "ipod",
                     isInserted: $appState.showsStatusItem) {
            TransferStatusMenu(model: model)
        }
    }
}

/// Contents of the menu-bar item during a background transfer: each item's
/// stage, plus the controls to surface the app or quit.
private struct TransferStatusMenu: View {
    @ObservedObject var model: SyncModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(backgroundItems) { item in
            Text("\(item.title) — \(item.stage.label)")
        }
        Divider()
        Button("Open PodFlick") {
            openWindow(id: "main")
            AppState.shared.exitBackgroundMode()
        }
        if backgroundItems.contains(where: \.stage.isFinished) {
            Button("Clear finished") { model.clearFinished() }
        }
        Divider()
        Button("Quit PodFlick") { NSApp.terminate(nil) }
    }

    private var backgroundItems: [SyncModel.QueueItem] {
        model.queue.filter { $0.origin == .background }
    }
}
