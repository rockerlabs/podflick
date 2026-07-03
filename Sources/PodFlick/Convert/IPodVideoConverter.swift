import Foundation

/// Transcodes arbitrary video into the iPod 5G/5.5G envelope: H.264 Baseline
/// ≤640×480 ≤1.5 Mbps ≤30fps + AAC-LC stereo, in an .m4v container
/// (docs/itunesdb-format.md, "Video file requirements").
///
/// The encoder settings are the on-device-proven recipe from
/// `reference/convert_to_ipod.sh` — keep the two in sync.
struct IPodVideoConverter {

    enum ConversionError: Error, Equatable {
        /// Non-zero exit; `detail` is the tail of the tool's stderr.
        case toolFailed(tool: String, status: Int32, detail: String)
    }

    let tools: FFmpegTools

    // MARK: - Probe

    func probe(_ input: URL) async throws -> VideoProbe {
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
    /// progress in [0, 1]. `durationSeconds` comes from `probe(_:)`.
    /// On failure or cancellation the half-written output is removed.
    func convert(_ input: URL, to output: URL, title: String,
                 durationSeconds: Double,
                 onProgress: @escaping (Double) -> Void = { _ in }) async throws {
        var parser = ProgressParser()
        do {
            let result = try await Self.run(
                tools.ffmpeg,
                arguments: Self.conversionArguments(input: input, output: output,
                                                    title: title)
            ) { line in
                parser.consume(line: line)
                onProgress(parser.fraction(ofTotal: durationSeconds))
            }
            guard result.status == 0 else {
                throw ConversionError.toolFailed(
                    tool: "ffmpeg", status: result.status, detail: result.stderrTail)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        onProgress(1)
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
            // Proven recipe — reference/convert_to_ipod.sh.
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
        let cleaned = String(String.UnicodeScalarView(
            stem.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    // MARK: - Progress stream

    /// Accumulates the `key=value` line stream of `ffmpeg -progress pipe:1`.
    struct ProgressParser {
        private(set) var outTimeSeconds: Double = 0
        private(set) var finished = false

        mutating func consume(line: String) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return }
            switch parts[0] {
            case "out_time_us", "out_time_ms":
                // Both fields are microseconds — out_time_ms is a misnamed
                // ffmpeg field, not milliseconds. Value is "N/A" until the
                // first frame lands, which Double(_:) rejects as intended.
                if let microseconds = Double(parts[1]) {
                    outTimeSeconds = microseconds / 1_000_000
                }
            case "progress":
                finished = parts[1] == "end"
            default:
                break
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
            let tail = String((try await stderrText).suffix(2000))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var status: Int32 = -1
            for await code in exitCodes { status = code }
            return (status, tail)
        } onCancel: {
            process.terminate()
        }
    }

    private static func collectText(_ handle: FileHandle) async throws -> String {
        var text = ""
        for try await line in handle.bytes.lines {
            text += line + "\n"
        }
        return text
    }
}
