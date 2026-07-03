import AppKit

/// Clean-eject flow for an iPod volume, per the on-device-proven discipline
/// (docs/itunesdb-format.md, "Eject discipline"): flush file caches, mark the
/// volume `.metadata_never_index`, then unmount-and-eject with retries.
///
/// Spotlight's `mds_stores` often holds a freshly written iPod for a few
/// seconds. It runs as root, so an unprivileged app cannot kill it — the
/// marker plus patient retries are the in-app equivalent of the manual
/// "kill mds_stores and retry" workflow. Force-eject is never an option:
/// it risks corrupting the FAT32 volume mid-write.
struct IPodEjector: Sendable {

    struct EjectFailure: Error, CustomStringConvertible {
        let volumeName: String
        let attempts: Int
        let underlying: String

        var description: String {
            "could not eject \(volumeName) after \(attempts) attempts — "
            + "something (usually Spotlight indexing) is still using it; "
            + "wait a few seconds and try again. Never unplug without a "
            + "clean eject. (\(underlying))"
        }
    }

    var maxAttempts = 5
    var retryDelay: Duration = .seconds(1)

    /// Seams for tests. The real flow flushes the kernel's dirty file-cache
    /// pages (belt-and-braces — unmount flushes too) and asks NSWorkspace
    /// for a clean, never forced, unmount-and-eject.
    var flushFileCaches: @Sendable () -> Void = { sync() }
    var unmount: @Sendable (URL) throws -> Void = {
        try NSWorkspace.shared.unmountAndEjectDevice(at: $0)
    }

    func eject(volume: URL) async throws {
        try await blocking(flushFileCaches)
        discourageSpotlight(on: volume)
        var lastError = "no error reported"
        for attempt in 1...maxAttempts {
            do {
                return try await blocking { try unmount(volume) }
            } catch {
                lastError = error.localizedDescription
                if attempt < maxAttempts { try await Task.sleep(for: retryDelay) }
            }
        }
        throw EjectFailure(volumeName: volume.lastPathComponent,
                           attempts: maxAttempts, underlying: lastError)
    }

    /// `sync` and a dissented unmount block for seconds — too long to pin
    /// a width-limited cooperative-pool thread (and far too long for the
    /// main thread), so each attempt hops to a GCD thread for its duration.
    private func blocking<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// Best-effort `.metadata_never_index` marker: Spotlight skips volumes
    /// carrying it, which is what keeps FUTURE mounts eject-clean. Failure
    /// to write it must not block the eject itself, so errors are ignored.
    private func discourageSpotlight(on volume: URL) {
        let marker = volume.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
    }
}
