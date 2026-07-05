import Foundation

/// Transcodes arbitrary video into an iPod-playable .m4v: H.264 Baseline
/// ≤30fps + AAC-LC stereo (docs/itunesdb-format.md, "Video file
/// requirements"), sized per the target device's `VideoProfile` —
/// 320×240 by default, 640×480 for devices opted into the 5.5G profile.
struct IPodVideoConverter {

    enum ConversionError: Error, Equatable {
        /// Non-zero exit; `detail` is the tail of the tool's stderr.
        case toolFailed(tool: String, status: Int32, detail: String)
        /// The located ffmpeg was built without the VideoToolbox encoder —
        /// unusual on macOS (Homebrew ships it, and it is an Apple system
        /// framework) but possible with a misconfigured or non-macOS build,
        /// and it only shows up as an opaque encoder error deep in the run.
        /// Surfaced as its own case for an actionable hint.
        case videoToolboxUnavailable
    }

    let tools: FFmpegTools

    // MARK: - Probe

    func probe(_ input: URL) async throws -> VideoProbe {
        // Joining lines without newlines is safe: JSON forbids raw newlines
        // inside strings, so structure survives.
        var json = ""
        let result = try await Self.run(tools.ffprobe, arguments: [
            "-v", "error",
            "-print_format", "json",
            "-show_format", "-show_streams",
            input.path,
        ]) { json += $0 }
        guard result.status == 0 else {
            throw ConversionError.toolFailed(
                tool: "ffprobe", status: result.status, detail: result.stderrTail)
        }
        return try VideoProbe.decode(ffprobeJSON: Data(json.utf8))
    }

    // MARK: - Convert

    /// Writes the converted video to `output` (overwriting), reporting
    /// progress in [0, 1]. Requiring the `probe(_:)` result (rather than a
    /// bare duration) encodes the probe→convert ordering in the signature.
    /// On failure or cancellation the half-written output is removed.
    ///
    /// `onProgress` fires only when the fraction changes, on the
    /// stdout-reading task — UI consumers hop to the main actor themselves.
    func convert(_ input: URL, to output: URL, title: String,
                 profile: VideoProfile = .standard,
                 probe: VideoProbe,
                 onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        var parser = ProgressParser()
        var lastReported = -1.0
        do {
            let result = try await Self.run(
                tools.ffmpeg,
                arguments: Self.conversionArguments(input: input, output: output,
                                                    title: title, profile: profile,
                                                    sourceFrameRate: probe.frameRate)
            ) { line in
                parser.consume(line: line)
                let fraction = parser.fraction(ofTotal: probe.durationSeconds)
                if fraction != lastReported {
                    lastReported = fraction
                    onProgress(fraction)
                }
            }
            guard result.status == 0 else {
                throw Self.conversionError(status: result.status,
                                           stderrTail: result.stderrTail)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        if lastReported != 1 { onProgress(1) }
    }

    /// The full ffmpeg invocation for one file. Pure, so tests can pin it
    /// against the proven recipe. `sourceFrameRate` is the probe's raw
    /// `avg_frame_rate` string; see `frameRateArgument` for how it shapes `-r`.
    static func conversionArguments(input: URL, output: URL, title: String,
                                    profile: VideoProfile = .standard,
                                    sourceFrameRate: String? = nil) -> [String] {
        [
            "-i", input.path,
            // Legacy sources carry pre-UTF-8 tags (a Windows-1251 ©nam gave
            // Finder an empty title) — drop them all and write our own.
            "-map_metadata", "-1",
            "-metadata", "title=\(title)",
            // The firmware plays one video + one audio track; subtitle/data
            // streams would otherwise be muxed into the .m4v.
            "-sn", "-dn",
            // Hardware-decoder limits live in VideoProfile: the 5G-safe
            // default (≤320×240, baseline ≤L1.3, ≤768 kbps — proven in the
            // B.5.1 smoke) or the opt-in 5.5G envelope (≤640×480, ≤L3.0,
            // ≤1.5 Mbps — decodes BLACK on a real 5G).
            //
            // Encoder: Apple's h264_videotoolbox (B.15.1) rather than libx264
            // (GPL) so a bundled ffmpeg stays LGPL-only. VideoToolbox honours
            // `-profile:v baseline`/`-level` strictly — a headless probe of
            // both profiles confirms the muxed stream reports Baseline L1.3 /
            // L3.0, not a silently-upgraded Main. Re-proven on real hardware
            // (2026-07-05): 5G plays .standard; 5.5G plays both profiles —
            // identical behaviour to the libx264 output it replaces.
            "-c:v", "h264_videotoolbox",
            "-profile:v", "baseline",
            "-level", profile.h264Level,
            "-pix_fmt", "yuv420p",
            "-vf", "scale=\(profile.maxWidth):\(profile.maxHeight)"
                 + ":force_original_aspect_ratio=decrease,"
                 + "scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-b:v", profile.videoBitrate,
            "-maxrate", profile.videoMaxrate,
            "-bufsize", profile.videoBufsize,
            // The firmware caps playback at 30fps. A ≤30fps source is passed
            // through at its native cadence; forcing `-r 30` on a 24/25fps
            // source inserted duplicate frames on a fixed cadence (25→30
            // doubles every 5th frame) → pan judder (B.4.1a).
            "-r", frameRateArgument(source: sourceFrameRate),
            "-c:a", "aac",
            "-b:a", "128k",
            "-ar", "44100",
            "-ac", "2",
            "-movflags", "+faststart",
            // Machine-readable progress on stdout; stderr stays errors-only
            // so a failure report is readable.
            "-progress", "pipe:1",
            "-nostats",
            "-loglevel", "error",
            "-y", output.path,
        ]
    }

    /// The value for ffmpeg's `-r` given the source's raw `avg_frame_rate`
    /// string. A known rate in (0, 30] is returned verbatim so the output
    /// keeps the source's exact cadence (no resampling); anything above 30,
    /// unknown ("0/0"), or unparseable falls back to "30" — the firmware's
    /// playback ceiling and the safe default.
    static func frameRateArgument(source: String?) -> String {
        guard let source, let fps = evaluateFraction(source), fps > 0, fps <= 30
        else { return "30" }
        return source
    }

    /// Evaluates an ffprobe rational string ("30000/1001", "25/1") or a plain
    /// decimal to a Double; nil on a malformed field or a zero denominator.
    static func evaluateFraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            guard let n = Double(parts[0]), let d = Double(parts[1]), d != 0
            else { return nil }
            return n / d
        }
        return Double(text)
    }

