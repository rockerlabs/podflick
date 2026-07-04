import AppKit
import Combine
import Foundation

/// Serializes every iTunesDB mutation in the session. Two concurrent
/// load-splice-write cycles on the same file would silently drop one of
/// them (e.g. a queue upload racing a user's remove), so adds, removes and
/// renames all funnel through this one actor.
///
/// The queue is also the eject gate: `close()` doubles as a barrier (the
/// actor is non-reentrant through the synchronous `run` body, so by the
/// time it returns any in-flight write has finished) and every later `run`
/// is rejected until `reopen()` — writers are excluded by the mechanism
/// they already funnel through, not by per-callsite flags.
actor DeviceWriteQueue {
    struct ClosedForEject: Error, CustomStringConvertible {
        var description: String {
            "eject in progress — reconnect the iPod to make changes"
        }
    }

    private var isClosed = false

    func run<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T {
        guard !isClosed else { throw ClosedForEject() }
        return try body()
    }

    func close() { isClosed = true }
    func reopen() { isClosed = false }
}

/// UI state for the whole app: connected devices, the upload queue with
/// per-item stages (probe → convert → copy → DB), and the on-device video
/// list. Uploads run one at a time — a single ffmpeg saturates the machine,
/// and DB writes must be serial anyway.
@MainActor
final class SyncModel: ObservableObject {

    enum Stage: Equatable {
        case waiting
        case probing
        case converting(Double)
        case copying(Double)
        case updatingDatabase
        case done
        case failed(String)

        var isFinished: Bool {
            if case .failed = self { return true }
            return self == .done
        }
    }

    struct QueueItem: Identifiable, Equatable {
        let id = UUID()
        let sourceURL: URL
        var title: String
        /// The device this item was dropped on, captured at enqueue time.
        /// `process` targets THIS volume, not the live selection, so
        /// switching the device picker mid-batch can't silently redirect a
        /// queued upload to the other iPod. nil only if nothing was selected
        /// when it was enqueued — the item then fails at its turn.
        let targetVolume: URL?
        var stage: Stage = .waiting
    }

    @Published private(set) var devices: [IPodDevice] = []
    @Published var selectedVolume: URL? {
        didSet { if selectedVolume != oldValue { reloadDeviceVideos() } }
    }
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var deviceVideos: [IPodLibrary.Video] = []
    /// Media files on the selected device that no DB track references.
    @Published private(set) var orphans: [IPodLibrary.Orphan] = []
    /// Last failed device read/write outside the queue (list load, remove,
    /// rename, eject); the queue reports its failures on the item instead.
    @Published var deviceError: String?
    @Published private(set) var ejectTask: Task<Void, Never>?
    /// Most recent remove/rename/prefs write; kept for the test hook below.
    private var deviceWriteTask: Task<Void, Never>?

    let tools: FFmpegTools?
    private let scanner: IPodDeviceScanner
    private let ejector: IPodEjector
    private let writeQueue = DeviceWriteQueue()
    private var worker: Task<Void, Never>?

    var isEjecting: Bool { ejectTask != nil }

    /// The connected device backing `volume`, or nil if none matches (the
    /// volume was ejected, or `volume` is nil). The one lookup shared by the
    /// live selection, per-item queue targeting, and the queue UI label.
    func device(for volume: URL?) -> IPodDevice? {
        guard let volume else { return nil }
        return devices.first { $0.volumeURL == volume }
    }

    var selectedDevice: IPodDevice? { device(for: selectedVolume) }

    /// Uploads need all three: the tools, a supported device, and an
    /// existing DB (donor-clone splicing cannot start from an empty one —
    /// the first sync of a fresh iPod must come from Finder).
    var canAcceptDrops: Bool {
        guard let device = selectedDevice, !isEjecting else { return false }
        return tools != nil && device.isSupported && device.databaseExists
    }

    /// True while any queued item is still moving toward the device.
    var queueIsBusy: Bool {
        queue.contains { !$0.stage.isFinished }
    }

