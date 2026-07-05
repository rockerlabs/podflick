import AppKit

/// Backs the Finder right-click "Transfer to iPod" service (declared in
/// NSServices in the Info.plist). macOS instantiates the app if needed and
/// invokes `transferToIPod:userData:error:` on whatever object is registered
/// as `NSApp.servicesProvider`, passing the selected files on a pasteboard.
///
/// The object just extracts the file URLs and hands them off; all queueing,
/// device targeting and the single-mutator DB write live in the app model it
/// forwards to. The extraction is a pure static function so it can be tested
/// without the Services machinery.
final class ServiceProvider: NSObject {
    private let onFiles: @Sendable @MainActor ([URL]) -> Void

    init(onFiles: @escaping @Sendable @MainActor ([URL]) -> Void) {
        self.onFiles = onFiles
    }

    /// The NSMessage selector named in the Info.plist. AppKit delivers service
    /// messages on the main thread, so we forward synchronously (not via a
    /// Task hop) — a cold service launch is then classified against the same
    /// launch-phase timing as a podflick:// URL open, which is delivered
    /// synchronously too.
    @objc func transferToIPod(_ pasteboard: NSPasteboard,
                              userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = Self.fileURLs(from: pasteboard)
        guard !files.isEmpty else {
            error.pointee = "No video files to transfer." as NSString
            return
        }
        MainActor.assumeIsolated { onFiles(files) }
    }

    /// The file URLs the service was invoked on. Only real file URLs survive —
    /// anything else on the pasteboard is ignored.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: options) as? [URL] ?? []
        return urls.filter(\.isFileURL)
    }
}
