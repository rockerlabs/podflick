import SwiftUI
import AppKit

@main
struct PodFlickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The project page opened by the Help menu (usage + README).
    private static let helpURL = URL(string: "https://github.com/rockerlabs/podflick")!

    var body: some Scene {
        // The main window is created and owned by AppState (AppKit), NOT by a
        // SwiftUI Window scene: a scene's window auto-opens at launch, so a
        // quiet service/URL launch flashed it before it could be hidden.
        // Owning the window means a background launch never creates one.
        // Settings is the ⌘, pane (also the scene SwiftUI requires); it does
        // NOT auto-open, unlike a Window/WindowGroup, so a quiet launch stays
        // window-less. See SettingsView for the app-global preferences.
        Settings { SettingsView() }
            .commands {
                // Replace the default "About PodFlick" so the panel carries the
                // Apple-trademark disclaimer (AppState.showAboutPanel).
                CommandGroup(replacing: .appInfo) {
                    Button("About PodFlick") { AppState.showAboutPanel() }
                }
                // A menu-bar app otherwise has no Help menu — point it at the
                // project page (usage + README).
                CommandGroup(replacing: .help) {
                    Button("PodFlick Help") {
                        NSWorkspace.shared.open(Self.helpURL)
                    }
                }
            }
    }
}
