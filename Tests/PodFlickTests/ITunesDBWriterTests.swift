import XCTest
@testable import PodFlick

/// B.2 splice-writer tests against the golden fixtures (CLAUDE.md
/// Conventions): (b) add + remove returns a byte-identical DB; (c) rename
/// reproduces the firmware-accepted fixture byte-exactly; plus structural
/// checks of the add splice through the strict parser (a) — every mutation
/// re-parses with full coverage, closing the byte round-trip.
final class ITunesDBWriterTests: XCTestCase {

    private let newVideo = ITunesDBWriter.NewTrack(
        title: "tiny",
        ipodPath: ":iPod_Control:Music:F07:TEST.m4v",
        fileSize: 1_234_567,
        durationMs: 90_000)
    private let dbid: UInt64 = 0x1122_3344_5566_7788
    private let itemDBID: UInt64 = 0x0102_0304_0506_0708
    private let timestamp: UInt32 = 3_800_000_000   // fixed Mac-epoch time

    // MARK: - (b) add + remove invariant

    func testAddThenRemoveIsByteIdentical() throws {
        for name in ["iTunesDB.single-video", "iTunesDB.four-videos"] {
            let original = try fixture(name)
            var writer = try ITunesDBWriter(original)
            let trackID = try writer.add(newVideo, dbid: dbid,
                                         itemDBID: itemDBID,
                                         timestamp: timestamp)
            XCTAssertNotEqual(writer.data, original, name)
            try writer.remove(trackID: trackID)
            XCTAssertEqual(writer.data, original, name)
        }
    }

    func testTwoAddsThenRemovesAreByteIdentical() throws {
        let original = try fixture("iTunesDB.four-videos")
        var writer = try ITunesDBWriter(original)
        let first = try writer.add(newVideo, dbid: dbid,
                                   itemDBID: itemDBID, timestamp: timestamp)
        var second = newVideo
        second.title = "tiny 2"
        let secondID = try writer.add(second, dbid: dbid &+ 1,
                                      itemDBID: itemDBID &+ 1,
                                      timestamp: timestamp)
        // The second add counts the first clone's ids: item id (+3) is the
        // new maximum, so the next track id is that +2.
        XCTAssertEqual(secondID, first + 3)
        try writer.remove(trackID: secondID)
        try writer.remove(trackID: first)
        XCTAssertEqual(writer.data, original)
    }

    // MARK: - add splice structure (checked through the strict parser)

    func testAddClonesDonorAtEndOfLists() throws {
        var writer = try ITunesDBWriter(try fixture("iTunesDB.four-videos"))
        let original = writer.db
        let trackID = try writer.add(newVideo, dbid: dbid,
                                     itemDBID: itemDBID, timestamp: timestamp)

        // Ids follow the proven pattern: max used id +2, item id +3. The
        // golden fixture's max used id is 69 (the master playlists' last
        // mhip item id).
        XCTAssertEqual(trackID, 71)

        let db = writer.db
        XCTAssertEqual(db.tracks.count, 5)
        let added = try XCTUnwrap(db.tracks.last)
        XCTAssertEqual(added.id, trackID)
        XCTAssertEqual(added.title, newVideo.title)
        XCTAssertEqual(added.path, newVideo.ipodPath)
        XCTAssertEqual(added.fileSize, newVideo.fileSize)
        XCTAssertEqual(added.durationMs, newVideo.durationMs)
        XCTAssertEqual(added.dbid, dbid)
        XCTAssertEqual(added.mediaType, 2)
        XCTAssertEqual(added.albumID, 0, "clone must not reference an album")

        // The kind mhod is the donor's ("Sample Video 4", album id 0), verbatim.
        let donor = try XCTUnwrap(db.tracks.first { $0.title == "Sample Video 4" })
        XCTAssertEqual(writer.data.subdata(in: try XCTUnwrap(added.kindMhodRange)),
                       writer.data.subdata(in: try XCTUnwrap(donor.kindMhodRange)))

        // One cloned mhip at the end of BOTH master-playlist copies.
        XCTAssertEqual(db.masterPlaylists.count, 2)
        for master in db.masterPlaylists {
            XCTAssertEqual(master.items.count, 5)
            let item = try XCTUnwrap(master.items.last)
            XCTAssertEqual(item.trackID, trackID)
            XCTAssertEqual(item.itemID, trackID + 1)
            XCTAssertEqual(item.trackDBID, dbid)
        }

        // Albums, smart playlists and indexes are never touched.
        XCTAssertEqual(db.albums.count, original.albums.count)
        XCTAssertEqual(db.smartPlaylists.map(\.title),
                       original.smartPlaylists.map(\.title))
    }

    // MARK: - (c) rename patch against the firmware-accepted fixture

