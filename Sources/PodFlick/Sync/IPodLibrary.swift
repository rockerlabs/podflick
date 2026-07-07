import Foundation

/// The video library on one mounted iPod volume: list / add / rename /
/// remove, ported from reference/ipod_sync_v3.py's commands. The DB on the
/// device is the only source of truth — no manifest.
///
/// Every mutation backs up the live DB next to it first (the reference
/// behavior), splices in memory via ITunesDBWriter — whose strict re-parse
/// self-checks the splice before anything touches the device — and only
/// then replaces the on-device file atomically.
///
/// Callers must serialize mutations per volume: two concurrent
/// load-splice-write cycles would silently drop one of them (SyncModel
/// funnels everything through one actor).
struct IPodLibrary {

    let volumeURL: URL

    /// The bundled donor DB (the golden single-video fixture) that seeds a
    /// library with no donors of its own — an iPod whose every video was
    /// deleted. nil (no such resource, the unit-test default) restores the
    /// old behavior: adds to an empty library are rejected.
    var seedDatabaseURL: URL? = Bundle.main.url(
        forResource: "iTunesDB", withExtension: "single-video")

    var databaseURL: URL { IPodDevice.databaseURL(onVolume: volumeURL) }

    enum LibraryError: Error, Equatable, CustomStringConvertible {
        /// Titles are the dedup key (the reference skips such adds): two
        /// identical Videos-menu entries are indistinguishable on device.
        case duplicateTitle(String)
        /// FAT32 and the DB's u32 size field both cap files at 4 GiB.
        case fileTooLarge(Int64)
        case noFreeMediaName
        /// The donor-clone splice needs an existing track + playlist entry to
        /// clone; without a seed donor DB a library with none can't be seeded.
        case cannotAddToEmptyLibrary
        /// No master playlist at all — there is nothing to splice a playlist
        /// entry into, and PodFlick never builds playlist structure from
        /// scratch. Only a Finder/iTunes sync can rebuild one.
        case noMasterPlaylist

        var description: String {
            switch self {
            case .duplicateTitle(let title):
                return "'\(title)' is already on the iPod"
            case .fileTooLarge(let bytes):
                return "file is \(bytes) bytes — over the 4 GiB FAT32/DB limit"
            case .noFreeMediaName:
                return "could not find a free Music/FNN file name"
            case .cannotAddToEmptyLibrary:
                return "this iPod has no videos yet — add the first one with "
                     + "Finder/iTunes, then PodFlick can add more"
            case .noMasterPlaylist:
                return "this iPod's database has no master playlist — sync it "
                     + "once with Finder/iTunes to rebuild it"
            }
        }
    }

    /// One video track as the firmware sees it.
    struct Video: Identifiable, Equatable, Sendable {
        let id: UInt32              // track id
        var title: String
        let ipodPath: String        // ":iPod_Control:Music:F16:JHBI.m4v"
        let fileSize: UInt32
        let durationMs: UInt32
    }

    // MARK: - list

    /// Video tracks (media type 2 = movie) in DB order. Music tracks, if
    /// any ever appear, stay invisible to this video-only app.
    func videos() throws -> [Video] {
        try ITunesDB.parse(Data(contentsOf: databaseURL)).tracks
            .filter { $0.mediaType == 2 }
            .map(Video.init(track:))
    }

    // MARK: - add (two-phase: copy off the write queue, splice on it)

    /// Media copied to the device but not yet spliced into the DB — the
    /// output of `copyMedia`, the input to `commit`.
    struct Staged: Sendable {
        let url: URL
        let ipodPath: String
        let fileSize: UInt32
    }

