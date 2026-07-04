import SwiftUI

@main
struct PodFlickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The one app-wide model; the background entry points (Finder service,
    // podflick://) feed the same instance via AppDelegate → AppState. The
    // menu-bar progress item is an AppKit NSStatusItem owned by AppState (a
    // SwiftUI MenuBarExtra pegs the main thread in an image-render loop here).
    @StateObject private var model = SyncModel.shared

    var body: some Scene {
        // A single-instance Window (not a WindowGroup): reopening from the
        // status item focuses the one window instead of spawning duplicates
        // that would share the one SyncModel.
        Window("PodFlick", id: "main") {
            ContentView(model: model)
        }
    }
}
