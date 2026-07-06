import XCTest
@testable import PodFlick

/// End-to-end runs against the real ffmpeg/ffprobe binaries. Skipped when
/// they are not installed; on the dev machine they come from Homebrew.
/// The 1-second synthetic clip keeps each run well under a couple seconds.
final class FFmpegIntegrationTests: XCTestCase {

    private var tools: FFmpegTools!
    private var workDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let located = FFmpegTools.locate() else {
            throw XCTSkip("ffmpeg/ffprobe not installed")
        }
        tools = located
        workDir = try makeTempDirectory(prefix: "PodFlickConvert")
    }

    override func tearDownWithError() throws {
        if let workDir { try FileManager.default.removeItem(at: workDir) }
    }

    private func makeSourceClip() throws -> URL {
        try makeTestClip(tools: tools,
                         at: workDir.appendingPathComponent("source clip.mp4"))
    }

    func testProbeReadsRealFile() async throws {
        let source = try makeSourceClip()
        let probe = try await IPodVideoConverter(tools: tools).probe(source)

        XCTAssertEqual(probe.durationSeconds, 1.0, accuracy: 0.2)
        XCTAssertEqual(probe.videoCodec, "h264")
        XCTAssertEqual(probe.width, 320)
        XCTAssertEqual(probe.height, 240)
        XCTAssertEqual(probe.audioCodec, "aac")
        XCTAssertEqual(probe.title, "legacy source title")
    }

    func testConvertProducesSpecCompliantFileWithCleanTitle() async throws {
        let source = try makeSourceClip()
        let output = workDir.appendingPathComponent("converted.m4v")
        let converter = IPodVideoConverter(tools: tools)
        let sourceProbe = try await converter.probe(source)

        var fractions: [Double] = []
        try await converter.convert(
            source, to: output, title: "Чистый заголовок",
            probe: sourceProbe) { fractions.append($0) }

        // Progress fired, never repeated or ran backwards, and landed on 1.
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions, Array(Set(fractions)).sorted())
        XCTAssertEqual(fractions.last, 1)

        // Output is inside the 5.5G envelope (docs/itunesdb-format.md) and
        // carries our clean UTF-8 title instead of the source tag.
        let result = try await converter.probe(output)
        XCTAssertEqual(result.videoCodec, "h264")
        XCTAssertTrue(result.videoProfile?.contains("Baseline") == true,
                      "profile was \(result.videoProfile ?? "nil")")
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.width), 640)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.height), 480)
        XCTAssertEqual(result.audioCodec, "aac")
        XCTAssertEqual(result.title, "Чистый заголовок")
    }

    /// Every aspect ratio must convert to the profile's exact, macroblock-
    /// aligned box — pillar/letter-boxed — never an odd fitted size that
    /// h264_videotoolbox would code wider and hide behind an SPS crop the iPod's
    /// decoder ignores (the on-device garbling this recipe fixes). Portrait is
    /// the worst case (a 58 px right crop before the fix); landscape/ultrawide
    /// carried a smaller bottom crop; 4:3 already matched. All land on 320×240.
    func testEveryAspectRatioIsPaddedToExactProfileBox() async throws {
        let converter = IPodVideoConverter(tools: tools)
        for (label, size) in [("portrait", "540x960"), ("landscape", "1920x1080"),
                              ("ultrawide", "2560x1080"), ("standard", "640x480")] {
            let source = try makeTestClip(
                tools: tools,
                at: workDir.appendingPathComponent("\(label).mp4"),
                size: size)
            let output = workDir.appendingPathComponent("\(label).m4v")
            let probe = try await converter.probe(source)
            try await converter.convert(source, to: output, title: label, probe: probe)

            // Exactly 320×240 (not the fitted size) proves the pad ran;
            // display == coded here means a zero SPS crop.
            let result = try await converter.probe(output)
            XCTAssertEqual(result.width, 320, "\(label) width")
            XCTAssertEqual(result.height, 240, "\(label) height")
        }
    }

    func testCancelledConversionThrowsCancellationError() async throws {
        let source = try makeSourceClip()
        let output = workDir.appendingPathComponent("cancelled.m4v")
        let converter = IPodVideoConverter(tools: tools)
        let sourceProbe = try await converter.probe(source)

        let task = Task {
            try await converter.convert(source, to: output, title: "X",
                                        probe: sourceProbe)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled conversion must throw")
        } catch is CancellationError {
            // The user's cancel must not masquerade as an ffmpeg failure.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "cancelled output must be removed")
    }

    func testConvertFailureCleansUpAndReportsStderr() async throws {
        let source = workDir.appendingPathComponent("not-a-video.mp4")
        try Data("junk".utf8).write(to: source)
        let output = workDir.appendingPathComponent("out.m4v")

        // Junk can't be probed, so hand-build the probe result convert wants.
        let fakeProbe = VideoProbe(durationSeconds: 1, videoCodec: "h264")
        do {
            try await IPodVideoConverter(tools: tools).convert(
                source, to: output, title: "X", probe: fakeProbe)
            XCTFail("conversion of junk input must fail")
        } catch let IPodVideoConverter.ConversionError.toolFailed(tool, status, detail) {
            XCTAssertEqual(tool, "ffmpeg")
            XCTAssertNotEqual(status, 0)
            XCTAssertFalse(detail.isEmpty, "stderr detail should explain the failure")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "half-written output must be removed")
    }

    func testProbeFailureOnMissingFile() async throws {
        let missing = workDir.appendingPathComponent("missing.mp4")
        do {
            _ = try await IPodVideoConverter(tools: tools).probe(missing)
            XCTFail("probe of a missing file must fail")
        } catch let IPodVideoConverter.ConversionError.toolFailed(tool, _, _) {
            XCTAssertEqual(tool, "ffprobe")
        }
    }
}
