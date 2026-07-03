import XCTest
@testable import PodFlick

/// The full B.5 pipeline against real ffmpeg and a fake volume: drop →
/// probe → convert → copy → DB splice, then the failure path. This is the
/// closest a test gets to the device smoke without hardware.
@MainActor
final class SyncPipelineIntegrationTests: XCTestCase {

    private var tools: FFmpegTools!
    private var volumesRoot: URL!
    private var model: SyncModel!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let located = FFmpegTools.locate() else {
            throw XCTSkip("ffmpeg/ffprobe not installed")
        }
        tools = located
        volumesRoot = try makeTempDirectory(prefix: "PodFlickPipeline")

        try install(database: try fixture("iTunesDB.four-videos"),
                    onVolume: volumesRoot.appendingPathComponent("IPOD"))

        model = SyncModel(
            scanner: IPodDeviceScanner(volumesDirectory: volumesRoot),
            tools: tools, observeVolumeMounts: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: volumesRoot)
    }

    func testDroppedClipEndsUpConvertedOnVolumeAndInDB() async throws {
        let clip = try makeTestClip(
            tools: tools,
            at: volumesRoot.appendingPathComponent("My Test Movie.mp4"))

        model.enqueue([clip])
        await model.waitUntilQueueDrained()

        XCTAssertEqual(model.queue.map(\.stage), [.done])

        // The DB gained the track under the cleaned filename title.
        let videos = model.deviceVideos
        XCTAssertEqual(videos.count, 5)
        let added = try XCTUnwrap(videos.first { $0.title == "My Test Movie" })
        XCTAssertEqual(Double(added.durationMs) / 1000, 1.0, accuracy: 0.3)

        // The media file is a real iPod-spec conversion, not a raw copy.
        let library = IPodLibrary(volumeURL:
            volumesRoot.appendingPathComponent("IPOD"))
        let onDevice = library.url(forIPodPath: added.ipodPath)
        let probe = try await IPodVideoConverter(tools: tools).probe(onDevice)
        XCTAssertEqual(probe.videoCodec, "h264")
        XCTAssertEqual(probe.title, "My Test Movie")
        XCTAssertEqual(added.fileSize,
                       UInt32(try XCTUnwrap(onDevice.resourceValues(
                           forKeys: [.fileSizeKey]).fileSize)))

        // The strict parser accepts the DB the app wrote.
        XCTAssertNoThrow(try ITunesDB.parse(
            Data(contentsOf: library.databaseURL)))
    }

    func testJunkInputFailsItemAndLeavesDBUntouched() async throws {
        let library = IPodLibrary(volumeURL:
            volumesRoot.appendingPathComponent("IPOD"))
        let before = try Data(contentsOf: library.databaseURL)
        let junk = volumesRoot.appendingPathComponent("junk.mp4")
        try Data("not a video".utf8).write(to: junk)

        model.enqueue([junk])
        await model.waitUntilQueueDrained()

        guard case .failed = try XCTUnwrap(model.queue.first).stage else {
            return XCTFail("junk must fail, got \(model.queue[0].stage)")
        }
        XCTAssertEqual(try Data(contentsOf: library.databaseURL), before)
        XCTAssertEqual(model.deviceVideos.count, 4)
    }

    func testTwoDropsProcessSeriallyBothLand() async throws {
        let first = try makeTestClip(
            tools: tools, at: volumesRoot.appendingPathComponent("First.mp4"))
        let second = try makeTestClip(
            tools: tools, at: volumesRoot.appendingPathComponent("Second.mp4"))

        model.enqueue([first])
        model.enqueue([second])
        await model.waitUntilQueueDrained()

        XCTAssertEqual(model.queue.map(\.stage), [.done, .done])
        XCTAssertEqual(Set(model.deviceVideos.map(\.title))
            .intersection(["First", "Second"]).count, 2)
        XCTAssertEqual(model.deviceVideos.count, 6)
    }
}
