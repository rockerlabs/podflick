import Foundation
@testable import PodFlick

/// Loads a golden fixture: real, firmware-accepted databases captured from
/// the operator's devices (see reference/fixtures/).
func fixture(_ name: String) throws -> Data {
    // Tests/PodFlickTests/<this file> -> repo root -> reference/fixtures
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PodFlickTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    return try Data(contentsOf: root
        .appendingPathComponent("reference/fixtures")
        .appendingPathComponent(name))
}

/// Creates a unique scratch directory for one test; the caller removes it
/// in tearDown/defer.
func makeTempDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url,
                                            withIntermediateDirectories: true)
    return url
}

struct TestClipError: Error {}

/// 1s 320×240 test pattern + 440 Hz tone at `url`, with a source title tag
/// that must NOT survive conversion. Shared by every ffmpeg-gated test.
func makeTestClip(tools: FFmpegTools, at url: URL) throws -> URL {
    let generate = Process()
    generate.executableURL = tools.ffmpeg
    generate.arguments = [
        "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=30",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
        "-c:v", "libx264", "-c:a", "aac",
        "-metadata", "title=legacy source title",
        "-loglevel", "error", "-y", url.path,
    ]
    try generate.run()
    generate.waitUntilExit()
    guard generate.terminationStatus == 0 else { throw TestClipError() }
    return url
}
