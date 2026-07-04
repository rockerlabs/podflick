import Foundation

/// The `podflick://` URL scheme (declared in CFBundleURLTypes) — the entry
/// point for Shortcuts / Automator Quick Actions that hand the app files to
/// transfer without going through Finder's Services menu.
///
/// Shape: `podflick://transfer?path=/abs/one.mp4&path=/abs/two.mp4`. Each
/// `path` query item is one absolute filesystem path; percent-decoding is
/// handled by URLComponents. Parsing is pure so it can be unit-tested.
enum URLScheme {
    static let scheme = "podflick"

    /// The files a `podflick://` URL asks to transfer, or `[]` for any URL
    /// that isn't ours or carries no usable path.
    static func transferURLs(from url: URL) -> [URL] {
        guard url.scheme == scheme,
              let components = URLComponents(url: url,
                                             resolvingAgainstBaseURL: false)
        else { return [] }
        return (components.queryItems ?? [])
            .filter { $0.name == "path" }
            .compactMap(\.value)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }
}
