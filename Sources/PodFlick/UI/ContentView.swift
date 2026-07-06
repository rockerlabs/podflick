import SwiftUI

/// The app's own brand mark — media streams funneled down into a device tray —
/// used wherever the UI needs a device glyph, in place of Apple's "ipod" SF
/// Symbol, so PodFlick ships no Apple product artwork or trade dress. Vector-
/// drawn so it stays crisp at any size; a monochrome rendering of the app icon
/// `Design/icons/podflick-icon.svg` (coordinates mapped from its 1024 grid to 24).
struct BrandGlyph: View {
    var color: Color = .primary

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
            func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
                Path(roundedRect: .init(x: x * s, y: y * s, width: w * s, height: h * s),
                     cornerRadius: r * s)
            }
            // A downward funnel with soft corners. Rounded from a slightly
            // enlarged triangle so the corners are gentle AND the mouth stays
            // wide enough to meet the bars — all in the fill outline itself, with
            // no stroke (a same-color stroke reads as an outline at small sizes).
            let a = pt(4.3, 8.92), b = pt(19.75, 8.92), c = pt(12.02, 18.5)
            let funnelPath = CGMutablePath()
            funnelPath.move(to: CGPoint(x: (a.x + b.x) / 2, y: a.y))
            funnelPath.addArc(tangent1End: b, tangent2End: c, radius: 0.7 * s)
            funnelPath.addArc(tangent1End: c, tangent2End: a, radius: 0.7 * s)
            funnelPath.addArc(tangent1End: a, tangent2End: b, radius: 0.7 * s)
            funnelPath.closeSubpath()
            let funnel = Path(funnelPath)

            // Build the whole mark as one opaque-white silhouette first, so its
            // overlapping parts (funnel tip under the tray, bars over the funnel
            // mouth) never compound — which they would if `color` is translucent,
            // as .secondary is. The silhouette is recolored in a single pass below.
            let bars: [(CGFloat, CGFloat, CGFloat)] = [   // x, top-y, height
                (5.69, 5.96, 3.92), (9.43, 1.00, 3.51), (9.43, 5.96, 3.92),
                (13.16, 3.41, 3.64), (16.90, 2.32, 1.82), (16.90, 6.79, 3.10),
            ]
            for (x, y, h) in bars {
                ctx.fill(rrect(x, y, 1.46, h, 0.73), with: .color(.white))
            }
            ctx.fill(funnel, with: .color(.white))
            ctx.fill(rrect(3.55, 16.63, 16.94, 5.38, 1.37), with: .color(.white))

            // Cut the slot through the tray.
            ctx.blendMode = .destinationOut
            ctx.fill(rrect(9.74, 18.54, 4.55, 0.73, 0.36), with: .color(.black))

            // Recolor the silhouette uniformly, preserving its alpha (and the slot).
            ctx.blendMode = .sourceIn
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
        }
    }
}

