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
    var videoProfile: String?
    var width: Int?
    var height: Int?
    var audioCodec: String?
    var title: String?

    /// Decodes `ffprobe -print_format json -show_format -show_streams`
    /// output. Split from the process run so it is testable on captured JSON.
    static func decode(ffprobeJSON data: Data) throws -> VideoProbe {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try decoder.decode(RawProbe.self, from: data)

        let streams = raw.streams ?? []
        guard let video = streams.first(where: { $0.codecType == "video" }),
              let videoCodec = video.codecName
        else { throw ProbeError.noVideoStream }
        guard let text = raw.format?.duration, let duration = Double(text),
              duration > 0
        else { throw ProbeError.durationUnavailable }

        let audio = streams.first { $0.codecType == "audio" }
        return VideoProbe(
            durationSeconds: duration,
            videoCodec: videoCodec,
            videoProfile: video.profile,
            width: video.width,
            height: video.height,
            audioCodec: audio?.codecName,
            title: raw.format?.tags?["title"])
    }

    private struct RawProbe: Decodable {
        struct Stream: Decodable {
            var codecType: String?
            var codecName: String?
            var profile: String?
            var width: Int?
            var height: Int?
        }
        struct Format: Decodable {
            var duration: String?
            var tags: [String: String]?
        }
        var streams: [Stream]?
        var format: Format?
    }
}
