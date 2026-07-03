import XCTest
@testable import PodFlick

/// Pure-logic tests for the Convert layer — no ffmpeg binary needed.
/// End-to-end conversion runs in `FFmpegIntegrationTests`.
final class ConvertTests: XCTestCase {

    // MARK: - Conversion arguments

    /// Pins the invocation to the on-device-proven recipe
    /// (reference/convert_to_ipod.sh). A drift here is a firmware-facing
    /// change and needs a real-device re-proof before it lands.
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
            "-level", "3.0",
            "-pix_fmt", "yuv420p",
            "-vf", "scale=640:480:force_original_aspect_ratio=decrease,"
                 + "scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-b:v", "1200k",
            "-maxrate", "1500k",
            "-bufsize", "3000k",
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
            IPodVideoConverter.title(for: URL(fileURLWithPath: "/x/Кин-дза-дза 1.mkv")),
            "Кин-дза-дза 1")
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
             "profile": "Constrained Baseline", "width": 640, "height": 480},
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
