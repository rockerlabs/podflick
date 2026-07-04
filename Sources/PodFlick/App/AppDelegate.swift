import AppKit

/// Thin AppKit bridge for the background entry points (B.9). SwiftUI has no
/// hooks for the Services provider or for URL opens without a window, so this
/// delegate wires both to `AppState.shared` and lets that type own the logic.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var serviceProvider = ServiceProvider { files in
        AppState.shared.handleTransferRequest(files)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be registered before launch completes for the Finder service
        // to route "Transfer to iPod" here.
        NSApp.servicesProvider = serviceProvider
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.applicationDidFinishLaunching()
    }

    /// podflick:// URLs — both at launch (a cold Quick Action) and while the
    /// app is already running.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.flatMap(URLScheme.transferURLs(from:))
        AppState.shared.handleTransferRequest(files)
    }

    /// Keep the app alive when the window closes: it may be running a quiet
    /// background transfer (windowless), and on a cold service/URL launch the
    /// single Window scene would otherwise terminate the app the instant
    /// AppState hides the auto-opened window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
