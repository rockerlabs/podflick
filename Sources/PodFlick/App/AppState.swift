import AppKit
import UserNotifications

/// App-wide coordination for the two background entry points (B.9): the Finder
/// "Transfer to iPod" service and the podflick:// URL scheme. Both funnel here,
/// which decides whether the request is a quiet one (cold launch → no window,
/// report via the menu-bar item and a notification) or lands while the app is
/// already open (keep the window; the queue list shows progress).
///
/// The queue, device targeting and the single-mutator DB write all live in
/// `SyncModel.shared`; this type only owns the *presentation* of background
/// transfers (activation policy, the menu-bar status item, notifications).
///
/// NOTE: the quiet-launch handling (launch-phase classification, closing the
/// auto-opened window, activation policy) is macOS window-server behavior with
/// no headless-testable surface — it must be verified by hand on a real Mac.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private let model = SyncModel.shared

    /// Drives the MenuBarExtra's `isInserted`. Mirrors background mode, so the
    /// menu-bar item — the only way back to the app while it runs windowless —
    /// stays available until the user opens the window or quits, even after the
    /// queue has been cleared.
    @Published var showsStatusItem = false

    /// True between a quiet (service/URL) launch and the user opening a window.
    /// While set, the app runs as an `.accessory` (no Dock icon, no window).
    private var isBackgroundMode = false

    /// True only during the launch runloop pass. A transfer request that
    /// arrives while this holds was the reason the app was launched, so it runs
    /// quiet; a request to an already-running instance keeps the window. Both
    /// entry points forward synchronously (see ServiceProvider), so they see
    /// this flag with the same timing.
    private var launchPhase = true

    /// Notification permission is requested on first use, not at launch, so a
    /// plain windowed launch pays no permission cost or first-run prompt.
    private var didRequestNotificationAuth = false

    private init() {
        model.onItemFinished = { [weak self] item in
            self?.itemFinished(item)
        }
    }

    // MARK: - Lifecycle (called by AppDelegate)

    func applicationDidFinishLaunching() {
        // A launch-time service/URL event is delivered within this same
        // runloop pass; clearing the flag one turn later lets those be seen
        // as the launch reason while later requests count as "app running".
        DispatchQueue.main.async { [weak self] in self?.launchPhase = false }
    }

    // MARK: - Transfer requests

    /// The single entry point for both background sources.
    func handleTransferRequest(_ files: [URL]) {
        let files = files.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        // Resolve the device BEFORE going windowless: a request with no iPod
        // connected must not strand the app in accessory mode with nothing to
        // show. Leave the launch/window as-is and just report the problem.
        guard model.selectedDevice != nil else {
            notify(title: "No iPod connected",
                   body: "Connect an iPod 5G/5.5G and try again.")
            return
        }
        if launchPhase { enterBackgroundMode() }
        model.enqueueBackground(files)
    }

    // MARK: - Background mode

    /// Go windowless: no Dock icon, and close the window the scene auto-opened
    /// at launch so a quiet transfer really has none. Reopened cleanly via
    /// `openWindow(id: "main")` from the menu-bar item.
    private func enterBackgroundMode() {
        isBackgroundMode = true
        showsStatusItem = true
        NSApp.setActivationPolicy(.accessory)
        for window in NSApp.windows
        where window.canBecomeMain && window.styleMask.contains(.titled) {
            window.close()
        }
    }

    /// Return to a normal windowed app. Called when the user picks "Open
    /// PodFlick" from the menu-bar item (which also opens the window).
    func exitBackgroundMode() {
        isBackgroundMode = false
        showsStatusItem = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Notifications

    private func itemFinished(_ item: SyncModel.QueueItem) {
        guard item.origin == .background else { return }
        switch item.stage {
        case .done:
            notify(title: "Transferred to iPod",
                   body: "“\(item.title)” is ready to watch.")
        case .failed(let message):
            notify(title: "Transfer failed",
                   body: "“\(item.title)” — \(message)")
        default:
            break
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        if !didRequestNotificationAuth {
            didRequestNotificationAuth = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                          content: content, trigger: nil))
    }
}
