import SwiftUI

/// Main window: device header, upload queue, and the on-device video list.
/// Dropping files anywhere in the window enqueues them.
struct ContentView: View {
    @StateObject private var model = SyncModel()
    @State private var isDropTargeted = false
    @State private var videoToRename: IPodLibrary.Video?
    @State private var renameTitle = ""
    @State private var videoToRemove: IPodLibrary.Video?
    @State private var showCleanUpConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeaderView(model: model)
            Divider()
            banners
            if !model.queue.isEmpty {
                QueueSectionView(model: model)
                Divider()
            }
            videoList
        }
        .frame(minWidth: 560, minHeight: 460)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canAcceptDrops else { return false }
            model.enqueue(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay { dropOverlay }
        .alert("Rename Video", isPresented: renameAlertShown,
               presenting: videoToRename) { video in
            TextField("Title", text: $renameTitle)
            Button("Rename") { model.rename(video, to: renameTitle) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The new title shows up in the iPod's Videos menu.")
        }
        .confirmationDialog("Remove from iPod?", isPresented: removeDialogShown,
                            presenting: videoToRemove) { video in
            Button("Remove “\(video.title)”", role: .destructive) {
                model.remove(video)
            }
        } message: { _ in
            Text("Deletes the video file and its database entry. The DB is backed up first.")
        }
        .confirmationDialog("Delete orphaned files?",
                            isPresented: $showCleanUpConfirmation) {
            Button("Delete \(model.orphans.count) "
                 + (model.orphans.count == 1 ? "file" : "files"),
                   role: .destructive) {
                model.cleanUpOrphans()
            }
        } message: {
            Text("The database is not touched — these files are not part "
               + "of it:\n" + orphanFileList)
        }
    }

    /// First few orphan names for the confirmation dialog.
    private var orphanFileList: String {
        let shown = model.orphans.prefix(5).map(\.name).joined(separator: ", ")
        let more = model.orphans.count - 5
        return more > 0 ? "\(shown) and \(more) more" : shown
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if model.tools == nil {
            BannerView(text: "ffmpeg not found — install it (brew install ffmpeg) "
                           + "and relaunch PodFlick", style: .warning)
        }
        if let device = model.selectedDevice {
            if device.rejection == .hashRequiredModel {
                BannerView(text: "\(device.name) requires a hashed iTunesDB "
                               + "(classic 6G+) — not supported yet", style: .warning)
            } else if !device.databaseExists {
                BannerView(text: "No iTunesDB on \(device.name) — sync it once "
                               + "with Finder first", style: .warning)
            }
        }
        if !model.orphans.isEmpty {
            BannerView(text: orphanSummary, style: .warning,
                       actionTitle: "Clean Up…",
                       onAction: { showCleanUpConfirmation = true })
        }
        if let error = model.deviceError {
            BannerView(text: error, style: .error, onDismiss: { model.deviceError = nil })
        }
    }

    /// "3 files (812 MB) on IPOD are not referenced by the database …"
    private var orphanSummary: String {
        let count = model.orphans.count
        let size = Formatters.bytes(model.orphans.reduce(0) { $0 + $1.fileSize })
        let device = model.selectedDevice?.name ?? "iPod"
        return "\(count) \(count == 1 ? "file" : "files") (\(size)) on \(device) "
             + "\(count == 1 ? "is" : "are") not referenced by the database — "
             + "invisible on the device, wasting space"
    }

    // MARK: - Video list

    @ViewBuilder
    private var videoList: some View {
        if model.selectedDevice == nil {
            emptyState("ipod", "Connect an iPod",
                       "Plug in an iPod 5G/5.5G and it appears here.")
        } else if model.deviceVideos.isEmpty {
            emptyState("film", "No videos on this iPod",
                       model.canAcceptDrops
                           ? "Drop video files anywhere in this window to upload them."
                           : "")
        } else {
            List {
                Section("Videos on iPod (\(model.deviceVideos.count))") {
                    ForEach(model.deviceVideos) { video in
                        VideoRowView(video: video)
                            .contextMenu {
                                Button("Rename…") {
                                    renameTitle = video.title
                                    videoToRename = video
                                }
                                Button("Remove from iPod", role: .destructive) {
                                    videoToRemove = video
                                }
                            }
                    }
                }
            }
        }
    }

    private func emptyState(_ symbol: String, _ title: String,
                            _ subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(title).font(.title2)
            if !subtitle.isEmpty {
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted && model.canAcceptDrops {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .background(Color.accentColor.opacity(0.08))
                .overlay {
                    Label("Drop to upload to \(model.selectedDevice?.name ?? "iPod")",
                          systemImage: "arrow.down.circle.fill")
                        .font(.title3)
                        .padding(10)
                        .background(.regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Sheet/dialog bindings

    private var renameAlertShown: Binding<Bool> {
        Binding(get: { videoToRename != nil },
                set: { if !$0 { videoToRename = nil } })
    }

    private var removeDialogShown: Binding<Bool> {
        Binding(get: { videoToRemove != nil },
                set: { if !$0 { videoToRemove = nil } })
    }
}

// MARK: - Device header

private struct DeviceHeaderView: View {
    @ObservedObject var model: SyncModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "ipod")
                .font(.system(size: 28))
                .foregroundStyle(model.selectedDevice == nil ? .secondary : .primary)
            if let device = model.selectedDevice {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    Text(subtitle(for: device))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No iPod connected")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let device = model.selectedDevice, device.isSupported {
                Picker("Video quality", selection: profileBinding) {
                    ForEach(VideoProfile.allCases, id: \.self) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Conversion size for this iPod. 640×480 plays only on "
                    + "a 5.5G — a 5G shows a black screen. Stored on the "
                    + "device; new uploads use it, existing videos keep theirs.")
                .disabled(model.isEjecting)
            }
            if model.devices.count > 1 {
                Picker("Device", selection: $model.selectedVolume) {
                    ForEach(model.devices, id: \.volumeURL) { device in
                        Text(device.name).tag(Optional(device.volumeURL))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }
            if model.selectedDevice != nil {
                if model.isEjecting {
                    ProgressView()
                        .controlSize(.small)
                        .help("Ejecting…")
                } else {
                    Button {
                        model.eject()
                    } label: {
                        Image(systemName: "eject.fill")
                    }
                    .help("Sync and safely eject")
                    .disabled(model.queueIsBusy)
                }
            }
            Button {
                model.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan for iPods")
        }
        .padding(12)
    }

    /// The device snapshot is the single source of truth; a set rewrites
    /// the on-device prefs and comes back via the rescan.
    private var profileBinding: Binding<VideoProfile> {
        Binding(get: { model.selectedDevice?.videoProfile ?? .standard },
                set: { model.setVideoProfile($0) })
    }

    private func subtitle(for device: IPodDevice) -> String {
        var parts: [String] = []
        if let model = device.modelNumber { parts.append("Model \(model)") }
        parts.append("\(Formatters.bytes(device.freeBytes)) free")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Upload queue

private struct QueueSectionView: View {
    @ObservedObject var model: SyncModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Upload queue").font(.headline)
                Spacer()
                if model.queue.contains(where: \.stage.isFinished) {
                    Button("Clear finished") { model.clearFinished() }
                        .buttonStyle(.link)
                }
            }
            // Scrolls so a big multi-file drop can't squeeze the video
            // list out of the window.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.queue) { item in
                        QueueRowView(item: item)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(12)
    }
}

private struct QueueRowView: View {
    let item: SyncModel.QueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor)
                Text(item.title)
                Spacer()
                Text(stageText)
                    .font(.caption)
                    .foregroundStyle(stageIsFailure ? .red : .secondary)
            }
            if let fraction = progressFraction {
                ProgressView(value: fraction)
                    .controlSize(.small)
            }
        }
    }

    private var stageIsFailure: Bool {
        if case .failed = item.stage { return true }
        return false
    }

    private var progressFraction: Double? {
        switch item.stage {
        case .converting(let fraction), .copying(let fraction): return fraction
        default: return nil
        }
    }

    private var stageText: String {
        switch item.stage {
        case .waiting: return "Waiting"
        case .probing: return "Analyzing…"
        case .converting(let fraction): return "Converting \(Int(fraction * 100))%"
        case .copying(let fraction): return "Copying \(Int(fraction * 100))%"
        case .updatingDatabase: return "Updating iTunesDB…"
        case .done: return "Done"
        case .failed(let message): return message
        }
    }

    private var symbol: String {
        switch item.stage {
        case .waiting: return "clock"
        case .probing, .converting, .copying, .updatingDatabase:
            return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var symbolColor: Color {
        switch item.stage {
        case .done: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

// MARK: - Video row

private struct VideoRowView: View {
    let video: IPodLibrary.Video

    var body: some View {
        HStack {
            Image(systemName: "film")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                Text("\(Formatters.duration(ms: video.durationMs)) · "
                   + Formatters.bytes(Int64(video.fileSize)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Banner

private struct BannerView: View {
    enum Style { case warning, error }

    let text: String
    let style: Style
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack {
            Image(systemName: style == .error
                  ? "exclamationmark.octagon.fill"
                  : "exclamationmark.triangle.fill")
            Text(text).lineLimit(3)
            Spacer()
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.link)
            }
            if let onDismiss {
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style == .error ? Color.red.opacity(0.12)
                                    : Color.yellow.opacity(0.15))
    }
}

// MARK: - Formatting

enum Formatters {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// 754_000 ms → "12:34"; hour-long videos get "1:02:03".
    static func duration(ms: UInt32) -> String {
        let seconds = Int(ms) / 1000
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

#Preview {
    ContentView()
}
