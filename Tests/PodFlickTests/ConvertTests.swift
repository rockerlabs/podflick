import XCTest
@testable import PodFlick

/// Pure-logic tests for the Convert layer — no ffmpeg binary needed.
/// End-to-end conversion runs in `FFmpegIntegrationTests`.
final class ConvertTests: XCTestCase {

    // MARK: - Conversion arguments

    /// Pins the invocation to the recipe proven on the real 5G during the
    /// B.5.1 smoke (320×240 L1.3 ≤768 kbps — the 5G decoder limit; the
    /// 640×480 L3.0 reference recipe played black). A drift here is a
    /// firmware-facing change and needs a real-device re-proof before it
    /// lands. With no source frame rate this exercises the unknown-rate
    /// default: `-r 30`, the firmware ceiling (B.4.1a).
    func testConversionArgumentsMatchProvenRecipe() {
        let arguments = IPodVideoConverter.conversionArguments(
            input: URL(fileURLWithPath: "/in/movie.mkv"),
            output: URL(fileURLWithPath: "/out/movie.m4v"),
            title: "Movie")

        XCTAssertEqual(arguments, [
            "-i", "/in/movie.mkv",
            "-map_metadata", "-1",
            "-metadata", "title=Movie",
            "-sn", "-dn",
            "-c:v", "libx264",
            "-profile:v", "baseline",
            "-level", "1.3",
            "-pix_fmt", "yuv420p",
            "-vf", "scale=320:240:force_original_aspect_ratio=decrease,"
                 + "scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-b:v", "700k",
            "-maxrate", "768k",
            "-bufsize", "1536k",
            "-r", "30",
            "-c:a", "aac",
            "-b:a", "128k",
            "-ar", "44100",
            "-ac", "2",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-nostats",
            "-loglevel", "error",
            "-y", "/out/movie.m4v",
        ])
    }

    /// Pins the opt-in 5.5G recipe (640×480 baseline L3.0 ≤1.5 Mbps —
    /// reference/convert_to_ipod.sh). Everything but the four decoder
    /// knobs must stay identical to the standard profile. Same rule as
    /// above: a drift is firmware-facing and needs a real-device re-proof.
    func testHighProfileArgumentsMatch55GRecipe() {
        let standard = IPodVideoConverter.conversionArguments(
            input: URL(fileURLWithPath: "/in/movie.mkv"),
            output: URL(fileURLWithPath: "/out/movie.m4v"),
            title: "Movie", profile: .standard)
        let high = IPodVideoConverter.conversionArguments(
            input: URL(fileURLWithPath: "/in/movie.mkv"),
            output: URL(fileURLWithPath: "/out/movie.m4v"),
            title: "Movie", profile: .high)

        var expected = standard
        expected[expected.firstIndex(of: "1.3")!] = "3.0"
        expected[expected.firstIndex(where: { $0.hasPrefix("scale=320:240") })!]
            = "scale=640:480:force_original_aspect_ratio=decrease,"
            + "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        expected[expected.firstIndex(of: "700k")!] = "1200k"
        expected[expected.firstIndex(of: "768k")!] = "1500k"
        expected[expected.firstIndex(of: "1536k")!] = "3000k"
        XCTAssertEqual(high, expected)
    }

    /// The default profile is the safe one — omitting the argument can
    /// never produce a file a 5G won't play.
    func testConversionArgumentsDefaultToStandardProfile() {
        let input = URL(fileURLWithPath: "/in/movie.mkv")
        let output = URL(fileURLWithPath: "/out/movie.m4v")
        XCTAssertEqual(
            IPodVideoConverter.conversionArguments(input: input, output: output,
                                                   title: "Movie"),
            IPodVideoConverter.conversionArguments(input: input, output: output,
                                                   title: "Movie", profile: .standard))
    }

    // MARK: - Frame rate

    /// A ≤30fps source is passed through at its exact native cadence — the
    /// whole point of B.4.1a. Forcing `-r 30` on 24/25fps duplicated every
    /// 5th/6th frame (pan judder).
    func testConversionArgumentsPassThroughSubThirtyFrameRate() {
        for rate in ["24/1", "25/1", "30000/1001", "30/1"] {
            let arguments = IPodVideoConverter.conversionArguments(
                input: URL(fileURLWithPath: "/in/movie.mkv"),
                output: URL(fileURLWithPath: "/out/movie.m4v"),
                title: "Movie", sourceFrameRate: rate)
            let r = arguments.firstIndex(of: "-r")!
            XCTAssertEqual(arguments[r + 1], rate, "expected native cadence for \(rate)")
        }
    }

