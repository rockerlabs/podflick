import XCTest
@testable import PodFlick

/// Retry/marker logic on a fake volume; the real NSWorkspace unmount and
/// the kernel cache flush are replaced through the ejector's test seams.
final class IPodEjectorTests: XCTestCase {

    private var volume: URL!

    override func setUpWithError() throws {
        volume = try makeTempDirectory(prefix: "PodFlickEjector")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: volume)
    }

    func testFlushesOnceAndRetriesUntilUnmountSucceeds() async throws {
        let unmounts = Recorder<URL>()
        let flushes = Recorder<Void>()
        let ejector = makeStubEjector(unmounts: unmounts, failFirst: 2,
                                      onFlush: { flushes.append(()) })

        try await ejector.eject(volume: volume)

        XCTAssertEqual(flushes.recorded.count, 1)
        XCTAssertEqual(unmounts.recorded.count, 3,
                       "two busy failures, then success")
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            volume.appendingPathComponent(".metadata_never_index").path),
            "the Spotlight opt-out marker must be dropped on the volume")
    }

    func testGivesUpAfterMaxAttemptsAndNamesSpotlight() async throws {
        let unmounts = Recorder<URL>()
        let ejector = makeStubEjector(unmounts: unmounts, failFirst: .max,
                                      maxAttempts: 3)

        do {
            try await ejector.eject(volume: volume)
            XCTFail("expected EjectFailure")
        } catch let failure as IPodEjector.EjectFailure {
            XCTAssertEqual(failure.attempts, 3)
            XCTAssertEqual(unmounts.recorded.count, 3)
            XCTAssertTrue(failure.description.contains("Spotlight"),
                          failure.description)
            XCTAssertTrue(failure.description.contains("volume is busy"),
                          "the underlying unmount error must surface: "
                          + failure.description)
        }
    }

    func testExistingMarkerIsLeftUntouched() async throws {
        let marker = volume.appendingPathComponent(".metadata_never_index")
        try Data("keep me".utf8).write(to: marker)

        try await makeStubEjector(unmounts: Recorder<URL>())
            .eject(volume: volume)

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep me")
    }
}
