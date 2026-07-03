import AppKit
import Combine
import Foundation

/// Serializes every iTunesDB mutation in the session. Two concurrent
/// load-splice-write cycles on the same file would silently drop one of
/// them (e.g. a queue upload racing a user's remove), so adds, removes and
/// renames all funnel through this one actor.
actor DeviceWriteQueue {
    func run<T: Sendable>(_ body: @Sendable () throws -> T) rethrows -> T {
        try body()
    }
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
        var stage: Stage = .waiting
    }

    @Published private(set) var devices: [IPodDevice] = []
    @Published var selectedVolume: URL? {
        didSet { if selectedVolume != oldValue { reloadDeviceVideos() } }
    }
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var deviceVideos: [IPodLibrary.Video] = []
    /// Last failed device read/write outside the queue (list load, remove,
    /// rename); the queue reports its failures on the item instead.
    @Published var deviceError: String?

    let tools: FFmpegTools?
    private let scanner: IPodDeviceScanner
    private let writeQueue = DeviceWriteQueue()
    private var worker: Task<Void, Never>?

    var selectedDevice: IPodDevice? {
        devices.first { $0.volumeURL == selectedVolume }
    }

    /// Uploads need all three: the tools, a supported device, and an
    /// existing DB (donor-clone splicing cannot start from an empty one —
    /// the first sync of a fresh iPod must come from Finder).
    var canAcceptDrops: Bool {
        guard let device = selectedDevice else { return false }
        return tools != nil && device.isSupported && device.databaseExists
    }

    init(scanner: IPodDeviceScanner = IPodDeviceScanner(),
         tools: FFmpegTools? = FFmpegTools.locate(),
         observeVolumeMounts: Bool = true) {
        self.scanner = scanner
        self.tools = tools
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
            return
        }
        do {
            deviceVideos = try IPodLibrary(volumeURL: device.volumeURL).videos()
        } catch {
            deviceVideos = []
            deviceError = "Could not read iTunesDB: \(error)"
        }
    }

    // MARK: - Upload queue

    func enqueue(_ urls: [URL]) {
        let incoming = urls.filter(\.isFileURL).map {
            QueueItem(sourceURL: $0, title: IPodVideoConverter.title(for: $0))
        }
        guard !incoming.isEmpty else { return }
        queue.append(contentsOf: incoming)
        if worker == nil {
            worker = Task {
                await processQueue()
                worker = nil
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
        guard let device = selectedDevice, device.isSupported,
              device.databaseExists else {
            set(.failed("no writable iPod connected"))
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
                                        title: item.title, probe: probe) { fraction in
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
            refreshDevices()
        } catch {
            set(.failed(Self.message(for: error)))
        }
    }

    private func setStage(_ stage: Stage, for id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].stage = stage
    }

    // MARK: - Remove / rename

    func remove(_ video: IPodLibrary.Video) {
        performDeviceWrite { try $0.remove(trackID: video.id) }
    }

    func rename(_ video: IPodLibrary.Video, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != video.title else { return }
        performDeviceWrite { try $0.rename(trackID: video.id, to: title) }
    }

    private func performDeviceWrite(
        _ body: @escaping @Sendable (IPodLibrary) throws -> Void
    ) {
        guard let device = selectedDevice else { return }
        let library = IPodLibrary(volumeURL: device.volumeURL)
        Task {
            do {
                try await writeQueue.run { try body(library) }
            } catch {
                deviceError = "\(error)"
            }
            refreshDevices()
        }
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
