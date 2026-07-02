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
