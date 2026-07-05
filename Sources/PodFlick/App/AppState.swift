import AppKit
import SwiftUI
import UserNotifications

/// App-wide coordination for the two background entry points (B.9): the Finder
/// "Transfer to iPod" service and the podflick:// URL scheme. Both funnel here,
/// which decides whether the request is a quiet one (cold launch → no window,
/// report via the menu-bar item and a notification) or lands while the app is
/// already open (keep the window; the queue list shows progress).
///
/// The queue, device targeting and the single-mutator DB write all live in
/// `SyncModel.shared`; this type owns the *presentation*: the main window
/// (AppKit-owned so a quiet launch never creates it — a SwiftUI Window scene
/// auto-opens at launch and flashed before it could be hidden), the activation
/// policy, an AppKit `NSStatusItem` menu (SwiftUI's `MenuBarExtra` pegs the
/// main thread in an image-render loop here), and completion notifications.
///
/// NOTE: the quiet-launch handling (launch-phase classification, window
/// suppression, activation policy) is macOS window-server behavior with no
/// headless-testable surface — verify it by hand on a real Mac.
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

    /// The one main window, created lazily on the first windowed use and
    /// reused ever after (isReleasedWhenClosed = false). nil on a quiet
    /// launch until the user asks for it — that is what kills the flash.
    private var mainWindow: NSWindow?

    private override init() {
        super.init()
        model.onItemFinished = { [weak self] item in
            self?.itemFinished(item)
        }
        // Without a delegate opting in, macOS silently drops banners posted
        // by the ACTIVE app — and during a quiet launch this app is active,
        // so every completion notification landed in Notification Center
        // without ever popping. willPresent below opts back in.
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Lifecycle (called by AppDelegate)

    func applicationDidFinishLaunching() {
        // A launch-time service/URL event is delivered within this same
        // runloop pass, BEFORE this async block runs — so a background
        // request has already set isBackgroundMode by the time we decide
        // whether this launch gets a window. A normal launch gets one here.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.launchPhase = false
            if !self.isBackgroundMode { self.showMainWindow() }
        }
    }

    /// Dock-icon click (or app reopen) with no visible window.
    func applicationShouldHandleReopen() {
        if !isBackgroundMode { showMainWindow() }
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

    // MARK: - Main window (AppKit-owned)

    /// Shows (creating on first use) the one main window and brings the app
    /// forward as a regular windowed app (the app launches as an LSUIElement
    /// agent; this is where a normal launch gains its Dock icon).
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        // Ask for notification permission while the app is visibly frontmost —
        // requested from a windowless accessory launch, the system prompt is
        // easy to miss and an unanswered prompt drops every later banner.
        requestNotificationAuthIfNeeded()
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: ContentView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "PodFlick"
            window.setContentSize(NSSize(width: 720, height: 560))
            window.contentMinSize = NSSize(width: 560, height: 460)
            window.isReleasedWhenClosed = false   // closed = hidden, reused later
            window.setFrameAutosaveName("PodFlickMain")
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Background mode

    /// Quiet mode for a cold service/URL launch: no Dock icon, no window (none
    /// was ever created — see applicationDidFinishLaunching), just the status
    /// item as the way back into the app.
    private func enterBackgroundMode() {
        guard !isBackgroundMode else { return }
        isBackgroundMode = true
        NSApp.setActivationPolicy(.accessory)
        showStatusItem()
    }

    /// Return to a normal windowed app. Called from the status item's "Open
    /// PodFlick".
    func exitBackgroundMode() {
        guard isBackgroundMode else { return }
        isBackgroundMode = false
        hideStatusItem()
        showMainWindow()
    }

    // MARK: - Status item

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Brand glyph from the asset catalog, rendered as a template so it adapts
        // to the light/dark menu bar; fall back to the SF Symbol if it's ever missing.
        let icon = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "ipod", accessibilityDescription: nil)
        icon?.isTemplate = true
        icon?.accessibilityDescription = "PodFlick transfers"
        item.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self    // rebuilt from the live queue each time it opens
        menu.autoenablesItems = false
        item.menu = menu
        // Force visibility: created during a cold/accessory launch, the item's
        // isVisible defaults to false and it never renders otherwise.
        item.isVisible = true
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
            let row = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
            row.isEnabled = false   // informational rows
            // A custom view so the row carries a progress bar; rebuilt on each
            // open, so it reflects progress at the moment the menu is shown.
            row.view = TransferProgressRow(title: item.title,
                                           label: item.stage.label,
                                           progress: item.stage.overallProgress)
        }
        if !background.isEmpty { menu.addItem(.separator()) }
        addItem(to: menu, "Open PodFlick", #selector(openMainWindow))
        if background.contains(where: \.stage.isFinished) {
            addItem(to: menu, "Clear finished", #selector(clearFinished))
        }
        // Eject without having to open the app — the whole point of a quiet
        // transfer is not summoning the window just to unplug safely.
        if let device = model.selectedDevice {
            let eject = addItem(to: menu, "Eject \(device.name)",
                                #selector(ejectSelectedDevice))
            eject.isEnabled = !model.queueIsBusy && !model.isEjecting
        }
        menu.addItem(.separator())
        addItem(to: menu, "Quit PodFlick", #selector(quit))
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String,
                         _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openMainWindow() { exitBackgroundMode() }
    @objc private func clearFinished() { model.clearFinished() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Eject from the status menu: fire the model's eject and report the
    /// outcome as a notification (the window that normally shows the error
    /// banner may not exist).
    @objc private func ejectSelectedDevice() {
        guard let device = model.selectedDevice else { return }
        let name = device.name
        model.eject()
        // eject() refuses — and returns WITHOUT starting a task — when the
        // queue is busy. Don't then report a fake "Eject failed" for an eject
        // that never ran (waitUntilEjectFinished would resolve instantly on a
        // nil task, surfacing a stale/unrelated deviceError); show its reason.
        guard model.isEjecting else {
            if let reason = model.deviceError {
                notify(title: "Can’t eject yet", body: reason)
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.model.waitUntilEjectFinished()
            if let error = self.model.deviceError {
                self.notify(title: "Eject failed", body: error)
            } else {
                self.notify(title: "Safe to disconnect",
                            body: "\(name) has been ejected.")
            }
        }
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

    private func requestNotificationAuthIfNeeded() {
        guard !didRequestNotificationAuth else { return }
        didRequestNotificationAuth = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        // Resolve authorization BEFORE adding: on first use (a quiet launch)
        // the async request would otherwise race the add() and drop the very
        // notification this exists to deliver. requestAuthorization returns the
        // existing decision without re-prompting once the user has chosen.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { center.add(request) }
        }
    }
}

extension AppState: UNUserNotificationCenterDelegate {
    /// Show banners even while this app is the active one (the default is to
    /// suppress them, which hid every quiet-transfer completion).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
