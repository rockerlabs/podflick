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
            struct Disposition: Decodable {
                var attachedPic: Int?
            }
            var codecType: String?
            var codecName: String?
            var profile: String?
            var width: Int?
            var height: Int?
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