    /// A >30fps source is capped at the firmware ceiling; unknown/unparseable
    /// rates fall back to the same safe default.
    func testConversionArgumentsCapAboveThirtyFrameRate() {
        for rate in ["60/1", "50/1", "60000/1001", "0/0", "N/A", ""] {
            let arguments = IPodVideoConverter.conversionArguments(
                input: URL(fileURLWithPath: "/in/movie.mkv"),
                output: URL(fileURLWithPath: "/out/movie.m4v"),
                title: "Movie", sourceFrameRate: rate)
            let r = arguments.firstIndex(of: "-r")!
            XCTAssertEqual(arguments[r + 1], "30", "expected 30fps cap for \(rate)")
        }
    }

    func testFrameRateArgumentBoundary() {
        // 30000/1001 ≈ 29.97 stays; 60000/1001 ≈ 59.94 caps.
        XCTAssertEqual(IPodVideoConverter.frameRateArgument(source: "30000/1001"),
                       "30000/1001")
        XCTAssertEqual(IPodVideoConverter.frameRateArgument(source: "60000/1001"), "30")
        // nil (no probe rate) and a zero denominator both fall back.
        XCTAssertEqual(IPodVideoConverter.frameRateArgument(source: nil), "30")
        XCTAssertEqual(IPodVideoConverter.frameRateArgument(source: "25/0"), "30")
    }

    func testEvaluateFraction() {
        XCTAssertEqual(IPodVideoConverter.evaluateFraction("30000/1001")!,
                       29.97, accuracy: 0.01)
        XCTAssertEqual(IPodVideoConverter.evaluateFraction("25/1"), 25)
        XCTAssertEqual(IPodVideoConverter.evaluateFraction("23.976"), 23.976)
        XCTAssertNil(IPodVideoConverter.evaluateFraction("30/0"))
        XCTAssertNil(IPodVideoConverter.evaluateFraction("N/A"))
    }

    // MARK: - Progress parsing

    func testProgressParserReadsMicroseconds() {
        var parser = IPodVideoConverter.ProgressParser()
        for line in ["frame=30", "fps=29.9", "out_time_us=1500000",
                     "out_time_ms=1500000", "out_time=00:00:01.500000",
                     "progress=continue"] {
            parser.consume(line: line)
        }
        XCTAssertEqual(parser.outTimeSeconds, 1.5)

        parser.consume(line: "out_time_us=3000000")
        XCTAssertEqual(parser.outTimeSeconds, 3.0)
    }

    func testProgressParserIgnoresGarbageAndNA() {
        var parser = IPodVideoConverter.ProgressParser()
        for line in ["out_time_us=N/A", "out_time_ms=N/A", "not a pair",
                     "", "=", "progress=continue"] {
            parser.consume(line: line)
        }
        XCTAssertEqual(parser.outTimeSeconds, 0)
    }

    func testProgressFractionClamps() {
        var parser = IPodVideoConverter.ProgressParser()
        XCTAssertEqual(parser.fraction(ofTotal: 0), 0)

        parser.consume(line: "out_time_us=5000000")
        XCTAssertEqual(parser.fraction(ofTotal: 10), 0.5)
        // Encoder can overshoot the probed duration by a frame or two.
        XCTAssertEqual(parser.fraction(ofTotal: 4), 1)
    }

    // MARK: - Title

    func testTitleIsFilenameStem() {
        XCTAssertEqual(
            IPodVideoConverter.title(for: URL(fileURLWithPath: "/x/Sample Movie 1.mkv")),
            "Sample Movie 1")
    }

    func testTitleStripsControlCharactersAndWhitespace() {
        XCTAssertEqual(
            IPodVideoConverter.title(for: URL(fileURLWithPath: "/x/ a\u{07}b\u{0D} .mp4")),
            "ab")
    }

    func testTitleNeverEmpty() {
        XCTAssertEqual(
            IPodVideoConverter.title(for: URL(fileURLWithPath: "/x/ \u{01}.mp4")),
            "Untitled")
    }

    // MARK: - Probe decoding

    private let sampleProbeJSON = Data("""
        {
          "streams": [
            {"codec_type": "video", "codec_name": "h264",
             "profile": "Constrained Baseline", "width": 640, "height": 480,
             "avg_frame_rate": "30000/1001"},
            {"codec_type": "audio", "codec_name": "aac"}
          ],
          "format": {"duration": "90.500000", "tags": {"title": "Old Title"}}
        }
        """.utf8)

    func testProbeDecoding() throws {
        let probe = try VideoProbe.decode(ffprobeJSON: sampleProbeJSON)
        XCTAssertEqual(probe, VideoProbe(
            durationSeconds: 90.5,
            videoCodec: "h264",
            videoProfile: "Constrained Baseline",
            width: 640,
            height: 480,
            frameRate: "30000/1001",
            audioCodec: "aac",
            title: "Old Title"))
    }

