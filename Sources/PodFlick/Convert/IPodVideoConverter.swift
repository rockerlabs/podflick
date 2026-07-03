import Foundation

/// Transcodes arbitrary video into the iPod 5G envelope: H.264 Baseline
/// ≤320×240 ≤768 kbps ≤L1.3 ≤30fps + AAC-LC stereo, in an .m4v container
/// (docs/itunesdb-format.md, "Video file requirements").
///
/// This is deliberately the 5G limit, not the 5.5G one: it plays on both
/// generations, while `reference/convert_to_ipod.sh`'s 640×480 L3.0 output
/// gave a black screen on the real 5G (B.5.1 smoke, 2026-07-04).
struct IPodVideoConverter {

    enum ConversionError: Error, Equatable {
        /// Non-zero exit; `detail` is the tail of the tool's stderr.
        case toolFailed(tool: String, status: Int32, detail: String)
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
                 probe: VideoProbe,
                 onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        var parser = ProgressParser()
        var lastReported = -1.0
        do {
            let result = try await Self.run(
                tools.ffmpeg,
                arguments: Self.conversionArguments(input: input, output: output,
                                                    title: title)
            ) { line in
                parser.consume(line: line)
                let fraction = parser.fraction(ofTotal: probe.durationSeconds)
                if fraction != lastReported {
                    lastReported = fraction
                    onProgress(fraction)
                }
            }
            guard result.status == 0 else {
                throw ConversionError.toolFailed(
                    tool: "ffmpeg", status: result.status, detail: result.stderrTail)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        if lastReported != 1 { onProgress(1) }
    }

    /// The full ffmpeg invocation for one file. Pure, so tests can pin it
    /// against the proven recipe.
    static func conversionArguments(input: URL, output: URL,
                                    title: String) -> [String] {
        [
            "-i", input.path,
            // Legacy sources carry pre-UTF-8 tags (a Windows-1251 ©nam gave
            // Finder an empty title) — drop them all and write our own.
            "-map_metadata", "-1",
            "-metadata", "title=\(title)",
            // The firmware plays one video + one audio track; subtitle/data
            // streams would otherwise be muxed into the .m4v.
            "-sn", "-dn",
            // iPod 5G H.264 hardware-decoder limits: ≤320×240, baseline
            // ≤L1.3, ≤768 kbps. Every file proven playing on the device
            // fits this; the reference recipe's 640×480 L3.0 (the 5.5G
            // profile) decodes to a black screen on the 5G (B.5.1 smoke,
            // 2026-07-04). A per-device 5.5G profile is a backlog item.
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
            // Machine-readable progress on stdout; stderr stays errors-only
            // so a failure report is readable.
            "-progress", "pipe:1",
            "-nostats",
            "-loglevel", "error",
            "-y", output.path,
        ]
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
            async let stderrText = collectText(stderr.fileHandleForReading)
            for try await line in stdout.fileHandleForReading.bytes.lines {
                onLine(line)
            }
            // AsyncBytes completes an in-flight read at EOF without throwing,
            // so a cancel that already SIGTERMed the child would otherwise
            // surface as toolFailed(status: 15) instead of CancellationError.
            try Task.checkCancellation()
            let tail = String((try await stderrText).suffix(2000))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = await exitCodes.first { _ in true } ?? -1
            return (status, tail)
        } onCancel: {
            process.terminate()
        }
    }

    /// Keeps only a rolling tail: corrupt sources can flood stderr with a
    /// per-packet error line even at `-loglevel error`, and callers only
    /// ever report the last couple thousand characters.
    private static func collectText(_ handle: FileHandle) async throws -> String {
        let cap = 4096
        var text = ""
        for try await line in handle.bytes.lines {
            text += line + "\n"
            if text.count > cap {
                text.removeFirst(text.count - cap)
            }
        }
        return text
    }
}