/// Main window: device header, upload queue, and the on-device video list.
/// Dropping files anywhere in the window enqueues them.
struct ContentView: View {
    @ObservedObject var model: SyncModel
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
            emptyState("Connect an iPod",
                       "Plug in an iPod 5G/5.5G and it appears here.") {
                BrandGlyph(color: .secondary).frame(width: 56, height: 56)
            }
        } else if model.deviceVideos.isEmpty {
            emptyState("No videos on this iPod",
                       model.canAcceptDrops
                           ? "Drop video files anywhere in this window to upload them."
                           : "") {
                Image(systemName: "film")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
            }
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

    private func emptyState(_ title: String, _ subtitle: String,
                            @ViewBuilder icon: () -> some View) -> some View {
        VStack(spacing: 12) {
            icon()
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
    @State private var showingDeviceInfo = false

    var body: some View {
        HStack(spacing: 12) {
            BrandGlyph(color: model.selectedDevice == nil ? .secondary : .primary)
                .frame(width: 28, height: 28)
            if let device = model.selectedDevice {
                let rows = infoRows(for: device)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name).font(.headline)
                        if device.hasRockbox {
                            RockboxBadge(version: device.rockboxVersion)
                        }
                        if !rows.isEmpty {
                            Button {
                                showingDeviceInfo.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Device details")
                            .popover(isPresented: $showingDeviceInfo) {
                                DeviceInfoPopover(rows: rows)
                            }
                        }
                    }
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
        if let freeBytes = device.freeBytes {
            let free = "\(Formatters.bytes(freeBytes)) free"
            parts.append(device.totalBytes.map { "\(free) of \(Formatters.bytes($0))" } ?? free)
        }
        return parts.joined(separator: " · ")
    }

    /// Label/value pairs for the ⓘ popover; absent fields yield no row
    /// (DMRD's empty SysInfo shows only the volume format).
    private func infoRows(for device: IPodDevice) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let firmware = device.firmwareVersion { rows.append(("Firmware", firmware)) }
        if let serial = device.serialNumber { rows.append(("Serial", serial)) }
        if device.hasRockbox {
            rows.append(("Rockbox", device.rockboxVersion ?? "installed"))
        }
        if let format = device.volumeFormat { rows.append(("Format", format)) }
        return rows
    }
}

/// Small capsule next to the device name; the version (when the build
/// stamps one) rides in the tooltip and the ⓘ popover.
private struct RockboxBadge: View {
    let version: String?

    var body: some View {
        Text("Rockbox")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.orange)
            .background(Capsule().fill(.orange.opacity(0.15)))
            .help(version.map { "Rockbox \($0)" } ?? "Rockbox installed")
    }
}

private struct DeviceInfoPopover: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows, id: \.label) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary)
                    Text(row.value).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
        .padding(12)
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
                        QueueRowView(item: item, deviceLabel: deviceLabel(for: item))
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(12)
    }

    /// The destination iPod for a queued item — shown only when more than
    /// one device is connected, so a multi-iPod session can tell where each
    /// upload is bound. Single-device sessions have no ambiguity to resolve.
    private func deviceLabel(for item: SyncModel.QueueItem) -> String? {
        guard model.devices.count > 1 else { return nil }
        return model.device(for: item.targetVolume)?.name
    }
}

private struct QueueRowView: View {
    let item: SyncModel.QueueItem
    let deviceLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor)
                Text(item.title)
                if let deviceLabel {
                    Text("→ \(deviceLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.stage.label)
                    .font(.caption)
                    .foregroundStyle(stageIsFailure ? .red : .secondary)
            }
            // Only the item being processed shows the stepper — uploads run
            // one at a time, so waiting/done/failed rows stay a compact line.
            if let activeStep = item.stage.activeStep {
                PipelineStepper(activeStep: activeStep,
                                fraction: item.stage.stepFraction)
            }
        }
    }

    private var stageIsFailure: Bool {
        if case .failed = item.stage { return true }
        return false
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

/// The 1—2—3 pipeline strip under the in-progress queue row: a checked circle
/// per completed step, an accent ring on the active one, and the connectors
/// filling with the active step's fine progress.
private struct PipelineStepper: View {
    let activeStep: Int
    let fraction: Double?

    private var count: Int { SyncModel.Stage.stepTitles.count }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { step in
                node(step)
                if step < count - 1 {
                    connector(fill: fillOfConnector(after: step))
                }
            }
        }
        .frame(height: 16)
    }

    /// The connector between step `i` and `i+1` visualizes step `i+1`'s work,
    /// so both the convert and the copy phases fill their own segment: full
    /// once that step is done, filling with its fine progress while active,
    /// empty before it starts. The active step that reports no fraction (the
    /// brief DB-write tail of Copy) reads as full.
    private func fillOfConnector(after i: Int) -> Double {
        let phase = i + 1
        if activeStep > phase { return 1 }
        if activeStep == phase { return fraction ?? 1 }
        return 0
    }

    @ViewBuilder
    private func node(_ i: Int) -> some View {
        let isDone = i < activeStep
        let isActive = i == activeStep
        ZStack {
            Circle()
                .fill(isDone ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                .overlay(
                    Circle().strokeBorder(
                        isDone || isActive ? Color.accentColor
                                           : Color.secondary.opacity(0.5),
                        lineWidth: 1.5))
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(i + 1)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
        }
        .frame(width: 16, height: 16)
        .help(SyncModel.Stage.stepTitles[i])
    }

    private func connector(fill: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.3))
                Capsule().fill(Color.accentColor)
                    .frame(width: geo.size.width * max(0, min(1, fill)))
            }
        }
        .frame(height: 3)
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
    ContentView(model: SyncModel(observeVolumeMounts: false))
}
