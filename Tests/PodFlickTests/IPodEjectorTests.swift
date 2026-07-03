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

    /// Thread-safe event log the @Sendable seams can append to.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func append(_ entry: String) {
            lock.lock(); defer { lock.unlock() }
            entries.append(entry)
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    private func makeEjector(log: EventLog, failFirst failures: Int,
                             maxAttempts: Int = 5) -> IPodEjector {
        var ejector = IPodEjector()
        ejector.maxAttempts = maxAttempts
        ejector.retryDelay = .milliseconds(1)
        ejector.flushFileCaches = { log.append("flush") }
        ejector.unmount = { _ in
            log.append("unmount")
            if log.all.filter({ $0 == "unmount" }).count <= failures {
                throw NSError(domain: "test", code: 1, userInfo:
                    [NSLocalizedDescriptionKey: "volume is busy"])
            }
        }
        return ejector
    }

    func testFlushesThenRetriesUntilUnmountSucceeds() async throws {
        let log = EventLog()
        try await makeEjector(log: log, failFirst: 2).eject(volume: volume)

        XCTAssertEqual(log.all, ["flush", "unmount", "unmount", "unmount"],
                       "one flush up front, then retries until success")
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            volume.appendingPathComponent(".metadata_never_index").path),
            "the Spotlight opt-out marker must be dropped on the volume")
    }

    func testGivesUpAfterMaxAttemptsAndNamesSpotlight() async throws {
        let log = EventLog()
        let ejector = makeEjector(log: log, failFirst: .max, maxAttempts: 3)

        do {
            try await ejector.eject(volume: volume)
            XCTFail("expected EjectFailure")
        } catch let failure as IPodEjector.EjectFailure {
            XCTAssertEqual(failure.attempts, 3)
            XCTAssertEqual(log.all.filter { $0 == "unmount" }.count, 3)
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

        try await makeEjector(log: EventLog(), failFirst: 0).eject(volume: volume)

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep me")
    }
}
