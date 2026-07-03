import Foundation

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
