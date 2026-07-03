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

    private func makeModel(tools: FFmpegTools? = nil) -> SyncModel {
        SyncModel(scanner: IPodDeviceScanner(volumesDirectory: volumesRoot),
                  tools: tools, observeVolumeMounts: false)
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