    /// Cheap fast-fail before the (multi-GB) copy: reject a duplicate title
    /// against the current DB. `commit` re-checks authoritatively under the
    /// write lock, but this spares a gigabyte copy in the common case.
    func precheckAdd(title: String) throws {
        let db = try ITunesDB.parse(try Data(contentsOf: databaseURL))
        guard !db.tracks.contains(where: { $0.title == title }) else {
            throw LibraryError.duplicateTitle(title)
        }
        // The donor-clone splice needs a track and — since it clones into
        // EVERY master-playlist copy — an mhip to clone in each. An emptied
        // library supplies neither, but the bundled seed donor DB can; only
        // a DB with no master playlist at all stays unfixable. Reject an
        // unseedable DB BEFORE copying gigabytes (matches commit's per-master
        // requirement; commit re-validates authoritatively via ITunesDBWriter).
        guard !db.masterPlaylists.isEmpty else {
            throw LibraryError.noMasterPlaylist
        }
        _ = try seedDonor(for: db)
    }

    /// True when the DB cannot supply its own donors: no track to clone, or
    /// a master-playlist copy with no mhip left (both after "every video was
    /// deleted", the state a demo wipe leaves behind).
    private func needsSeed(_ db: ITunesDB) -> Bool {
        db.tracks.isEmpty || db.masterPlaylists.contains { $0.items.isEmpty }
    }

    /// Loads the bundled donor DB when the on-device DB needs seeding; nil
    /// when it can donate to itself. Validates the seed actually holds the
    /// donors the splice will clone, so a missing/unparseable/donor-less
    /// resource fails in precheckAdd — BEFORE the multi-GB copy, not after.
    /// Reading the 16 KB resource twice per seeded add is noise next to
    /// that copy.
    private func seedDonor(for db: ITunesDB) throws -> ITunesDBWriter.SeedDonor? {
        guard needsSeed(db) else { return nil }
        guard let url = seedDatabaseURL,
              let seed = try? ITunesDBWriter.SeedDonor(try Data(contentsOf: url)),
              !seed.db.tracks.isEmpty,
              seed.db.masterPlaylists.contains(where: { !$0.items.isEmpty }) else {
            throw LibraryError.cannotAddToEmptyLibrary
        }
        return seed
    }

