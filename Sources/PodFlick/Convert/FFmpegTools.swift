import Foundation

/// The external ffmpeg/ffprobe pair PodFlick shells out to.
///
/// A self-contained release bundles an LGPL ffmpeg (VideoToolbox encoder, no
/// x264) under `Contents/Resources/bin/` (see docs/bundling-ffmpeg.md); lookup
/// prefers that copy so the app works with no user setup. When it is absent —
/// a plain `swift build`, an unbundled dev build, or an OSS build that opted
/// out of bundling — lookup falls back to the session PATH and then the usual
/// package-manager prefixes (a Homebrew install). Finder-launched apps inherit
/// a minimal PATH, hence the explicit fallback prefixes.
struct FFmpegTools {

    let ffmpeg: URL
    let ffprobe: URL

    /// The bundled `bin/` directory inside the app's Resources, or nil when
    /// running outside an app bundle (e.g. the test host / `swift build`).
    /// Preferred over every other location so a self-contained release never
    /// depends on the user's PATH.
    static var bundledDirectory: String? {
        Bundle.main.resourceURL?.appendingPathComponent("bin").path
    }

    /// Install prefixes checked after PATH: Homebrew (arm64), Homebrew
    /// x86_64 / manual installs, MacPorts.
    static let fallbackDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    /// Finds both binaries, or nil when either is missing (the UI should
    /// then point the user at `brew install ffmpeg`). Search order is bundled
    /// dir → PATH → fallback prefixes; all three inputs are injectable so
    /// tests search only their temp tree.
    static func locate(
        bundled: String? = bundledDirectory,
        searchPATH: String? = ProcessInfo.processInfo.environment["PATH"],
        fallbacks: [String] = fallbackDirectories
    ) -> FFmpegTools? {
        let pathDirectories = searchPATH?.split(separator: ":").map(String.init) ?? []
        let directories = [bundled].compactMap { $0 } + pathDirectories + fallbacks
        guard let ffmpeg = find("ffmpeg", in: directories),
              let ffprobe = find("ffprobe", in: directories)
        else { return nil }
        return FFmpegTools(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    private static func find(_ name: String, in directories: [String]) -> URL? {
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
