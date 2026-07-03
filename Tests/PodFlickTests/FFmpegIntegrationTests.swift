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
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodFlickConvert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try FileManager.default.removeItem(at: workDir) }
    }

    /// 1s 320×240 test pattern + 440 Hz tone, with a source title tag that
    /// must NOT survive the conversion.
    private func makeSourceClip() throws -> URL {
        let source = workDir.appendingPathComponent("source clip.mp4")
        let generate = Process()
        generate.executableURL = tools.ffmpeg
        generate.arguments = [
            "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", "libx264", "-c:a", "aac",
            "-metadata", "title=legacy source title",
            "-loglevel", "error", "-y", source.path,
        ]
        try generate.run()
        generate.waitUntilExit()
        XCTAssertEqual(generate.terminationStatus, 0, "test clip generation failed")
        return source
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
            durationSeconds: sourceProbe.durationSeconds) { fractions.append($0) }

        // Progress fired, never ran backwards, and landed on 1.
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions, fractions.sorted())
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

    func testConvertFailureCleansUpAndReportsStderr() async throws {
        let source = workDir.appendingPathComponent("not-a-video.mp4")
        try Data("junk".utf8).write(to: source)
        let output = workDir.appendingPathComponent("out.m4v")

        do {
            try await IPodVideoConverter(tools: tools).convert(
                source, to: output, title: "X", durationSeconds: 1)
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
