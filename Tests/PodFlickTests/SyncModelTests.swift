import XCTest
@testable import PodFlick

/// Queue/device-state logic without ffmpeg: fake volumes, injected (or nil)
/// tools, no mount observers. The happy upload path is covered by
/// SyncPipelineIntegrationTests.
@MainActor
final class SyncModelTests: XCTestCase {

    private var volumesRoot: URL!

    override func setUpWithError() throws {
        volumesRoot = try makeTempDirectory(prefix: "PodFlickSyncModel")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: volumesRoot)
    }

    @discardableResult
    private func makeVolume(_ name: String, sysInfoExtended: Bool = false,
                            database: Bool = true) throws -> URL {
        let volume = volumesRoot.appendingPathComponent(name)
        let control = volume.appendingPathComponent("iPod_Control")
        try FileManager.default.createDirectory(
            at: control.appendingPathComponent("Device"),
            withIntermediateDirectories: true)
        if sysInfoExtended {
            try Data("<plist/>".utf8).write(to: control
                .appendingPathComponent("Device/SysInfoExtended"))
        }
        if database {
            try install(database: try fixture("iTunesDB.four-videos"),
                        onVolume: volume)
        }
        return volume
    }

    private func makeModel(tools: FFmpegTools? = nil,
                           ejector: IPodEjector = IPodEjector()) -> SyncModel {
        SyncModel(scanner: IPodDeviceScanner(volumesDirectory: volumesRoot),
                  tools: tools, ejector: ejector, observeVolumeMounts: false)
    }

    // MARK: - Device selection

    func testSelectionPrefersSupportedDevice() throws {
        try makeVolume("ACLASSIC6G", sysInfoExtended: true)
        try makeVolume("ZIPOD")

        let model = makeModel()
        XCTAssertEqual(model.devices.count, 2)
        XCTAssertEqual(model.selectedDevice?.name, "ZIPOD",
                       "the hash-required device sorts first but must not win")
        XCTAssertEqual(model.deviceVideos.count, 4)
    }

    func testSelectionSurvivesRescanAndFallsBackWhenUnmounted() throws {
        let volume = try makeVolume("IPOD")
        let model = makeModel()
        XCTAssertEqual(model.selectedDevice?.name, "IPOD")

        model.refreshDevices()
        XCTAssertEqual(model.selectedDevice?.name, "IPOD")

        try FileManager.default.removeItem(at: volume)
        model.refreshDevices()
        XCTAssertNil(model.selectedDevice)
        XCTAssertTrue(model.deviceVideos.isEmpty)
    }

    // MARK: - Drop gating

    func testCanAcceptDropsRequiresToolsSupportAndDatabase() throws {
        try makeVolume("IPOD")
        let fakeTools = FFmpegTools(ffmpeg: URL(fileURLWithPath: "/bin/false"),
                                    ffprobe: URL(fileURLWithPath: "/bin/false"))

        XCTAssertFalse(makeModel(tools: nil).canAcceptDrops,
                       "no ffmpeg — no uploads")
        XCTAssertTrue(makeModel(tools: fakeTools).canAcceptDrops)

        try FileManager.default.removeItem(at: volumesRoot
            .appendingPathComponent("IPOD/iPod_Control/iTunes/iTunesDB"))
        let noDB = makeModel(tools: fakeTools)
        XCTAssertFalse(noDB.canAcceptDrops,
                       "donor-clone splicing cannot start from a missing DB")

        try makeVolume("CLASSIC6G", sysInfoExtended: true)
        try FileManager.default.removeItem(
            at: volumesRoot.appendingPathComponent("IPOD"))
        let unsupported = makeModel(tools: fakeTools)
        XCTAssertEqual(unsupported.selectedDevice?.name, "CLASSIC6G")
        XCTAssertFalse(unsupported.canAcceptDrops)
    }

    // MARK: - Queue

    func testEnqueueWithoutFFmpegFailsItemWithInstallHint() async throws {
        try makeVolume("IPOD")
        let model = makeModel(tools: nil)

        model.enqueue([volumesRoot.appendingPathComponent("whatever.mp4")])
        await model.waitUntilQueueDrained()

        XCTAssertEqual(model.queue.count, 1)
        guard case .failed(let message) = model.queue[0].stage else {
            return XCTFail("expected failure, got \(model.queue[0].stage)")
        }
        XCTAssertTrue(message.contains("ffmpeg"), message)
    }

    func testEnqueueIgnoresNonFileURLs() throws {
        try makeVolume("IPOD")
        let model = makeModel()

        model.enqueue([try XCTUnwrap(URL(string: "https://example.com/a.mp4"))])
        XCTAssertTrue(model.queue.isEmpty)
    }

    /// Drops and background (service/URL) transfers share the one queue but
    /// carry their origin so the app knows where to report progress (B.9).
    func testEnqueueTagsOriginDropVsBackground() throws {
        try makeVolume("IPOD")
        let model = makeModel(tools: nil)

        model.enqueue([volumesRoot.appendingPathComponent("a.mp4")])
        model.enqueueBackground([volumesRoot.appendingPathComponent("b.mp4")])

        XCTAssertEqual(model.queue.map(\.origin), [.drop, .background])
    }

    func testClearFinishedKeepsPendingItems() async throws {
        try makeVolume("IPOD")
        let model = makeModel(tools: nil)

        model.enqueue([volumesRoot.appendingPathComponent("a.mp4"),
                       volumesRoot.appendingPathComponent("b.mp4")])
        await model.waitUntilQueueDrained()
        XCTAssertEqual(model.queue.count, 2)

        model.clearFinished()
        XCTAssertTrue(model.queue.isEmpty)
    }

    // MARK: - Queue targets the enqueue-time device (B.13)

    /// The device is captured when the item is dropped; moving the picker
    /// afterwards must not retarget an already-queued upload.
    func testEnqueueCapturesTargetDeviceAndSelectionSwitchDoesNotMoveIt() throws {
        try makeVolume("APOD")
        try makeVolume("BPOD")
        let model = makeModel()
        let volA = try XCTUnwrap(model.devices.first { $0.name == "APOD" }?.volumeURL)
        let volB = try XCTUnwrap(model.devices.first { $0.name == "BPOD" }?.volumeURL)

        model.selectedVolume = volA
        model.enqueue([volumesRoot.appendingPathComponent("clip.mp4")])
        XCTAssertEqual(model.queue.first?.targetVolume, volA)

        model.selectedVolume = volB
        XCTAssertEqual(model.queue.first?.targetVolume, volA,
                       "switching the picker must not redirect a queued item")
    }

    /// If the enqueue-time device is gone by the item's turn, it fails with a
    /// clear message instead of diverting onto whatever is selected now (here
    /// the selection has fallen back to the still-connected BPOD).
    func testQueuedItemFailsWhenTargetDeviceIsGoneRatherThanRedirecting() async throws {
        let volA = try makeVolume("APOD")
        try makeVolume("BPOD")
        let fakeTools = FFmpegTools(ffmpeg: URL(fileURLWithPath: "/bin/false"),
                                    ffprobe: URL(fileURLWithPath: "/bin/false"))
        let model = makeModel(tools: fakeTools)
        model.selectedVolume = try XCTUnwrap(
            model.devices.first { $0.name == "APOD" }?.volumeURL)

        model.enqueue([volumesRoot.appendingPathComponent("clip.mp4")])
        // APOD vanishes before the worker (still on this actor) can run; the
        // selection falls back to BPOD.
        try FileManager.default.removeItem(at: volA)
        model.refreshDevices()
        XCTAssertEqual(model.selectedDevice?.name, "BPOD")

        await model.waitUntilQueueDrained()
        guard case .failed(let message) = model.queue[0].stage else {
            return XCTFail("expected failure, got \(model.queue[0].stage)")
        }
        XCTAssertTrue(message.contains("no longer connected"), message)
    }

    // MARK: - Eject

    func testEjectUnmountsSelectedVolume() async throws {
        let volume = try makeVolume("IPOD")
        let unmounts = Recorder<URL>()
        let model = makeModel(ejector: makeStubEjector(unmounts: unmounts))

        model.eject()
        XCTAssertTrue(model.isEjecting)
        await model.waitUntilEjectFinished()

        // The scanner reports /private/var/... where the test dir says
        // /var/... — compare symlink-resolved paths, not raw URLs.
        XCTAssertEqual(unmounts.recorded.map { $0.resolvingSymlinksInPath().path },
                       [volume.resolvingSymlinksInPath().path])
        XCTAssertFalse(model.isEjecting)
        XCTAssertNil(model.deviceError)
    }

    func testEjectFailureSurfacesDeviceError() async throws {
        try makeVolume("IPOD")
        let unmounts = Recorder<URL>()
        let model = makeModel(ejector: makeStubEjector(unmounts: unmounts,
                                                       failFirst: .max,
                                                       maxAttempts: 2))

        model.eject()
        await model.waitUntilEjectFinished()

        XCTAssertEqual(unmounts.recorded.count, 2, "maxAttempts retries")
        XCTAssertFalse(model.isEjecting)
        XCTAssertTrue(try XCTUnwrap(model.deviceError).contains("could not eject"))
    }

    func testEjectRefusedWhileQueueIsBusy() throws {
        try makeVolume("IPOD")
        let unmounts = Recorder<URL>()
        let model = makeModel(ejector: makeStubEjector(unmounts: unmounts))

        // Freshly enqueued items sit in .waiting until the worker's first
        // suspension resolves, so the queue is deterministically busy here.
        model.enqueue([volumesRoot.appendingPathComponent("a.mp4")])
        XCTAssertTrue(model.queueIsBusy)
        model.eject()

        XCTAssertFalse(model.isEjecting)
        XCTAssertTrue(unmounts.recorded.isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.deviceError).contains("uploads in progress"))
    }

    func testWriteQueueGateIsPerVolume() async throws {
        // Closing the gate for one ejecting volume must not block writes to a
        // different connected iPod.
        let queue = DeviceWriteQueue()
        let ejecting = URL(fileURLWithPath: "/Volumes/EJECTING")
        let other = URL(fileURLWithPath: "/Volumes/OTHER")
        await queue.close(volume: ejecting)

        do {
            _ = try await queue.run(volume: ejecting) { 1 }
            XCTFail("a write to the ejecting volume must be rejected")
        } catch is DeviceWriteQueue.ClosedForEject { /* expected */ }

        let onOther = try await queue.run(volume: other) { 42 }
        XCTAssertEqual(onOther, 42, "the other iPod must stay writable")

        await queue.reopen(volume: ejecting)
        let reopened = try await queue.run(volume: ejecting) { 7 }
        XCTAssertEqual(reopened, 7, "reopen restores writes to the volume")
    }

    // MARK: - Video profile

    func testSetVideoProfilePersistsOnDeviceAndRefreshesSnapshot() async throws {
        let volume = try makeVolume("IPOD")
        let model = makeModel()
        XCTAssertEqual(model.selectedDevice?.videoProfile, .standard)

        model.setVideoProfile(.high)
        await model.waitUntilDeviceWriteFinished()

        XCTAssertEqual(model.selectedDevice?.videoProfile, .high)
        XCTAssertEqual(DevicePrefs.load(volumeURL: volume).videoProfile, .high,
                       "the setting must live on the device, not in the app")
        XCTAssertNil(model.deviceError)

        // Back to safe — the sidecar is rewritten, not append-only.
        model.setVideoProfile(.standard)
        await model.waitUntilDeviceWriteFinished()
        XCTAssertEqual(DevicePrefs.load(volumeURL: volume).videoProfile, .standard)
    }

    // MARK: - Orphans

    func testOrphansPublishedOnReloadAndCleanedUpOnDemand() async throws {
        let volume = try makeVolume("IPOD")
        let musicDir = volume.appendingPathComponent("iPod_Control/Music/F35")
        try FileManager.default.createDirectory(
            at: musicDir, withIntermediateDirectories: true)
        let orphan = musicDir.appendingPathComponent("XEPQ.m4v")
        try Data(repeating: 0xEE, count: 500).write(to: orphan)
        let sidecar = musicDir.appendingPathComponent("._XEPQ.m4v")
        try Data("junk".utf8).write(to: sidecar)

        let model = makeModel()
        XCTAssertEqual(model.orphans.map { $0.url.path },
                       [try XCTUnwrap(orphan.resourceValues(
                           forKeys: [.canonicalPathKey]).canonicalPath)])
        XCTAssertEqual(model.deviceVideos.count, 4, "orphans don't hide videos")

        model.cleanUpOrphans()
        await model.waitUntilDeviceWriteFinished()

        XCTAssertTrue(model.orphans.isEmpty)
        XCTAssertNil(model.deviceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path),
                       "the AppleDouble sidecar goes with its file")
        XCTAssertEqual(model.deviceVideos.count, 4, "the library is untouched")
    }

    /// The banner's list can go stale between scan and click; entries
    /// that are no longer orphans by delete time (here: file already
    /// gone) must be skipped silently, not surfaced as errors.
    func testCleanUpSkipsEntriesThatAreNoLongerOrphans() async throws {
        let volume = try makeVolume("IPOD")
        let musicDir = volume.appendingPathComponent("iPod_Control/Music/F35")
        try FileManager.default.createDirectory(
            at: musicDir, withIntermediateDirectories: true)
        let orphan = musicDir.appendingPathComponent("XEPQ.m4v")
        try Data("x".utf8).write(to: orphan)

        let model = makeModel()
        XCTAssertEqual(model.orphans.count, 1)

        try FileManager.default.removeItem(at: orphan)
        model.cleanUpOrphans()
        await model.waitUntilDeviceWriteFinished()

        XCTAssertNil(model.deviceError,
                     "a stale entry is a no-op, not a failure")
        XCTAssertTrue(model.orphans.isEmpty)
    }

    // MARK: - Error rendering

    func testErrorMessagesAreHumanReadable() {
        XCTAssertEqual(
            SyncModel.message(for: VideoProbe.ProbeError.noVideoStream),
            "no video stream — this is not a video file")
        XCTAssertEqual(
            SyncModel.message(for: IPodLibrary.LibraryError.duplicateTitle("X")),
            "'X' is already on the iPod")
        XCTAssertTrue(SyncModel.message(for:
            IPodVideoConverter.ConversionError.toolFailed(
                tool: "ffmpeg", status: 1, detail: "boom"))
            .contains("exit 1"))
    }
}