    func testRenameRoundTripMatchesAcceptedFixture() throws {
        // iTunesDB.four-videos is a firmware-accepted device DB (titles since
        // neutralized to placeholders — see Fixtures.swift). Renaming a track
        // away and back must land on those exact bytes.
        let original = try fixture("iTunesDB.four-videos")
        var writer = try ITunesDBWriter(original)
        let target = try XCTUnwrap(
            writer.db.tracks.first { $0.title == "Sample Video 4" })

        try writer.rename(trackID: target.id, to: "Election Day (extended)")
        XCTAssertNotEqual(writer.data, original)
        let renamed = try XCTUnwrap(
            writer.db.tracks.first { $0.id == target.id })
        XCTAssertEqual(renamed.title, "Election Day (extended)")
        XCTAssertEqual(renamed.path, target.path, "rename must not touch the path")
        XCTAssertEqual(writer.db.tracks.count, 4)

        try writer.rename(trackID: target.id, to: "Sample Video 4")
        XCTAssertEqual(writer.data, original)
    }

    func testRenameRoundTripOnFinderWrittenTitle() throws {
        // The single-video fixture carries one title mhod (neutralized
        // placeholder); a shrinking rename and the rename back reproduce it.
        let original = try fixture("iTunesDB.single-video")
        var writer = try ITunesDBWriter(original)
        let track = try XCTUnwrap(writer.db.tracks.first)

        try writer.rename(trackID: track.id, to: "K")
        XCTAssertEqual(writer.db.tracks.first?.title, "K")
        try writer.rename(trackID: track.id, to: track.title)
        XCTAssertEqual(writer.data, original)
    }

    func testRenameToUnalignedTitleWritesExactMhodSize() throws {
        // Firmware-facing regression (B.5.1 device smoke, 2026-07-04): a
        // title whose UTF-16 byte length is not 4-aligned must produce an
        // EXACT-size mhod (0x18+16+len). The old `(…+3)&~3` rounding wrote
        // 2 trailing pad bytes and the firmware answered with empty menus;
        // Finder itself writes unaligned totals (the 86-byte device-name
        // mhods in the fixtures are unaligned).
        var writer = try ITunesDBWriter(try fixture("iTunesDB.four-videos"))
        let target = try XCTUnwrap(writer.db.tracks.first)

        try writer.rename(trackID: target.id, to: "111")   // 6 UTF-16 bytes
        let renamed = try XCTUnwrap(
            writer.db.tracks.first { $0.id == target.id })
        XCTAssertEqual(renamed.title, "111")
        let range = try XCTUnwrap(renamed.titleMhodRange)
        XCTAssertEqual(range.count, 0x18 + 16 + 6,
                       "title mhod must be exact-size, never padded")
    }

    // MARK: - Unknown ids

    func testMutatingUnknownTrackThrows() throws {
        var writer = try ITunesDBWriter(try fixture("iTunesDB.single-video"))
        XCTAssertThrowsError(try writer.rename(trackID: 999_999, to: "x"))
        XCTAssertThrowsError(try writer.remove(trackID: 999_999))
    }

    // MARK: - Overflow guards (fail loudly, never trap)

    func testAddThrowsWhenIDSpaceExhausted() throws {
        // Patch a track id to the u32 ceiling so maxUsedID() saturates; add
        // must throw a recoverable WriteError, not trap on base + 3.
        var data = try fixture("iTunesDB.four-videos")
        let idOffset = try XCTUnwrap(ITunesDB.parse(data).tracks.first).offset + 0x10
        withUnsafeBytes(of: UInt32.max.littleEndian) { raw in
            for (i, byte) in raw.enumerated() { data[idOffset + i] = byte }
        }
        var writer = try ITunesDBWriter(data)
        XCTAssertThrowsError(try writer.add(newVideo, dbid: dbid,
                                            itemDBID: itemDBID,
                                            timestamp: timestamp)) { error in
            XCTAssertTrue("\(error)".contains("id space exhausted"), "\(error)")
        }
    }

    // MARK: - Exact-size string mhods on the add path (firmware-critical)

    func testAddWritesExactSizeTitleAndPathMhods() throws {
        // A padded (4-aligned) string mhod makes the firmware show empty menus
        // (proven on device 2026-07-04). The re-parse self-check can't catch a
        // padded-but-parseable mhod, so this pins the add path's exactness
        // directly (rename is covered by testRenameToUnalignedTitle…).
        var writer = try ITunesDBWriter(try fixture("iTunesDB.four-videos"))
        let new = ITunesDBWriter.NewTrack(
            title: "xyz",                                  // 6 UTF-16 bytes (unaligned)
            ipodPath: ":iPod_Control:Music:F07:ABC.m4v",   // 62 bytes (unaligned)
            fileSize: 1000, durationMs: 1000)
        let id = try writer.add(new, dbid: dbid, itemDBID: itemDBID,
                                timestamp: timestamp)
        let track = try XCTUnwrap(writer.db.tracks.first { $0.id == id })

        let titleBytes = new.title.data(using: .utf16LittleEndian)!.count
        XCTAssertEqual(try XCTUnwrap(track.titleMhodRange).count,
                       0x18 + 16 + titleBytes, "title mhod must be exact-size")
        let pathBytes = new.ipodPath.data(using: .utf16LittleEndian)!.count
        XCTAssertEqual(try XCTUnwrap(track.pathMhodRange).count,
                       0x18 + 16 + pathBytes, "path mhod must be exact-size")
    }
}
