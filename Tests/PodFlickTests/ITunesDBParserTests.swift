import XCTest
@testable import PodFlick

/// Golden-fixture tests: both fixtures are real, firmware-accepted databases
/// captured from the operator's devices (see reference/fixtures/).
final class ITunesDBParserTests: XCTestCase {

    // MARK: - Single-video fixture (Finder-written, the byte-exact template)

    func testSingleVideoFixtureParses() throws {
        let db = try ITunesDB.parse(try fixture("iTunesDB.single-video"))

        XCTAssertEqual(db.version, 0x75)
        // Section table in Finder's canonical order: albums, tracks,
        // playlists ×2, smart playlists — with sizes covering the file.
        XCTAssertEqual(db.sections.map(\.type), [4, 1, 3, 2, 5])
        XCTAssertEqual(db.sections.map(\.totalSize).reduce(0xF4, +), 15804)

        XCTAssertEqual(db.tracks.count, 1)
        let track = try XCTUnwrap(db.tracks.first)
        XCTAssertEqual(track.id, 126017)
        XCTAssertEqual(track.title, "Sample Video 1")
        XCTAssertEqual(track.path, ":iPod_Control:Music:F16:JHBI.m4v")
        XCTAssertEqual(track.fileSize, 797639938)
        XCTAssertEqual(track.durationMs, 7642567)
        XCTAssertEqual(track.mediaType, 2)
        XCTAssertEqual(track.albumID, 126023)

        XCTAssertEqual(db.albums.count, 1)
        XCTAssertEqual(db.albums.first?.id, 126023)
    }

    func testSingleVideoPlaylistStructure() throws {
        let db = try ITunesDB.parse(try fixture("iTunesDB.single-video"))

        // Two identical master-playlist copies (mhsd types 3 and 2).
        let masters = db.masterPlaylists
        XCTAssertEqual(masters.count, 2)
        XCTAssertEqual(Set(masters.map(\.section.type)), [2, 3])
        XCTAssertEqual(Set(masters.map(\.persistentID)).count, 1)
        for master in masters {
            XCTAssertEqual(master.items.count, 1)
            XCTAssertEqual(master.items.first?.trackID, 126017)
            XCTAssertEqual(master.items.first?.itemID, 126022)
            XCTAssertFalse(master.isSmart)
        }

        // Five smart playlists with the canonical Finder names.
        XCTAssertEqual(db.smartPlaylists.map(\.title),
                       ["Audiobooks", "Movies", "Music", "TV Shows", "Videos"])
        XCTAssertTrue(db.smartPlaylists.allSatisfy { $0.items.isEmpty })
        XCTAssertTrue(db.smartPlaylists.allSatisfy { $0.section.type == 5 })
    }

    // MARK: - Four-videos fixture (firmware-accepted on device 2026-07-02)

    func testFourVideosFixtureParses() throws {
        let db = try ITunesDB.parse(try fixture("iTunesDB.four-videos"))

        XCTAssertEqual(db.version, 0x75)
        XCTAssertEqual(db.tracks.count, 4)
        XCTAssertEqual(db.tracks.map(\.id), [31, 48, 62, 68])
        XCTAssertEqual(db.tracks.map(\.title), [
            "Sample Video 1",
            "Sample Video 2",
            "Sample Video 3",
            "Sample Video 4",
        ])
        XCTAssertTrue(db.tracks.allSatisfy { $0.mediaType == 2 })

        // The renamed track keeps the degraded-but-working pattern: no album.
        let renamed = try XCTUnwrap(db.tracks.last)
        XCTAssertEqual(renamed.albumID, 0)
        XCTAssertEqual(renamed.path, ":iPod_Control:Music:F45:TDIT.mp4")

        // The rename recipe (B.2) splices the title mhod range in place:
        // it must sit inside its mhit and hold the decoded title.
        let titleRange = try XCTUnwrap(renamed.titleMhodRange)
        XCTAssertGreaterThan(titleRange.lowerBound, renamed.offset)
        XCTAssertLessThanOrEqual(titleRange.upperBound,
                                 renamed.offset + renamed.totalSize)

        XCTAssertEqual(db.albums.count, 3)
    }

    func testFourVideosPlaylistStructure() throws {
        let db = try ITunesDB.parse(try fixture("iTunesDB.four-videos"))

        let masters = db.masterPlaylists
        XCTAssertEqual(masters.count, 2)
        for master in masters {
            XCTAssertEqual(master.items.count, 4)
            XCTAssertEqual(master.items.map(\.trackID), [31, 48, 62, 68])
            // Item ids come from a global counter, not fixed arithmetic.
            XCTAssertEqual(master.items.map(\.itemID), [35, 53, 67, 69])
        }
        // mhip.trackDBID mirrors the track's dbid.
        let ids = db.tracks.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate track ids")
        let dbidByTrack = Dictionary(db.tracks.map { ($0.id, $0.dbid) },
                                     uniquingKeysWith: { a, _ in a })
        for item in masters.flatMap(\.items) {
            XCTAssertEqual(item.trackDBID, dbidByTrack[item.trackID])
        }

        XCTAssertEqual(db.smartPlaylists.count, 5)
    }

    // MARK: - Strictness

    func testTruncatedDataThrows() throws {
        let whole = try fixture("iTunesDB.single-video")
        XCTAssertThrowsError(try ITunesDB.parse(whole.prefix(1000)))
        XCTAssertThrowsError(try ITunesDB.parse(whole.dropFirst(4)))
    }

    func testCorruptedSizeFieldThrows() throws {
        var data = try fixture("iTunesDB.single-video")
        data[8] ^= 0xFF   // flip bits in mhbd total size
        XCTAssertThrowsError(try ITunesDB.parse(data))
    }

    func testZeroSizedSectionThrows() throws {
        // A zero-total mhsd must be rejected, not walked in place forever.
        var data = try fixture("iTunesDB.single-video")
        let firstSection = 0xF4
        for i in 0..<4 { data[firstSection + 8 + i] = 0 }
        XCTAssertThrowsError(try ITunesDB.parse(data)) { error in
            XCTAssertTrue("\(error)".contains("mhsd sizes invalid"))
        }
    }
}