    /// Maps a non-zero ffmpeg exit into a `ConversionError`. A build without
    /// the VideoToolbox encoder fails with `Unknown encoder
    /// 'h264_videotoolbox'` — promote that to `.videoToolboxUnavailable` so
    /// the UI can point the user at a real fix rather than dumping the raw
    /// stderr tail.
    static func conversionError(status: Int32, stderrTail: String) -> ConversionError {
        if stderrTail.contains("Unknown encoder 'h264_videotoolbox'") {
            return .videoToolboxUnavailable
        }
        return .toolFailed(tool: "ffmpeg", status: status, detail: stderrTail)
    }

    /// Filename stem → a clean UTF-8 title: control characters stripped,
    /// whitespace trimmed, never empty. Both the ©nam tag and (later) the
    /// DB title mhod need a value the firmware can render.
    static func title(for input: URL) -> String {
        let stem = input.deletingPathExtension().lastPathComponent
        let cleaned = stem.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    // MARK: - Progress stream

    /// Accumulates the `key=value` line stream of `ffmpeg -progress pipe:1`.
    struct ProgressParser {
        private(set) var outTimeSeconds: Double = 0

        mutating func consume(line: String) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0] == "out_time_us" || parts[0] == "out_time_ms"
            else { return }
            // Both fields are microseconds — out_time_ms is a misnamed
            // ffmpeg field, not milliseconds. Value is "N/A" until the
            // first frame lands, which Double(_:) rejects as intended.
            if let microseconds = Double(parts[1]) {
                outTimeSeconds = microseconds / 1_000_000
            }
        }

        func fraction(ofTotal durationSeconds: Double) -> Double {
            guard durationSeconds > 0 else { return 0 }
            return min(max(outTimeSeconds / durationSeconds, 0), 1)
        }
    }

    // MARK: - Process plumbing

    /// Runs a tool to completion, streaming stdout to `onLine`; cancellation
    /// terminates the child process.
    private static func run(
        _ tool: URL, arguments: [String],
        onLine: @escaping (String) -> Void
    ) async throws -> (status: Int32, stderrTail: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        // Buffers the exit code even when termination beats our iteration.
        let exitCodes = AsyncStream<Int32> { continuation in
            process.terminationHandler = {
                continuation.yield($0.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()

        return try await withTaskCancellationHandler {
            do {
                async let stderrText = collectText(stderr.fileHandleForReading)
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    onLine(line)
                }
                // AsyncBytes completes an in-flight read at EOF without
                // throwing, so a cancel that already SIGTERMed the child would
                // otherwise surface as toolFailed(status: 15) instead of
                // CancellationError.
                try Task.checkCancellation()
                let tail = String((try await stderrText).suffix(2000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let status = await exitCodes.first { _ in true } ?? -1
                return (status, tail)
            } catch {
                // A throw here (read error, an `onLine` that throws, or the
                // checkCancellation above) leaves the child running until it
                // happens to die on SIGPIPE — terminate it now so it is
                // always reaped. onCancel covers the cancellation path; this
                // covers every other throw.
                process.terminate()
                throw error
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// Keeps only a rolling tail: corrupt sources can flood stderr with a
    /// per-packet error line even at `-loglevel error`, and callers only
    /// ever report the last couple thousand characters.
    private static func collectText(_ handle: FileHandle) async throws -> String {
        // Byte-level rolling tail. Reading via `.lines` would buffer a
        // newline-less flood (a corrupt source can emit megabytes with no
        // newline) unbounded before the cap could apply, so accumulate raw
        // bytes and trim from the front, amortized O(1).
        let cap = 4096
        var buffer = Data()
        for try await byte in handle.bytes {
            buffer.append(byte)
            if buffer.count > cap * 2 { buffer.removeFirst(buffer.count - cap) }
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}
