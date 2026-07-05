import Foundation

/// One `ffprobe` pass over an input file: the duration that drives the
/// conversion progress bar, plus the stream facts worth surfacing in the UI.
struct VideoProbe: Equatable {

    enum ProbeError: Error, Equatable {
        /// No video stream — an audio file or something stranger was
        /// dropped in; nothing to convert.
        case noVideoStream
        /// The container reports no duration; without it progress cannot be
        /// computed, and such inputs are suspect anyway.
        case durationUnavailable
    }

    var durationSeconds: Double
    var videoCodec: String
    var videoProfile: String? = nil
    var width: Int? = nil
    var height: Int? = nil
    /// Source frame rate as ffprobe's raw `avg_frame_rate` rational string
    /// (e.g. "30000/1001", "25/1"), or nil when the stream reports none.
    /// Kept verbatim so the converter can pass a ≤30fps source through at its
    /// exact native cadence rather than resampling it (see
    /// `IPodVideoConverter.frameRateArgument`).
    var frameRate: String? = nil
    var audioCodec: String? = nil
    var title: String? = nil

    /// Decodes `ffprobe -print_format json -show_format -show_streams`
    /// output. Split from the process run so it is testable on captured JSON.
    static func decode(ffprobeJSON data: Data) throws -> VideoProbe {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try decoder.decode(RawProbe.self, from: data)

        let streams = raw.streams ?? []
        // Embedded cover art (MP3/M4A album art) is reported as a "video"
        // stream too, distinguished only by disposition.attached_pic —
        // without this check an audio file with artwork passes as video.
        guard let video = streams.first(where: {
                  $0.codecType == "video" && $0.disposition?.attachedPic != 1
              }),
              let videoCodec = video.codecName
        else { throw ProbeError.noVideoStream }
        guard let duration = Self.duration(format: raw.format, videoStream: video)
        else { throw ProbeError.durationUnavailable }

        let audio = streams.first { $0.codecType == "audio" }
        return VideoProbe(
            durationSeconds: duration,
            videoCodec: videoCodec,
            videoProfile: video.profile,
            width: video.width,
            height: video.height,
            frameRate: video.avgFrameRate,
            audioCodec: audio?.codecName,
            title: raw.format?.tags?["title"])
    }

    /// Duration in seconds, or nil when no source reports one. Preferred is
    /// the container's own `format.duration`; unfinalized or piped
    /// WebM/Matroska omits it but still carries a per-stream `duration`
    /// (float seconds) or a `DURATION` tag (`HH:MM:SS.fraction`) — either
    /// lets progress compute, and such files convert fine, so they must not
    /// be rejected as durationUnavailable.
    private static func duration(format: RawProbe.Format?,
                                 videoStream: RawProbe.Stream) -> Double? {
        if let text = format?.duration, let d = Double(text), d > 0 { return d }
        if let text = videoStream.duration, let d = Double(text), d > 0 { return d }
        // `DURATION` has no underscore, so convertFromSnakeCase leaves the
        // tag key intact (unlike e.g. `major_brand` → `majorBrand`).
        if let text = videoStream.tags?["DURATION"],
           let d = parseHMS(text), d > 0 { return d }
        return nil
    }

    /// "00:00:10.500000000" → 10.5 seconds; nil on any malformed field.
    private static func parseHMS(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private struct RawProbe: Decodable {
        struct Stream: Decodable {
            struct Disposition: Decodable {
                var attachedPic: Int?
            }
            var codecType: String?
            var codecName: String?
            var profile: String?
            var width: Int?
            var height: Int?
            var avgFrameRate: String?
            var duration: String?
            var tags: [String: String]?
            var disposition: Disposition?
        }
        struct Format: Decodable {
            var duration: String?
            var tags: [String: String]?
        }
        var streams: [Stream]?
        var format: Format?
    }
}
