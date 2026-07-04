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
/// transfers: activation policy, an AppKit `NSStatusItem` menu (SwiftUI's
/// `MenuBarExtra` pegs the main thread in an image-render loop here), and
/// completion notifications.
///
/// NOTE: the quiet-launch handling (launch-phase classification, hiding the
/// auto-opened window, activation policy) is macOS window-server behavior with
/// no headless-testable surface — verify it by hand on a real Mac.
@MainActor
final class AppState: NSObject, NSMenuDelegate {
    static let shared = AppState()

    private let model = SyncModel.shared

    /// True between a quiet (service/URL) launch and the user opening a window.
    /// While set, the app runs as an `.accessory` (no Dock icon, no window)
    /// and shows the status item.
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

    /// The menu-bar item, present only in background mode.
    private var statusItem: NSStatusItem?

    /// The window hidden on entering background mode, re-shown on exit. Hidden
    /// (orderOut) rather than closed so SwiftUI keeps its scene bookkeeping.
    private weak var hiddenWindow: NSWindow?

    private override init() {
        super.init()
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

    /// Go windowless: no Dock icon, hide the window the scene auto-opened at
    /// launch, and show the status item as the way back into the app.
    private func enterBackgroundMode() {
        guard !isBackgroundMode else { return }
        isBackgroundMode = true
        NSApp.setActivationPolicy(.accessory)
        for window in NSApp.windows
        where window.canBecomeMain && window.styleMask.contains(.titled) {
            hiddenWindow = window
            window.orderOut(nil)
        }
        showStatusItem()
    }

    /// Return to a normal windowed app. Called from the status item's "Open
    /// PodFlick".
    func exitBackgroundMode() {
        guard isBackgroundMode else { return }
        isBackgroundMode = false
        hideStatusItem()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        hiddenWindow?.makeKeyAndOrderFront(nil)
        hiddenWindow = nil
    }

    // MARK: - Status item

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "ipod",
                                     accessibilityDescription: "PodFlick transfers")
        let menu = NSMenu()
        menu.delegate = self    // rebuilt from the live queue each time it opens
        item.menu = menu
        statusItem = item
    }

    private func hideStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let background = model.queue.filter { $0.origin == .background }
        for item in background {
            menu.addItem(withTitle: "\(item.title) — \(item.stage.label)",
                         action: nil, keyEquivalent: "")
        }
        if !background.isEmpty { menu.addItem(.separator()) }
        addItem(to: menu, "Open PodFlick", #selector(openMainWindow))
        if background.contains(where: \.stage.isFinished) {
            addItem(to: menu, "Clear finished", #selector(clearFinished))
        }
        menu.addItem(.separator())
        addItem(to: menu, "Quit PodFlick", #selector(quit))
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) {
        menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }

    @objc private func openMainWindow() { exitBackgroundMode() }
    @objc private func clearFinished() { model.clearFinished() }
    @objc private func quit() { NSApp.terminate(nil) }

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
