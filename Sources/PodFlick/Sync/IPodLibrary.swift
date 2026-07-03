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

    var databaseURL: URL { IPodDevice.databaseURL(onVolume: volumeURL) }

    enum LibraryError: Error, Equatable, CustomStringConvertible {
        /// Titles are the dedup key (the reference skips such adds): two
        /// identical Videos-menu entries are indistinguishable on device.
        case duplicateTitle(String)
        /// FAT32 and the DB's u32 size field both cap files at 4 GiB.
        case fileTooLarge(Int64)
        case noFreeMediaName

        var description: String {
            switch self {
            case .duplicateTitle(let title):
                return "'\(title)' is already on the iPod"
            case .fileTooLarge(let bytes):
                return "file is \(bytes) bytes — over the 4 GiB FAT32/DB limit"
            case .noFreeMediaName:
                return "could not find a free Music/FNN file name"
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

    // MARK: - add

    /// Copies a converted video into `iPod_Control/Music/FNN/XXXX.m4v` and
    /// splices it into the DB. The splice is computed BEFORE the copy so a
    /// bad DB (no donor, duplicate title) fails fast, not after gigabytes.
    ///
    /// `folder`/`filename` and the writer's ids default to the reference's
    /// random picks; tests inject fixed values for determinism.
    @discardableResult
    func add(file: URL, title: String, durationMs: UInt32,
             folder: String? = nil, filename: String? = nil,
             dbid: UInt64 = ITunesDBWriter.randomDBID(),
             itemDBID: UInt64 = ITunesDBWriter.randomDBID(),
             timestamp: UInt32 = ITunesDBWriter.macTimestampNow(),
             onCopyProgress: @Sendable (Double) -> Void = { _ in }) throws -> Video {
        var writer = try ITunesDBWriter(try Data(contentsOf: databaseURL))
        guard !writer.db.tracks.contains(where: { $0.title == title }) else {
            throw LibraryError.duplicateTitle(title)
        }
        let byteCount = try fileSize(of: file)
        guard let fileSize = UInt32(exactly: byteCount) else {
            throw LibraryError.fileTooLarge(byteCount)
        }

        let destination = try mediaDestination(
            folder: folder, filename: filename,
            fileExtension: file.pathExtension.isEmpty ? "m4v" : file.pathExtension)
        let trackID = try writer.add(
            .init(title: title, ipodPath: destination.ipodPath,
                  fileSize: fileSize, durationMs: durationMs),
            dbid: dbid, itemDBID: itemDBID, timestamp: timestamp)

        try FileManager.default.createDirectory(
            at: destination.url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try copy(file, to: destination.url, totalBytes: byteCount,
                 onProgress: onCopyProgress)
        do {
            try backUpDatabase()
            try writer.data.write(to: databaseURL, options: .atomic)
        } catch {
            // The DB never saw the track — don't leave an orphan media file.
            try? FileManager.default.removeItem(at: destination.url)
            throw error
        }
        return Video(id: trackID, title: title, ipodPath: destination.ipodPath,
                     fileSize: fileSize, durationMs: durationMs)
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
        if let path {
            try? FileManager.default.removeItem(at: url(forIPodPath: path))
        }
    }

    /// ":iPod_Control:Music:F16:JHBI.m4v" → file URL on this volume.
    func url(forIPodPath path: String) -> URL {
        volumeURL.appendingPathComponent(
            path.split(separator: ":").joined(separator: "/"))
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
        // prefix instead of adding it.
        let volume = URL(fileURLWithPath: (try? volumeURL.resourceValues(
            forKeys: [.canonicalPathKey]).canonicalPath) ?? volumeURL.path,
                         isDirectory: true)
        let referenced = Set(
            try ITunesDB.parse(Data(contentsOf: databaseURL)).tracks
                .map { volume.appendingPathComponent(
                    $0.path.split(separator: ":").joined(separator: "/")
                ).path.lowercased() })
        let musicDir = volume.appendingPathComponent("iPod_Control/Music",
                                                     isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(
            at: musicDir, includingPropertiesForKeys: Array(keys)) else { return [] }

        var orphans: [Orphan] = []
        for case let file as URL in files {
            guard !file.lastPathComponent.hasPrefix("."),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  !referenced.contains(file.path.lowercased()) else { continue }
            orphans.append(Orphan(url: file, fileSize: Int64(values.fileSize ?? 0)))
        }
        return orphans.sorted { $0.url.path < $1.url.path }
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
        if totalBytes == 0 { onProgress(1) }
    }

    // MARK: - Backup

    /// Timestamped copy next to the live DB, before every write (CLAUDE.md:
    /// "every mutation backs up the DB first — keep the behavior"). A
    /// counter suffix keeps rapid successive mutations from colliding
    /// within one second.
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
                return candidate
            }
            counter += 1
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