    init(scanner: IPodDeviceScanner = IPodDeviceScanner(),
         tools: FFmpegTools? = FFmpegTools.locate(),
         ejector: IPodEjector = IPodEjector(),
         observeVolumeMounts: Bool = true) {
        self.scanner = scanner
        self.tools = tools
        self.ejector = ejector
        if observeVolumeMounts {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification,
                         NSWorkspace.didUnmountNotification,
                         NSWorkspace.didRenameVolumeNotification] {
                center.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in self?.refreshDevices() }
                }
            }
        }
        refreshDevices()
    }

    // MARK: - Devices

    func refreshDevices() {
        devices = scanner.scan()
        if let selectedVolume,
           devices.contains(where: { $0.volumeURL == selectedVolume }) {
            reloadDeviceVideos()    // still mounted; free space/DB may differ
        } else {
            self.selectedVolume =
                (devices.first(where: \.isSupported) ?? devices.first)?.volumeURL
        }
    }

    func reloadDeviceVideos() {
        guard let device = selectedDevice, device.isSupported,
              device.databaseExists else {
            deviceVideos = []
            orphans = []
            return
        }
        let library = IPodLibrary(volumeURL: device.volumeURL)
        do {
            deviceVideos = try library.videos()
            // Advisory, so a scan failure must not take the video list
            // down with it — no orphans shown beats no library shown.
            orphans = (try? library.orphanedFiles()) ?? []
        } catch {
            deviceVideos = []
            orphans = []
            deviceError = "Could not read iTunesDB: \(error)"
        }
    }

    // MARK: - Upload queue

    func enqueue(_ urls: [URL]) {
        let target = selectedVolume
        let incoming = urls.filter(\.isFileURL).map {
            QueueItem(sourceURL: $0, title: IPodVideoConverter.title(for: $0),
                      targetVolume: target)
        }
        guard !incoming.isEmpty else { return }
        queue.append(contentsOf: incoming)
        startWorkerIfIdle()
    }

    private func startWorkerIfIdle() {
        guard worker == nil else { return }
        worker = Task {
            await processQueue()
            worker = nil
            // An enqueue between processQueue's last empty-check and the
            // line above saw a live worker and didn't start one — without
            // this re-check its items would sit in .waiting forever.
            if queue.contains(where: { $0.stage == .waiting }) {
                startWorkerIfIdle()
            }
        }
    }

    func clearFinished() {
        queue.removeAll(where: \.stage.isFinished)
    }

    /// Test hook: resolves once every queued item has finished.
    func waitUntilQueueDrained() async {
        while let worker { await worker.value }
    }

    private func processQueue() async {
        while let next = queue.first(where: { $0.stage == .waiting }) {
            await process(next)
        }
    }

    private func process(_ item: QueueItem) async {
        let id = item.id
        func set(_ stage: Stage) { setStage(stage, for: id) }

        guard let tools else {
            set(.failed("ffmpeg not found — install it (brew install ffmpeg) and relaunch"))
            return
        }
        // Resolve the enqueue-time target against the current fleet, NOT the
        // live selection: the picker may have moved on to another iPod since
        // the drop. If that device is gone (or lost its DB) we fail the item
        // rather than divert it onto whatever is selected now.
        guard let device = device(for: item.targetVolume),
              device.isSupported, device.databaseExists else {
            set(.failed("the iPod this upload was queued for is no longer connected"))
            return
        }

        let converter = IPodVideoConverter(tools: tools)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodFlick-\(UUID().uuidString).m4v")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            set(.probing)
            let probe = try await converter.probe(item.sourceURL)

            set(.converting(0))
            try await converter.convert(item.sourceURL, to: temp,
                                        title: item.title,
                                        profile: device.videoProfile,
                                        probe: probe) { fraction in
                Task { @MainActor [weak self] in
                    self?.setStage(.converting(fraction), for: id)
                }
            }

            // The DB must carry the OUTPUT's duration and size, so re-probe
            // the converted file rather than trusting the source.
            let converted = try await converter.probe(temp)
            let durationMs = UInt32(min(converted.durationSeconds * 1000,
                                        Double(UInt32.max)).rounded())
            let convertedSize = Int64((try? temp.resourceValues(
                forKeys: [.fileSizeKey]).fileSize) ?? 0)
            // Scan-time free space is stale by now — re-inspect the volume.
            if let fresh = scanner.inspect(volume: device.volumeURL),
               !fresh.canFit(fileOfSize: convertedSize) {
                set(.failed("not enough free space on \(device.name)"))
                return
            }

            set(.copying(0))
            let library = IPodLibrary(volumeURL: device.volumeURL)
            let title = item.title
            _ = try await writeQueue.run {
                try library.add(file: temp, title: title,
                                durationMs: durationMs) { fraction in
                    Task { @MainActor [weak self] in
                        // The copy is done at 1; what remains is the DB write.
                        self?.setStage(fraction < 1 ? .copying(fraction)
                                                    : .updatingDatabase, for: id)
                    }
                }
            }
            set(.done)
        } catch {
            set(.failed(Self.message(for: error)))
        }
        // On success AND failure: free space moved either way, and a
        // failed copy can leave a fresh orphan the banner should show.
        refreshDevices()
    }

    private func setStage(_ stage: Stage, for id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }),
              // Progress callbacks hop to the main actor as detached Tasks
              // and can land AFTER the item finished — never regress a
              // final state to a stale "Copying 87%".
              !queue[index].stage.isFinished else { return }
        queue[index].stage = stage
    }

    // MARK: - Eject

    /// Sync + clean eject of the selected device (never forced). Refused
    /// while uploads run — an eject mid-copy would strand a half-written
    /// file. On success the didUnmount notification drives the device-list
    /// refresh; on failure nothing on the device changed.
    func eject() {
        guard let device = selectedDevice, !isEjecting else { return }
        guard !queueIsBusy else {
            deviceError = "uploads in progress — wait for the queue to finish before ejecting"
            return
        }
        deviceError = nil
        let volume = device.volumeURL
        ejectTask = Task {
            // close() is both the barrier for a remove/rename fired just
            // before the eject click and the gate rejecting writes for the
            // eject's duration.
            await writeQueue.close()
            do {
                try await ejector.eject(volume: volume)
            } catch {
                deviceError = "\(error)"
            }
            await writeQueue.reopen()   // other connected iPods stay writable
            ejectTask = nil
        }
    }

    /// Test hook: resolves once a running eject has finished.
    func waitUntilEjectFinished() async {
        while let ejectTask { await ejectTask.value }
    }

    // MARK: - Remove / rename / settings

    func remove(_ video: IPodLibrary.Video) {
        performDeviceWrite { try IPodLibrary(volumeURL: $0).remove(trackID: video.id) }
    }

    func rename(_ video: IPodLibrary.Video, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != video.title else { return }
        performDeviceWrite { try IPodLibrary(volumeURL: $0).rename(trackID: video.id, to: title) }
    }

    /// Persists the conversion profile for the SELECTED device (on the
    /// device itself, so it follows the hardware). Applies to conversions
    /// started after the change; a queued item still picks it up when its
    /// turn comes, because `process` re-resolves its target device from the
    /// live list per item (and this write refreshes that snapshot).
    /// No equality guard against the device snapshot: it goes stale while
    /// a write is in flight and would silently drop a quick second toggle.
    /// The write is idempotent and serialized by the queue anyway.
    func setVideoProfile(_ profile: VideoProfile) {
        performDeviceWrite { volume in
            var prefs = DevicePrefs.load(volumeURL: volume)
            prefs.videoProfile = profile
            try prefs.save(volumeURL: volume)
        }
    }

    /// Deletes the currently listed orphans — but only those that are
    /// STILL orphans by the time the write queue gets to us. The banner's
    /// list can go stale: a scan during an in-flight upload sees the
    /// half-copied file as unreferenced, and this deletion serializes
    /// BEHIND that upload's DB splice. Re-verifying inside the same
    /// queued transaction closes the race for good.
    func cleanUpOrphans() {
        let doomed = orphans
        guard !doomed.isEmpty else { return }
        performDeviceWrite { volume in
            let library = IPodLibrary(volumeURL: volume)
            let stillOrphaned = Set(try library.orphanedFiles().map(\.url))
            for orphan in doomed where stillOrphaned.contains(orphan.url) {
                try library.delete(orphan)
            }
        }
    }

    /// Runs one device write through the eject gate, surfaces its error,
    /// and rescans (list, free space and prefs may all have changed).
    private func performDeviceWrite(
        _ body: @escaping @Sendable (URL) throws -> Void
    ) {
        guard let device = selectedDevice else { return }
        let volume = device.volumeURL
        deviceWriteTask = Task {
            do {
                try await writeQueue.run { try body(volume) }
            } catch {
                deviceError = "\(error)"
            }
            refreshDevices()
        }
    }

    /// Test hook: resolves once the most recently started remove/rename/
    /// prefs write (and its rescan) has finished.
    func waitUntilDeviceWriteFinished() async {
        await deviceWriteTask?.value
    }

    // MARK: - Error rendering

    static func message(for error: Error) -> String {
        switch error {
        case let libraryError as IPodLibrary.LibraryError:
            return libraryError.description
        case VideoProbe.ProbeError.noVideoStream:
            return "no video stream — this is not a video file"
        case VideoProbe.ProbeError.durationUnavailable:
            return "the file reports no duration — re-mux it first"
        case IPodVideoConverter.ConversionError.libx264Unavailable:
            return "your ffmpeg has no libx264 encoder — reinstall it "
                 + "(brew install ffmpeg)"
        case IPodVideoConverter.ConversionError.toolFailed(let tool, let status, let detail):
            let tail = detail.isEmpty ? "" : ": \(detail.suffix(300))"
            return "\(tool) failed (exit \(status))\(tail)"
        case is CancellationError:
            return "cancelled"
        default:
            return "\(error)"
        }
    }
}
