import Foundation

/// The external ffmpeg/ffprobe pair PodFlick shells out to. Deliberately not
/// bundled (licensing and size — see CLAUDE.md "Stack"); the user installs
/// them, typically via Homebrew.
///
/// Finder-launched apps inherit a minimal PATH, so lookup searches the
/// session PATH first and then the usual package-manager prefixes.
struct FFmpegTools {

    let ffmpeg: URL
    let ffprobe: URL

    /// Install prefixes checked after PATH: Homebrew (arm64), Homebrew
    /// x86_64 / manual installs, MacPorts.
    static let fallbackDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    /// Finds both binaries, or nil when either is missing (the UI should
    /// then point the user at `brew install ffmpeg`).
    static func locate(
        searchPATH: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) -> FFmpegTools? {
        let pathDirectories = searchPATH?.split(separator: ":").map(String.init) ?? []
        let directories = pathDirectories + fallbackDirectories
        guard let ffmpeg = find("ffmpeg", in: directories, fileManager: fileManager),
              let ffprobe = find("ffprobe", in: directories, fileManager: fileManager)
        else { return nil }
        return FFmpegTools(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    private static func find(_ name: String, in directories: [String],
                             fileManager: FileManager) -> URL? {
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
