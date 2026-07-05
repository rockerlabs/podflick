import Foundation
@testable import PodFlick

/// Loads a golden fixture: real, firmware-accepted databases captured from
/// the operator's devices (see reference/fixtures/). Track titles and the
/// device name were neutralized to placeholders ("Sample Video N",
/// "PodFlick reference iPod") before open-sourcing — titles via the proven
/// rename splice, the device name via a same-length in-place edit — so the
/// byte structure and firmware-acceptance are unchanged.
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

/// Writes `database` as the iTunesDB of a fake iPod volume, creating the
/// iPod_Control/iTunes tree. Shared by every test that fakes a device.
func install(database: Data, onVolume volume: URL) throws {
    let iTunesDir = volume.appendingPathComponent("iPod_Control/iTunes")
    try FileManager.default.createDirectory(
        at: iTunesDir, withIntermediateDirectories: true)
    try database.write(to: iTunesDir.appendingPathComponent("iTunesDB"))
}

/// Thread-safe recorder for @Sendable test seams (unmount spies, progress
/// callbacks) to append to from any thread.
final class Recorder<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    func append(_ element: Element) {
        lock.lock(); defer { lock.unlock() }
        elements.append(element)
    }

    var recorded: [Element] {
        lock.lock(); defer { lock.unlock() }
        return elements
    }
}

/// A one-shot async barrier that makes "an item is held in-flight" a
/// deterministic fact rather than a scheduling accident. The code under test
/// calls `arrive()`, which suspends until the test calls `release()`; the test
/// calls `waitUntilArrived()` to observe that the code has reached the barrier
/// before it asserts. Used to pin a queued upload mid-flight so `queueIsBusy`
/// is provably true when eject/orphan-cleanup refusal is checked.
actor AsyncBarrier {
    private var released = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var arrived = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?

    /// Awaited by the code under test — suspends until `release()`.
    func arrive() async {
        arrived = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { blocked = $0 }
    }

    /// Awaited by the test — returns once the code has reached `arrive()`.
    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    /// Lets the held (or a future) `arrive()` call proceed.
    func release() {
        released = true
        blocked?.resume()
        blocked = nil
    }
}

/// Stub `IPodEjector`: no real cache flush, near-zero retry delay, and an
/// unmount seam that records into `unmounts` and fails the first
/// `failFirst` attempts with a "volume is busy" error (`.max` = always).
func makeStubEjector(unmounts: Recorder<URL>, failFirst: Int = 0,
                     maxAttempts: Int = 5,
                     onFlush: @escaping @Sendable () -> Void = {}) -> IPodEjector {
    var ejector = IPodEjector()
    ejector.maxAttempts = maxAttempts
    ejector.retryDelay = .milliseconds(1)
    ejector.flushFileCaches = onFlush
    ejector.unmount = { url in
        unmounts.append(url)
        if unmounts.recorded.count <= failFirst {
            throw NSError(domain: "test", code: 1, userInfo:
                [NSLocalizedDescriptionKey: "volume is busy"])
        }
    }
    return ejector
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