    func testProbeDecodingRejectsCoverArtAsVideo() {
        // MP3/M4A album art is a "video" stream with disposition
        // attached_pic — it must not defeat the audio-file rejection.
        let json = Data("""
            {"streams": [
               {"codec_type": "video", "codec_name": "png",
                "disposition": {"attached_pic": 1}},
               {"codec_type": "audio", "codec_name": "mp3"}],
             "format": {"duration": "10.0"}}
            """.utf8)
        XCTAssertThrowsError(try VideoProbe.decode(ffprobeJSON: json)) {
            XCTAssertEqual($0 as? VideoProbe.ProbeError, .noVideoStream)
        }
    }

    func testProbeDecodingRejectsAudioOnly() {
        let json = Data("""
            {"streams": [{"codec_type": "audio", "codec_name": "mp3"}],
             "format": {"duration": "10.0"}}
            """.utf8)
        XCTAssertThrowsError(try VideoProbe.decode(ffprobeJSON: json)) {
            XCTAssertEqual($0 as? VideoProbe.ProbeError, .noVideoStream)
        }
    }

    func testProbeDecodingRejectsMissingDuration() {
        let json = Data("""
            {"streams": [{"codec_type": "video", "codec_name": "h264"}],
             "format": {}}
            """.utf8)
        XCTAssertThrowsError(try VideoProbe.decode(ffprobeJSON: json)) {
            XCTAssertEqual($0 as? VideoProbe.ProbeError, .durationUnavailable)
        }
    }

    func testProbeFallsBackToStreamDuration() throws {
        // Unfinalized/piped WebM omits format.duration but the video stream
        // still reports one — the file converts fine, so it must be accepted.
        let json = Data("""
            {"streams": [{"codec_type": "video", "codec_name": "vp9",
                          "duration": "42.0"}],
             "format": {}}
            """.utf8)
        let probe = try VideoProbe.decode(ffprobeJSON: json)
        XCTAssertEqual(probe.durationSeconds, 42.0)
        XCTAssertEqual(probe.videoCodec, "vp9")
    }

    func testProbeFallsBackToStreamDurationTag() throws {
        // Last resort: the Matroska/WebM per-track DURATION tag
        // (HH:MM:SS.fraction), present even when both duration fields are not.
        let json = Data("""
            {"streams": [{"codec_type": "video", "codec_name": "vp9",
                          "tags": {"DURATION": "00:01:30.500000000"}}],
             "format": {}}
            """.utf8)
        let probe = try VideoProbe.decode(ffprobeJSON: json)
        XCTAssertEqual(probe.durationSeconds, 90.5)
    }

    // MARK: - Error mapping

    func testConversionErrorPromotesMissingLibx264() {
        // A static/conda ffmpeg without libx264 fails deep in the run — the
        // opaque "Unknown encoder" tail becomes an actionable case.
        XCTAssertEqual(
            IPodVideoConverter.conversionError(
                status: 234, stderrTail: "Unknown encoder 'libx264'\n"),
            .libx264Unavailable)
    }

    func testConversionErrorKeepsGenericToolFailure() {
        XCTAssertEqual(
            IPodVideoConverter.conversionError(
                status: 1, stderrTail: "moov atom not found"),
            .toolFailed(tool: "ffmpeg", status: 1, detail: "moov atom not found"))
    }

    // MARK: - Tool lookup

    func testLocateFindsBothToolsAcrossDirectories() throws {
        let root = try makeTempDirectory(prefix: "PodFlickTools")
        defer { try? FileManager.default.removeItem(at: root) }
        let binA = root.appendingPathComponent("a")
        let binB = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: binA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binB, withIntermediateDirectories: true)
        try makeExecutable(binA.appendingPathComponent("ffmpeg"))
        try makeExecutable(binB.appendingPathComponent("ffprobe"))

        let tools = FFmpegTools.locate(searchPATH: "\(binA.path):\(binB.path)",
                                       fallbacks: [])
        XCTAssertEqual(tools?.ffmpeg.path, binA.appendingPathComponent("ffmpeg").path)
        XCTAssertEqual(tools?.ffprobe.path, binB.appendingPathComponent("ffprobe").path)
    }

    func testLocateNeedsBothTools() throws {
        let root = try makeTempDirectory(prefix: "PodFlickTools")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(root.appendingPathComponent("ffmpeg"))
        // ffprobe missing → the pair is unusable. Empty fallbacks keep the
        // machine's real install out of the search.
        XCTAssertNil(FFmpegTools.locate(searchPATH: root.path, fallbacks: []))
    }

    private func makeExecutable(_ url: URL) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
    }
}
