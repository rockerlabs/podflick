import SwiftUI
import ServiceManagement

/// The ⌘, Settings pane. PodFlick's per-video settings live per-device in the
/// main window; the only app-global preference so far is launch-at-login, wired
/// straight to `SMAppService.mainApp` (the macOS login-item registration).
struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch PodFlick at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }
        }
        .padding(20)
        .frame(width: 340)
        // Re-sync in case the login item was changed elsewhere (System Settings).
        .onAppear { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let desired: SMAppService.Status = enabled ? .enabled : .notRegistered
        // Skip when already in the wanted state — avoids a redundant call when
        // onAppear resyncs the toggle and re-fires onChange.
        guard SMAppService.mainApp.status != desired else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // The OS refused (e.g. requires approval) — reflect the real state.
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
