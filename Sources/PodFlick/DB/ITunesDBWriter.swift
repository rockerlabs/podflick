import Foundation

/// Byte-exact mutation layer for iTunesDB: add / rename / remove as
/// surgical in-place splices, ported from the on-device-proven
/// reference/ipod_sync_v3.py.
///
/// THE core invariant (docs/itunesdb-format.md): never regenerate the DB,
/// never renumber ids. New records are clones of proven-visible donors from
/// the CURRENT database with only per-file fields swapped; every splice
/// bumps the size field of each enclosing record (mhbd, mhsd, mhit/mhyp)
/// and the owning list's count. mhod52/53 indexes, albums and smart
/// playlists are never touched.
///
/// The writer re-parses after every mutation, so the strict full-coverage
/// parser doubles as a structural self-check of each splice, and `db`
/// always reflects `data`.
struct ITunesDBWriter {

    private(set) var data: Data
    private(set) var db: ITunesDB

    init(_ data: Data) throws {
        self.data = Data(data)          // re-base: all offsets are absolute
        self.db = try ITunesDB.parse(data)
    }

    struct WriteError: Error, CustomStringConvertible {
        let message: String
        var description: String { "iTunesDB write error: \(message)" }
    }

    /// Per-file fields of a video already copied to the device.
    struct NewTrack {
        var title: String
        var ipodPath: String            // e.g. ":iPod_Control:Music:F16:JHBI.m4v"
        var fileSize: UInt32
        var durationMs: UInt32
    }

    static func randomDBID() -> UInt64 {
        // 63-bit nonzero, matching the reference implementation.
        UInt64.random(in: 0..<(1 << 63)) | 1
    }

    static func macTimestampNow() -> UInt32 {
        UInt32(Date().timeIntervalSince1970) + 2_082_844_800
    }

    // MARK: - add

    /// Splices a cloned mhit into the track list and a cloned mhip into each
    /// master-playlist copy. Returns the new track id (= max used id + 2;
    /// the playlist item id is +3, per the proven Finder-counter pattern).
    /// dbid/itemDBID/timestamp are injectable so tests are deterministic.
    @discardableResult
    mutating func add(_ new: NewTrack,
                      dbid: UInt64 = randomDBID(),
                      itemDBID: UInt64 = randomDBID(),
                      timestamp: UInt32 = macTimestampNow()) throws -> UInt32 {
        // Donor: prefer a track with album id 0 — the proven minimal pattern.
        guard let donor = db.tracks.first(where: { $0.albumID == 0 })
                ?? db.tracks.first else {
            throw WriteError(message: "DB has no track to clone from")
        }
        guard let trackSection = section(containing: donor.offset) else {
            throw WriteError(message: "donor mhit outside every section")
        }
        guard !db.masterPlaylists.isEmpty else {
            throw WriteError(message: "DB has no master playlist")
        }

        let base = maxUsedID()
        let trackID = base + 2
        let itemID = base + 3

        struct Splice {
            let insertAt: Int
            let blob: Data
            let sizeBumpOffsets: [Int]  // u32 total-size fields += blob.count
            let countOffset: Int        // u32 record-count field += 1
        }
        var splices = [Splice(
            insertAt: trackSection.offset + trackSection.totalSize,
            blob: try cloneTrack(donor: donor, id: trackID, dbid: dbid,
                                 new: new, timestamp: timestamp),
            sizeBumpOffsets: [trackSection.offset + 8, 8],
            countOffset: trackSection.listOffset + 8)]
        for master in db.masterPlaylists {
            splices.append(Splice(
                insertAt: master.offset + master.totalSize,
                blob: try cloneItem(in: master, trackID: trackID,
                                    itemID: itemID, trackDBID: dbid,
                                    itemDBID: itemDBID, timestamp: timestamp),
                sizeBumpOffsets: [master.offset + 8,
                                  master.section.offset + 8, 8],
                countOffset: master.offset + 16))
        }

        // Descending file order: each splice's bump offsets sit below its
        // insertion point, so nothing already applied ever shifts.
        for s in splices.sorted(by: { $0.insertAt > $1.insertAt }) {
            data.replaceSubrange(s.insertAt..<s.insertAt, with: s.blob)
            for offset in s.sizeBumpOffsets {
                try bump(offset, by: s.blob.count)
            }
            try bump(s.countOffset, by: 1)
        }
        db = try ITunesDB.parse(data)
        return trackID
    }