    /// Phase 1 — no DB access, so the queued upload runs it OFF the write
    /// queue: copy the converted video into `iPod_Control/Music/FNN/XXXX.m4v`.
    /// The partial copy is removed on failure; the returned `Staged` feeds
    /// `commit`. `folder`/`filename` default to the reference's random picks;
    /// tests inject fixed values for determinism.
    func copyMedia(file: URL, folder: String? = nil, filename: String? = nil,
                   onProgress: @Sendable (Double) -> Void = { _ in }) throws -> Staged {
        let byteCount = try fileSize(of: file)
        guard let fileSize = UInt32(exactly: byteCount) else {
            throw LibraryError.fileTooLarge(byteCount)
        }
        let destination = try mediaDestination(
            folder: folder, filename: filename,
            fileExtension: file.pathExtension.isEmpty ? "m4v" : file.pathExtension)
        try FileManager.default.createDirectory(
            at: destination.url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do {
            try copy(file, to: destination.url, totalBytes: byteCount,
                     onProgress: onProgress)
        } catch {
            // A copy can throw mid-stream (a full/unplugged volume); its
            // partial output must not linger as an orphan.
            try? FileManager.default.removeItem(at: destination.url)
            throw error
        }
        return Staged(url: destination.url, ipodPath: destination.ipodPath,
                      fileSize: fileSize)
    }

    /// Phase 2 — the serialized one-mutator section: splice already-copied
    /// media into the DB. Re-checks the duplicate title (another add may have
    /// landed one since `precheckAdd`, as they serialize here, not there). On
    /// failure the caller removes `staged.url` — the DB never referenced it.
    @discardableResult
    func commit(staged: Staged, title: String, durationMs: UInt32,
                dbid: UInt64 = ITunesDBWriter.randomDBID(),
                itemDBID: UInt64 = ITunesDBWriter.randomDBID(),
                timestamp: UInt32 = ITunesDBWriter.macTimestampNow()) throws -> Video {
        var writer = try ITunesDBWriter(try Data(contentsOf: databaseURL))
        guard !writer.db.tracks.contains(where: { $0.title == title }) else {
            throw LibraryError.duplicateTitle(title)
        }
        let trackID = try writer.add(
            .init(title: title, ipodPath: staged.ipodPath,
                  fileSize: staged.fileSize, durationMs: durationMs),
            seed: try seedDonor(for: writer.db),
            dbid: dbid, itemDBID: itemDBID, timestamp: timestamp)
        try backUpDatabase()
        try writer.data.write(to: databaseURL, options: .atomic)
        deleteStalePlayCounts()
        return Video(id: trackID, title: title, ipodPath: staged.ipodPath,
                     fileSize: staged.fileSize, durationMs: durationMs)
    }

    /// Atomic copy+splice for callers that don't need the copy off the write
    /// queue (tests, any single-shot add). The queued upload path in SyncModel
    /// splits `copyMedia`/`commit` so the multi-GB copy never pins the mutator.
    @discardableResult
    func add(file: URL, title: String, durationMs: UInt32,
             folder: String? = nil, filename: String? = nil,
             dbid: UInt64 = ITunesDBWriter.randomDBID(),
             itemDBID: UInt64 = ITunesDBWriter.randomDBID(),
             timestamp: UInt32 = ITunesDBWriter.macTimestampNow(),
             onCopyProgress: @Sendable (Double) -> Void = { _ in }) throws -> Video {
        try precheckAdd(title: title)
        let staged = try copyMedia(file: file, folder: folder, filename: filename,
                                   onProgress: onCopyProgress)
        do {
            return try commit(staged: staged, title: title, durationMs: durationMs,
                              dbid: dbid, itemDBID: itemDBID, timestamp: timestamp)
        } catch {
            try? FileManager.default.removeItem(at: staged.url)
            throw error
        }
    }

    // MARK: - rename / remove

    func rename(trackID: UInt32, to newTitle: String) throws {
        var writer = try ITunesDBWriter(try Data(contentsOf: databaseURL))
        // Same invariant as add: titles are the dedup key, and two
        // identical Videos-menu entries are indistinguishable on device.
        guard !writer.db.tracks.contains(where: {
            $0.title == newTitle && $0.id != trackID
        }) else {
            throw LibraryError.duplicateTitle(newTitle)
        }
        try writer.rename(trackID: trackID, to: newTitle)
        try backUpDatabase()
        try writer.data.write(to: databaseURL, options: .atomic)
        deleteStalePlayCounts()
    }

    /// Removes the DB records first, then best-effort deletes the media
    /// file (the reference's order: a leftover file is invisible junk, a
    /// dangling DB entry is a broken menu item).
    func remove(trackID: UInt32) throws {
        var writer = try ITunesDBWriter(try Data(contentsOf: databaseURL))
        let path = writer.db.tracks.first { $0.id == trackID }?.path
        try writer.remove(trackID: trackID)
        try backUpDatabase()
        try writer.data.write(to: databaseURL, options: .atomic)
        deleteStalePlayCounts()
        if let path {
            try? FileManager.default.removeItem(at: url(forIPodPath: path))
        }
    }

    // MARK: - createPlaylist

    /// Creates a manual (non-master) playlist listing `trackIDs`, spliced into
    /// the on-disk DB with the same backup + atomic-write discipline as the
    /// other mutations. Returns the new playlist's persistentID; unknown track
    /// ids throw (via the writer). Playlist names are not deduped — unlike
    /// track titles they are not the Videos-menu key.
    @discardableResult
    func createPlaylist(title: String, trackIDs: [UInt32],
                        persistentID: UInt64 = ITunesDBWriter.randomDBID(),
                        timestamp: UInt32 = ITunesDBWriter.macTimestampNow()) throws -> UInt64 {
        var writer = try ITunesDBWriter(try Data(contentsOf: databaseURL))
        let pid = try writer.createPlaylist(
            title: title, trackIDs: trackIDs,
            persistentID: persistentID, timestamp: timestamp)
        try backUpDatabase()
        try writer.data.write(to: databaseURL, options: .atomic)
        deleteStalePlayCounts()
        return pid
    }

    /// ":iPod_Control:Music:F16:JHBI.m4v" → file URL on this volume.
    func url(forIPodPath path: String) -> URL {
        volumeURL.appendingPathComponent(Self.relativePath(forIPodPath: path))
    }

    /// ":iPod_Control:Music:F16:JHBI.m4v" → "iPod_Control/Music/F16/JHBI.m4v".
    private static func relativePath(forIPodPath path: String) -> String {
        path.split(separator: ":").joined(separator: "/")
    }

    // MARK: - Orphans

    /// A file under `iPod_Control/Music` that no DB track references —
    /// invisible to the firmware, pure dead weight (found in the wild:
    /// an 800 MB leftover from a pre-PodFlick experiment).
    struct Orphan: Identifiable, Equatable, Sendable {
        let url: URL
        let fileSize: Int64
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// Files under `Music/` unreferenced by ANY track — not just videos:
    /// a music track's file must never look orphaned. Path comparison is
    /// case-insensitive (FAT32); dot-prefixed entries are skipped (macOS
    /// recreates its `._*` AppleDouble metadata at will).
    func orphanedFiles() throws -> [Orphan] {
        // One canonical base for both sides: the enumerator hands back
        // symlink-resolved URLs (/var → /private/var) and a raw
        // volumeURL-based path would never string-match them. NOT
        // `resolvingSymlinksInPath()` — that one STRIPS the /private
        // prefix instead of adding it. No canonical path → no scan:
        // guessing a base here could flag the ENTIRE library as orphaned.
        guard let canonicalVolume = try? volumeURL.resourceValues(
            forKeys: [.canonicalPathKey]).canonicalPath else { return [] }
        let volume = URL(fileURLWithPath: canonicalVolume, isDirectory: true)
        let referenced = Set(
            try ITunesDB.parse(Data(contentsOf: databaseURL)).tracks
                .map { Self.comparablePath(volume.appendingPathComponent(
                    Self.relativePath(forIPodPath: $0.path)).path) })
        let musicDir = volume.appendingPathComponent("iPod_Control/Music",
                                                     isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        // skipsHiddenFiles keeps the walk out of hidden DIRECTORIES too (e.g.
        // a stray .Spotlight-V100 under Music): a non-dot regular file inside
        // one must never be flagged as an orphan and deleted.
        guard let files = FileManager.default.enumerator(
            at: musicDir, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return [] }

        var orphans: [Orphan] = []
        for case let file as URL in files {
            guard !file.lastPathComponent.hasPrefix("."),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  !referenced.contains(Self.comparablePath(file.path)) else { continue }
            orphans.append(Orphan(url: file, fileSize: Int64(values.fileSize ?? 0)))
        }
        return orphans.sorted { $0.url.path < $1.url.path }
    }

    /// Comparison form for "is this on-disk file the one the DB names":
    /// case-folded (FAT32 is case-insensitive) and Unicode-precomposed —
    /// HFS+ stores names decomposed (NFD) while DB strings may be NFC,
    /// and for a feature that DELETES on mismatch, a normalization miss
    /// must never manufacture an orphan.
    private static func comparablePath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Deletes an orphan and its `._*` AppleDouble sidecar — the scan
    /// skips those, so deletion owns them, keeping all AppleDouble
    /// knowledge in this one place.
    func delete(_ orphan: Orphan) throws {
        let fm = FileManager.default
        try fm.removeItem(at: orphan.url)
        try? fm.removeItem(at: orphan.url.deletingLastPathComponent()
            .appendingPathComponent("._" + orphan.name))
    }

    // MARK: - Media file placement

    private func mediaDestination(
        folder: String?, filename: String?, fileExtension: String
    ) throws -> (url: URL, ipodPath: String) {
        let musicDir = volumeURL.appendingPathComponent("iPod_Control/Music")
        // The reference's naming: F00–F49 + four random letters. Finder
        // itself spreads files this way; the folder split keeps FAT32
        // directories small.
        let bothFixed = folder != nil && filename != nil
        for _ in 0..<100 {
            let pickedFolder = folder ?? String(format: "F%02d", Int.random(in: 0..<50))
            let pickedName = filename ?? String((0..<4).map { _ in
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()!
            }) + "." + fileExtension
            let url = musicDir.appendingPathComponent(pickedFolder)
                .appendingPathComponent(pickedName)
            if !FileManager.default.fileExists(atPath: url.path) {
                return (url, ":iPod_Control:Music:\(pickedFolder):\(pickedName)")
            }
            // Injected fixed names never get a second draw — an occupied
            // name there is an error, not a retry.
            if bothFixed { break }
        }
        throw LibraryError.noFreeMediaName
    }

    // MARK: - Copy with progress

    /// FileManager.copyItem reports no progress, so multi-GB videos copy in
    /// chunks instead. The caller cleans up the destination on failure.
    private func copy(_ source: URL, to destination: URL, totalBytes: Int64,
                      onProgress: (Double) -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var copied: Int64 = 0
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            onProgress(totalBytes > 0 ? Double(copied) / Double(totalBytes) : 1)
        }
        // Flush to disk before `commit` writes a DB that references this file:
        // on an unclean pull (a flapping cable), the firmware must not find a
        // referenced media file whose bytes are still only in the page cache —
        // that leaves a broken entry orphan-cleanup can't reclaim (the DB
        // holds it). The eject flow's sync() is the belt; this is the braces.
        try output.synchronize()
        if totalBytes == 0 { onProgress(1) }
    }

    /// The firmware's `Play Counts` file indexes tracks by mhlt position, so a
    /// splice that shifts positions leaves it stale. iTunes deletes it after
    /// every sync and the firmware recreates it, so PodFlick deletes it after
    /// each DB write too (docs/itunesdb-format.md, proven behavior #6).
    /// Best-effort: a missing file is the normal case.
    private func deleteStalePlayCounts() {
        try? FileManager.default.removeItem(
            at: databaseURL.deletingLastPathComponent()
                .appendingPathComponent("Play Counts"))
    }

    // MARK: - Backup

    /// Timestamped copy next to the live DB, before every write (CLAUDE.md:
    /// "every mutation backs up the DB first — keep the behavior"). A
    /// counter suffix keeps rapid successive mutations from colliding
    /// within one second.
    /// How many timestamped backups to retain; older ones are pruned.
    private static let maxBackups = 10

    @discardableResult
    private func backUpDatabase() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let directory = databaseURL.deletingLastPathComponent()
        var counter = 0
        while true {
            let name = counter == 0 ? "iTunesDB.backup-\(stamp)"
                                    : "iTunesDB.backup-\(stamp)-\(counter)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.copyItem(at: databaseURL, to: candidate)
                pruneBackups(in: directory)
                return candidate
            }
            counter += 1
        }
    }

    /// Keep only the newest `maxBackups` backups (by modification time, so a
    /// same-second counter suffix can't sort the just-made one out). Unbounded
    /// backups would otherwise fill a space-limited FAT32 volume (and a failed
    /// write leaks one); losing an OLD backup is harmless. Best-effort.
    private func pruneBackups(in directory: URL) {
        let key: URLResourceKey = .contentModificationDateKey
        let backups = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [key])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("iTunesDB.backup-") }
        guard backups.count > Self.maxBackups else { return }
        let mtime = { (url: URL) in
            (try? url.resourceValues(forKeys: [key]))?.contentModificationDate
                ?? .distantPast
        }
        for stale in backups.sorted(by: { mtime($0) > mtime($1) })
                            .dropFirst(Self.maxBackups) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}

private extension IPodLibrary.Video {
    init(track: ITunesDB.Track) {
        self.init(id: track.id, title: track.title, ipodPath: track.path,
                  fileSize: track.fileSize, durationMs: track.durationMs)
    }
}
