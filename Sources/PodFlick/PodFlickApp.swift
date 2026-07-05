import SwiftUI

@main
struct PodFlickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The main window is created and owned by AppState (AppKit), NOT by a
        // SwiftUI Window scene: a scene's window auto-opens at launch, so a
        // quiet service/URL launch flashed it before it could be hidden.
        // Owning the window means a background launch never creates one.
        // Settings is the placeholder scene SwiftUI requires.
        Settings { EmptyView() }
            .commands {
                // Replace the default "About PodFlick" so the panel carries the
                // Apple-trademark disclaimer (AppState.showAboutPanel).
                CommandGroup(replacing: .appInfo) {
                    Button("About PodFlick") { AppState.showAboutPanel() }
                }
            }
    }
}