    // MARK: - rename

    /// Replaces the title mhod in place and bumps the three enclosing size
    /// fields (mhit, mhsd, mhbd) — the splice proven on device 2026-07-02.
    mutating func rename(trackID: UInt32, to newTitle: String) throws {
        let track = try track(withID: trackID)
        guard let titleRange = track.titleMhodRange else {
            throw WriteError(message: "track \(trackID) has no title mhod")
        }
        guard let section = section(containing: track.offset) else {
            throw WriteError(message: "mhit outside every section")
        }
        let newMhod = Self.stringMhod(type: 1, newTitle)
        let delta = newMhod.count - titleRange.count
        data.replaceSubrange(titleRange, with: newMhod)
        try bump(track.offset + 8, by: delta)
        try bump(section.offset + 8, by: delta)
        try bump(8, by: delta)
        db = try ITunesDB.parse(data)
    }

    // MARK: - remove

    /// Deletes the mhit and its mhip in each master-playlist copy,
    /// decrementing the same size/count fields `add` bumps. Deleting the
    /// media file is the device layer's job, not the DB's.
    mutating func remove(trackID: UInt32) throws {
        let track = try track(withID: trackID)
        guard let trackSection = section(containing: track.offset) else {
            throw WriteError(message: "mhit outside every section")
        }

        struct Cut {
            let range: Range<Int>
            let sizeBumpOffsets: [Int]
            let countOffset: Int
        }
        var cuts = [Cut(range: track.offset ..< track.offset + track.totalSize,
                        sizeBumpOffsets: [trackSection.offset + 8, 8],
                        countOffset: trackSection.listOffset + 8)]
        for master in db.masterPlaylists {
            for item in master.items where item.trackID == trackID {
                cuts.append(Cut(
                    range: item.offset ..< item.offset + item.totalSize,
                    sizeBumpOffsets: [master.offset + 8,
                                      master.section.offset + 8, 8],
                    countOffset: master.offset + 16))
            }
        }

        for cut in cuts.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            data.removeSubrange(cut.range)
            for offset in cut.sizeBumpOffsets {
                try bump(offset, by: -cut.range.count)
            }
            try bump(cut.countOffset, by: -1)
        }
        db = try ITunesDB.parse(data)
    }

    // MARK: - Donor cloning

    private func cloneTrack(donor: ITunesDB.Track, id: UInt32, dbid: UInt64,
                            new: NewTrack, timestamp: UInt32) throws -> Data {
        guard let kindRange = donor.kindMhodRange else {
            throw WriteError(message: "donor track \(donor.id) has no filetype mhod")
        }
        let headerSize = Int(try Reader(data).u32(donor.offset + 4))
        // The clone patches fields up to 0x1F4 — reject exotic donors.
        guard headerSize >= 0x1F8 else {
            throw WriteError(message: "donor mhit header 0x\(String(headerSize, radix: 16)) too small to clone")
        }
        let children = Self.stringMhod(type: 1, new.title)
                     + data.subdata(in: kindRange)
                     + Self.stringMhod(type: 2, new.ipodPath)
        var header = data.subdata(in: donor.offset ..< donor.offset + headerSize)
        header.putU32(UInt32(headerSize + children.count), at: 0x08)
        header.putU32(3, at: 0x0C)              // child mhod count
        header.putU32(id, at: 0x10)
        header.putU32(timestamp, at: 0x20)      // date modified
        header.putU32(new.fileSize, at: 0x24)
        header.putU32(new.durationMs, at: 0x28)
        header.putU32(timestamp, at: 0x68)      // date added
        header.putU64(dbid, at: 0x70)
        // Album and related-track refs zeroed — the proven degraded-but-
        // working pattern; the writer never creates mhia records.
        header.putU32(0, at: 0x120)
        header.putU32(new.fileSize, at: 0x12C)
        header.putU32(0, at: 0x1E0)
        header.putU32(0, at: 0x1F4)
        return header + children
    }

    private func cloneItem(in master: ITunesDB.Playlist, trackID: UInt32,
                           itemID: UInt32, trackDBID: UInt64,
                           itemDBID: UInt64, timestamp: UInt32) throws -> Data {
        guard let donor = master.items.last else {
            throw WriteError(message: "master playlist has no mhip to clone from")
        }
        let headerSize = Int(try Reader(data).u32(donor.offset + 4))
        // Patched fields end at 0x44; the child mhod100's position value
        // sits at header + 0x18.
        guard headerSize >= 0x44, headerSize + 0x1C <= donor.totalSize else {
            throw WriteError(message: "donor mhip layout too small to clone")
        }
        var blob = data.subdata(in: donor.offset ..< donor.offset + donor.totalSize)
        blob.putU32(itemID, at: 0x14)
        blob.putU32(trackID, at: 0x18)
        blob.putU32(timestamp, at: 0x1C)
        blob.putU64(trackDBID, at: 0x2C)
        blob.putU64(itemDBID, at: 0x3C)
        // mhod100 carries an order/position value: donor's + a small bump.
        blob.putU32(blob.getU32(at: headerSize + 0x18) + 2, at: headerSize + 0x18)
        return blob
    }

    /// Title/path mhod in the live-DB layout (byte-identical to the
    /// reference string_mhod / Finder's own output — the selftest proves
    /// the layout): 0x18 header; payload encoding=1, byte length, flag=1,
    /// pad; UTF-16LE text zero-padded to a 4-byte boundary.
    private static func stringMhod(type: UInt32, _ text: String) -> Data {
        let utf16 = Array(text.utf16)
        let byteLength = utf16.count * 2
        var mhod = Data(count: (0x18 + 16 + byteLength + 3) & ~3)
        mhod.replaceSubrange(0..<4, with: Data("mhod".utf8))
        mhod.putU32(0x18, at: 4)
        mhod.putU32(UInt32(mhod.count), at: 8)
        mhod.putU32(type, at: 12)
        mhod.putU32(1, at: 0x18)                // encoding: UTF-16LE
        mhod.putU32(UInt32(byteLength), at: 0x1C)
        mhod.putU32(1, at: 0x20)
        for (i, unit) in utf16.enumerated() {
            mhod[0x28 + 2 * i] = UInt8(unit & 0xFF)
            mhod[0x28 + 2 * i + 1] = UInt8(unit >> 8)
        }
        return mhod
    }

    // MARK: - Lookup and size-field helpers

    private func track(withID id: UInt32) throws -> ITunesDB.Track {
        guard let track = db.tracks.first(where: { $0.id == id }) else {
            throw WriteError(message: "no track with id \(id)")
        }
        return track
    }

    private func section(containing offset: Int) -> ITunesDB.Section? {
        db.sections.first {
            offset >= $0.offset && offset < $0.offset + $0.totalSize
        }
    }

    /// Superset of the reference's max_id: every track/album/item id in the
    /// DB, so new ids never collide whatever record they came from.
    private func maxUsedID() -> UInt32 {
        var maxID: UInt32 = 0
        for track in db.tracks { maxID = max(maxID, track.id, track.albumID) }
        for album in db.albums { maxID = max(maxID, album.id) }
        for item in db.playlists.flatMap(\.items) {
            maxID = max(maxID, item.itemID, item.trackID)
        }
        return maxID
    }

    private mutating func bump(_ offset: Int, by delta: Int) throws {
        let old = try Reader(data).u32(offset)
        guard let new = UInt32(exactly: Int(old) + delta) else {
            throw WriteError(message: "size field @0x\(String(offset, radix: 16)) under/overflow")
        }
        data.putU32(new, at: offset)
    }
}

// MARK: - Little-endian stores into clone buffers

private extension Data {
    mutating func putU32(_ value: UInt32, at offset: Int) {
        withUnsafeMutableBytes {
            $0.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
        }
    }

    mutating func putU64(_ value: UInt64, at offset: Int) {
        withUnsafeMutableBytes {
            $0.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
        }
    }

    func getU32(at offset: Int) -> UInt32 {
        withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }.littleEndian
    }
}
