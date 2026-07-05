import XCTest
@testable import PodFlick

/// Library tests run against a fake volume in a temp dir carrying a golden
/// fixture DB — the full add/rename/remove device flow without a device.
/// The key check: the on-disk DB the library writes is byte-identical to
/// what ITunesDBWriter produces for the same inputs (the library adds file
/// handling, never DB bytes).
final class IPodLibraryTests: XCTestCase {

    private var volume: URL!
    private var library: IPodLibrary!
    private var workDir: URL!

    private let dbid: UInt64 = 0x1122_3344_5566_7788
    private let itemDBID: UInt64 = 0x0102_0304_0506_0708
    private let timestamp: UInt32 = 3_800_000_000

    override func setUpWithError() throws {
        workDir = try makeTempDirectory(prefix: "PodFlickLibrary")
        volume = workDir.appendingPathComponent("IPOD")
        try install(database: try fixture("iTunesDB.four-videos"),
                    onVolume: volume)
        library = IPodLibrary(volumeURL: volume)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: workDir)
    }

    private func makeSourceFile(bytes: Int = 100_000) throws -> URL {
        let url = workDir.appendingPathComponent("converted.m4v")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private var onDeviceDB: Data {
        get throws { try Data(contentsOf: library.databaseURL) }
    }

    private var backups: [URL] {
        let iTunesDir = volume.appendingPathComponent("iPod_Control/iTunes")
        let names = (try? FileManager.default.contentsOfDirectory(
            at: iTunesDir, includingPropertiesForKeys: nil)) ?? []
        return names.filter { $0.lastPathComponent.hasPrefix("iTunesDB.backup-") }
    }

    // MARK: - list

    func testVideosListsFixtureTracks() throws {
        let videos = try library.videos()
        XCTAssertEqual(videos.count, 4)
        let known = try XCTUnwrap(videos.first { $0.title == "Sample Video 4" })
        XCTAssertTrue(known.ipodPath.hasPrefix(":iPod_Control:Music:"))
        XCTAssertGreaterThan(known.durationMs, 0)
        XCTAssertGreaterThan(known.fileSize, 0)
    }

    // MARK: - orphans

    /// Writes an empty file at `iPod_Control/Music/<folder>/<name>`.
    @discardableResult
    private func makeMediaFile(_ folder: String, _ name: String,
                               bytes: Int = 0) throws -> URL {
        let dir = volume.appendingPathComponent("iPod_Control/Music/\(folder)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0xEE, count: bytes).write(to: url)
        return url
    }

    func testOrphanedFilesFindsOnlyUnreferencedMedia() throws {
        // Materialize every DB-referenced file, in the on-disk case the
        // DB uses — none of these may show up as orphans.
        for video in try library.videos() {
            let file = library.url(forIPodPath: video.ipodPath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data("v".utf8).write(to: file)
        }
        let orphan = try makeMediaFile("F35", "XEPQ.m4v", bytes: 1234)
        try makeMediaFile("F35", "._XEPQ.m4v")     // AppleDouble junk
        try makeMediaFile("F00", ".hidden")        // dot-file junk

        let orphans = try library.orphanedFiles()
        // Orphan URLs come back canonicalized (/var → /private/var).
        XCTAssertEqual(orphans.map { $0.url.path },
                       [try XCTUnwrap(orphan.resourceValues(
                           forKeys: [.canonicalPathKey]).canonicalPath)])
        XCTAssertEqual(orphans.first?.fileSize, 1234)
    }

    /// FAT32 is case-insensitive: a referenced file whose on-disk case
    /// differs from the DB path must NOT be reported as an orphan.
    func testOrphanedFilesComparesPathsCaseInsensitively() throws {
        let referenced = try XCTUnwrap(try library.videos().first).ipodPath
        let lowercased = library.url(forIPodPath: referenced.lowercased())
        try FileManager.default.createDirectory(
            at: lowercased.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("v".utf8).write(to: lowercased)

        XCTAssertEqual(try library.orphanedFiles(), [])
    }

    func testOrphanedFilesEmptyWhenMusicDirMissing() throws {
        XCTAssertEqual(try library.orphanedFiles(), [])
    }

    // MARK: - add

    func testAddCopiesFileAndWritesWriterIdenticalDB() throws {
        let original = try onDeviceDB
        let source = try makeSourceFile()
        var progress: [Double] = []

        let video = try library.add(
            file: source, title: "tiny", durationMs: 90_000,
            folder: "F07", filename: "TEST.m4v",
            dbid: dbid, itemDBID: itemDBID, timestamp: timestamp) {
            progress.append($0)
        }

        // The media file landed where the DB path points.
        XCTAssertEqual(video.ipodPath, ":iPod_Control:Music:F07:TEST.m4v")
        let copied = library.url(forIPodPath: video.ipodPath)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: source))
        XCTAssertEqual(progress.last, 1)

        // The DB is byte-identical to a pure-writer splice: the library must
        // add file plumbing, never DB bytes of its own.
        var writer = try ITunesDBWriter(original)
        try writer.add(.init(title: "tiny", ipodPath: video.ipodPath,
                             fileSize: 100_000, durationMs: 90_000),
                       dbid: dbid, itemDBID: itemDBID, timestamp: timestamp)
        XCTAssertEqual(try onDeviceDB, writer.data)

        // Pre-mutation state was backed up (the reference behavior).
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)

        // And the library sees the new video.
        XCTAssertEqual(try library.videos().count, 5)
    }

    func testCopyMediaStagesFileWithoutTouchingDB() throws {
        // Phase 1 must not write the DB — that is what lets it run off the
        // write queue (B.17 #1). The splice happens only in `commit`.
        let source = try makeSourceFile()
        let dbBeforeCopy = try onDeviceDB

        let staged = try library.copyMedia(file: source, folder: "F07",
                                           filename: "TEST.m4v")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))
        XCTAssertEqual(staged.ipodPath, ":iPod_Control:Music:F07:TEST.m4v")
        XCTAssertEqual(try onDeviceDB, dbBeforeCopy, "copy must not touch the DB")
        XCTAssertTrue(backups.isEmpty, "no backup before the splice")

        let video = try library.commit(staged: staged, title: "two-phase",
                                       durationMs: 1_000, dbid: dbid,
                                       itemDBID: itemDBID, timestamp: timestamp)
        XCTAssertEqual(video.ipodPath, staged.ipodPath)
        XCTAssertEqual(video.fileSize, staged.fileSize)
        XCTAssertTrue(try library.videos().contains { $0.id == video.id })
        XCTAssertFalse(backups.isEmpty, "commit backs up before writing")
    }

    func testCommitFailureLeavesStagedFileForCaller() throws {
        // commit does NOT own the staged file: on a failed splice the caller
        // (SyncModel) removes it. Here an already-present title trips commit's
        // authoritative duplicate check.
        let source = try makeSourceFile()
        let staged = try library.copyMedia(file: source, folder: "F07",
                                           filename: "TEST.m4v")
        XCTAssertThrowsError(try library.commit(
            staged: staged, title: "Sample Video 4", durationMs: 1_000)) { error in
            XCTAssertEqual(error as? IPodLibrary.LibraryError,
                           .duplicateTitle("Sample Video 4"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path),
                      "commit leaves the staged file for the caller to clean up")
    }

    func testAddWithRandomPlacementFollowsReferenceNaming() throws {
        let source = try makeSourceFile()
        let video = try library.add(file: source, title: "random spot",
                                    durationMs: 1_000)

        XCTAssertNotNil(video.ipodPath.range(
            of: #"^:iPod_Control:Music:F[0-4][0-9]:[A-Z]{4}\.m4v$"#,
            options: .regularExpression),
            "path was \(video.ipodPath)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: library.url(forIPodPath: video.ipodPath).path))
    }

    func testAddDuplicateTitleThrowsAndLeavesVolumeUntouched() throws {
        let original = try onDeviceDB
        let source = try makeSourceFile()

        XCTAssertThrowsError(try library.add(
            file: source, title: "Sample Video 4", durationMs: 1_000)) { error in
            XCTAssertEqual(error as? IPodLibrary.LibraryError,
                           .duplicateTitle("Sample Video 4"))
        }
        XCTAssertEqual(try onDeviceDB, original)
        XCTAssertTrue(backups.isEmpty)
    }

    func testAddOver4GiBFileThrows() throws {
        // A sparse 5 GiB file: instant on APFS, but reports its logical size.
        let source = workDir.appendingPathComponent("huge.m4v")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 5 << 30)
        try handle.close()

        XCTAssertThrowsError(try library.add(
            file: source, title: "huge", durationMs: 1_000)) { error in
            XCTAssertEqual(error as? IPodLibrary.LibraryError,
                           .fileTooLarge(5 << 30))
        }
    }

    func testAddFailsFastWithoutCopyWhenDBHasNoDonor() throws {
        // A DB whose only track was removed has no donor to clone — the
        // splice must fail BEFORE any bytes are copied to the volume.
        var writer = try ITunesDBWriter(try fixture("iTunesDB.single-video"))
        let onlyTrack = try XCTUnwrap(writer.db.tracks.first)
        try writer.remove(trackID: onlyTrack.id)
        try install(database: writer.data, onVolume: volume)

        let source = try makeSourceFile()
        XCTAssertThrowsError(try library.add(
            file: source, title: "orphan", durationMs: 1_000,
            folder: "F07", filename: "TEST.m4v")) { error in
            // Must be the pre-copy guard, not a post-copy writer failure — the
            // error identity pins that it failed BEFORE any bytes were copied.
            XCTAssertEqual(error as? IPodLibrary.LibraryError, .cannotAddToEmptyLibrary)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("iPod_Control/Music/F07/TEST.m4v").path))
        XCTAssertEqual(try onDeviceDB, writer.data)
    }

    func testAddFailsCleanlyWhenCopyThrows() throws {
        // A directory passed as the source opens but cannot be read as a
        // file, so `copy` raises. The add must abort with the DB, backups,
        // and media file all untouched — the same catch that guards a
        // mid-stream copy failure (a volume yanked while copying) from
        // leaving a half-written orphan behind.
        let original = try onDeviceDB
        let badSource = workDir.appendingPathComponent("not-a-file.m4v")
        try FileManager.default.createDirectory(
            at: badSource, withIntermediateDirectories: true)

        XCTAssertThrowsError(try library.add(
            file: badSource, title: "half", durationMs: 1_000,
            folder: "F07", filename: "TEST.m4v"))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent(
                "iPod_Control/Music/F07/TEST.m4v").path),
            "a copy failure must not leave a media file behind")
        XCTAssertEqual(try onDeviceDB, original)
        XCTAssertTrue(backups.isEmpty, "no backup or DB write after a failed copy")
    }

    // MARK: - remove

    func testAddThenRemoveRestoresFixtureAndDeletesFile() throws {
        let original = try onDeviceDB
        let source = try makeSourceFile()
        let video = try library.add(file: source, title: "tiny",
                                    durationMs: 90_000,
                                    folder: "F07", filename: "TEST.m4v",
                                    dbid: dbid, itemDBID: itemDBID,
                                    timestamp: timestamp)

        try library.remove(trackID: video.id)

        XCTAssertEqual(try onDeviceDB, original,
                       "add + remove must round-trip to the fixture bytes")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: library.url(forIPodPath: video.ipodPath).path))
        XCTAssertEqual(try library.videos().count, 4)
        XCTAssertEqual(backups.count, 2, "each mutation takes its own backup")
    }

    func testRemoveSurvivesAlreadyMissingMediaFile() throws {
        // The fixture's media files don't exist in the fake volume at all;
        // removal is DB-first and must not fail on the absent file.
        let victim = try XCTUnwrap(try library.videos().first)
        try library.remove(trackID: victim.id)
        XCTAssertEqual(try library.videos().count, 3)
    }

    // MARK: - rename

    func testRenameUpdatesTitleAndBacksUp() throws {
        let target = try XCTUnwrap(
            try library.videos().first { $0.title == "Sample Video 4" })

        try library.rename(trackID: target.id, to: "Election Day")

        let renamed = try XCTUnwrap(
            try library.videos().first { $0.id == target.id })
        XCTAssertEqual(renamed.title, "Election Day")
        XCTAssertEqual(renamed.ipodPath, target.ipodPath)
        XCTAssertEqual(backups.count, 1)
    }

    func testMutationDeletesStalePlayCounts() throws {
        // The firmware indexes Play Counts by mhlt position, so a splice makes
        // it stale; each DB write must delete it (the firmware recreates it).
        let playCounts = volume.appendingPathComponent(
            "iPod_Control/iTunes/Play Counts")
        try Data("stale".utf8).write(to: playCounts)

        let target = try XCTUnwrap(try library.videos().first)
        try library.rename(trackID: target.id, to: "renamed")

        XCTAssertFalse(FileManager.default.fileExists(atPath: playCounts.path),
                       "a DB rewrite must delete the stale Play Counts index")
    }

    func testRenameToAnotherTracksTitleThrows() throws {
        let videos = try library.videos()
        let taken = videos[0].title

        XCTAssertThrowsError(
            try library.rename(trackID: videos[1].id, to: taken)) { error in
            XCTAssertEqual(error as? IPodLibrary.LibraryError,
                           .duplicateTitle(taken))
        }
        // Re-asserting a track's own title is not a duplicate.
        XCTAssertNoThrow(try library.rename(trackID: videos[0].id, to: taken))
    }

    func testMutatingUnknownTrackThrows() {
        XCTAssertThrowsError(try library.rename(trackID: 999_999, to: "x"))
        XCTAssertThrowsError(try library.remove(trackID: 999_999))
        XCTAssertTrue(backups.isEmpty, "failed mutations must not write backups")
    }
}
