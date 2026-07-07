import Foundation

/// Byte-exact mutation layer for iTunesDB: add / rename / remove as
/// surgical in-place splices, ported from the on-device-proven
/// reference/ipod_sync_v3.py.
///
/// THE core invariant (docs/itunesdb-format.md): never regenerate the DB,
/// never renumber ids. New records are clones of proven-visible donors with
/// only per-file fields swapped — from the CURRENT database, or, when it
/// has none left (a library emptied of videos), from a `SeedDonor` database
/// that is itself firmware-accepted; every splice bumps the size field of
/// each enclosing record (mhbd, mhsd, mhit/mhyp) and the owning list's
/// count. mhod52/53 indexes, albums and smart playlists are never touched.
///
/// The writer re-parses after every mutation, so the strict full-coverage
/// parser doubles as a structural self-check of each splice, and `db`
/// always reflects `data`.
struct ITunesDBWriter {

    private(set) var data: Data
    private(set) var db: ITunesDB

    init(_ data: Data) throws {
        // Re-base slices: every parse offset is absolute in `self.data`.
        self.data = data.rebasedToZero
        self.db = try ITunesDB.parse(self.data)
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

    /// A donor database for seeding an emptied library: when the target DB
    /// has no track (or a master-playlist copy has no mhip) there is nothing
    /// left to clone, so `add` takes the missing donors from here instead.
    /// The app passes the bundled golden fixture — a real, firmware-accepted
    /// database of the same layout as every Finder-written iPod 5G/5.5G DB.
    struct SeedDonor {
        let data: Data
        let db: ITunesDB

        init(_ data: Data) throws {
            self.data = data.rebasedToZero
            self.db = try ITunesDB.parse(self.data)
        }
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
    /// When this DB has no donor of its own (an emptied library), the donor
    /// blobs come from `seed` instead — the splice targets stay this DB's.
    /// dbid/itemDBID/timestamp are injectable so tests are deterministic.
    @discardableResult
    mutating func add(_ new: NewTrack,
                      seed: SeedDonor? = nil,
                      dbid: UInt64 = randomDBID(),
                      itemDBID: UInt64 = randomDBID(),
                      timestamp: UInt32 = macTimestampNow()) throws -> UInt32 {
        // Donor: prefer a track with album id 0 — the proven minimal pattern.
        let donor: (track: ITunesDB.Track, source: Data)
        if let own = db.tracks.first(where: { $0.albumID == 0 })
                ?? db.tracks.first {
            donor = (own, data)
        } else if let seed,
                  let seeded = seed.db.tracks.first(where: { $0.albumID == 0 })
                        ?? seed.db.tracks.first {
            donor = (seeded, seed.data)
        } else {
            throw WriteError(message: "DB has no track to clone from")
        }
        guard !db.masterPlaylists.isEmpty else {
            throw WriteError(message: "DB has no master playlist")
        }
        // The splice inserts into THIS DB's track section — donor.track's own
        // section may live in the seed data.
        guard let trackSection = db.sections.first(where: { $0.type == 1 }) else {
            throw WriteError(message: "DB has no track section")
        }

        let base = maxUsedID()
        // ids are a never-renumbered monotonic counter (the hard invariant),
        // so guard the u32 ceiling rather than trapping on base + 3.
        guard base <= UInt32.max - 3 else {
            throw WriteError(message: "track-id space exhausted (max used id \(base))")
        }
        let trackID = base + 2
        let itemID = base + 3

        let trackListEnd = trackSection.offset + trackSection.totalSize
        var edits = [Edit(
            range: trackListEnd..<trackListEnd,
            replacement: try cloneTrack(donor: donor.track, in: donor.source,
                                        id: trackID, dbid: dbid,
                                        new: new, timestamp: timestamp),
            sizeBumpOffsets: [trackSection.offset + 8],
            countBump: (offset: trackSection.listOffset + 8, delta: 1))]
        for master in db.masterPlaylists {
            let item: (donor: ITunesDB.PlaylistItem, source: Data)
            if let own = master.items.last {
                item = (own, data)
            } else if let seed, let seeded = seed.db.masterPlaylists
                        .compactMap(\.items.last).first {
                item = (seeded, seed.data)
            } else {
                throw WriteError(message: "master playlist has no mhip to clone from")
            }
            let masterEnd = master.offset + master.totalSize
            edits.append(Edit(
                range: masterEnd..<masterEnd,
                replacement: try cloneItem(donor: item.donor, in: item.source,
                                           trackID: trackID,
                                           itemID: itemID, trackDBID: dbid,
                                           itemDBID: itemDBID,
                                           timestamp: timestamp),
                sizeBumpOffsets: [master.offset + 8,
                                  master.section.offset + 8],
                countBump: (offset: master.offset + 16, delta: 1)))
        }
        try apply(edits)
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
        try apply([Edit(
            range: titleRange,
            replacement: try Self.stringMhod(type: 1, newTitle),
            sizeBumpOffsets: [track.offset + 8, track.section.offset + 8],
            countBump: nil)])
    }

    // MARK: - remove

    /// Deletes the mhit and its mhip in each master-playlist copy,
    /// decrementing the same size/count fields `add` bumps. Deleting the
    /// media file is the device layer's job, not the DB's.
    mutating func remove(trackID: UInt32) throws {
        let track = try track(withID: trackID)
        var edits = [Edit(
            range: track.offset ..< track.offset + track.totalSize,
            replacement: Data(),
            sizeBumpOffsets: [track.section.offset + 8],
            countBump: (offset: track.section.listOffset + 8, delta: -1))]
        for master in db.masterPlaylists {
            for item in master.items where item.trackID == trackID {
                edits.append(Edit(
                    range: item.offset ..< item.offset + item.totalSize,
                    replacement: Data(),
                    sizeBumpOffsets: [master.offset + 8,
                                      master.section.offset + 8],
                    countBump: (offset: master.offset + 16, delta: -1)))
            }
        }
        try apply(edits)
    }

    // MARK: - Splice application

    /// One splice: replace `range` with `replacement` (either side may be
    /// empty — a pure insert or delete), bump each enclosing size field by
    /// the length delta, and adjust the owning list's count.
    private struct Edit {
        let range: Range<Int>
        let replacement: Data
        let sizeBumpOffsets: [Int]  // enclosing mhit/mhyp/mhsd; mhbd is implied
        let countBump: (offset: Int, delta: Int)?
    }

    /// Applies edits in descending file order: every edit's bump offsets sit
    /// below its own range — and therefore below every not-yet-applied,
    /// lower-lying edit — so nothing already patched ever shifts.
    private mutating func apply(_ edits: [Edit]) throws {
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            // Descending order is correct only if EVERY patched offset — size
            // and count alike — sits below its edit's range; otherwise a
            // not-yet-applied lower edit would relocate a byte we already
            // bumped. Enforced in release (unlike the old debug-only assert)
            // and recoverable: a violation aborts the mutation, never writes a
            // corrupt DB.
            let bumpOffsets = edit.sizeBumpOffsets
                + (edit.countBump.map { [$0.offset] } ?? [])
            guard bumpOffsets.allSatisfy({ $0 < edit.range.lowerBound }) else {
                throw WriteError(message:
                    "splice bump offset not below its edit range @0x\(String(edit.range.lowerBound, radix: 16))")
            }
            let delta = edit.replacement.count - edit.range.count
            data.replaceSubrange(edit.range, with: edit.replacement)
            for offset in edit.sizeBumpOffsets + [8] {  // 8 = mhbd total size
                try bump(offset, by: delta)
            }
            if let countBump = edit.countBump {
                try bump(countBump.offset, by: countBump.delta)
            }
        }
        db = try ITunesDB.parse(data)
    }

    private mutating func bump(_ offset: Int, by delta: Int) throws {
        let old = try Reader(data).u32(offset)
        guard let new = UInt32(exactly: Int(old) + delta) else {
            throw WriteError(message: "size field @0x\(String(offset, radix: 16)) under/overflow")
        }
        data.putU32(new, at: offset)
    }

    // MARK: - Donor cloning

    /// `source` is the data the donor's offsets index into: this DB's own
    /// bytes, or the seed donor DB's when seeding an emptied library.
    private func cloneTrack(donor: ITunesDB.Track, in source: Data,
                            id: UInt32, dbid: UInt64,
                            new: NewTrack, timestamp: UInt32) throws -> Data {
        guard let kindRange = donor.kindMhodRange else {
            throw WriteError(message: "donor track \(donor.id) has no filetype mhod")
        }
        // The clone patches fields up to 0x1F4 — reject exotic donors.
        guard donor.headerSize >= 0x1F8 else {
            throw WriteError(message: "donor mhit header 0x\(String(donor.headerSize, radix: 16)) too small to clone")
        }
        let children = try Self.stringMhod(type: 1, new.title)
                     + source.subdata(in: kindRange)
                     + Self.stringMhod(type: 2, new.ipodPath)
        var header = source.subdata(in: donor.offset ..< donor.offset + donor.headerSize)
        guard let cloneTotal = UInt32(exactly: donor.headerSize + children.count) else {
            throw WriteError(message:
                "cloned mhit total \(donor.headerSize + children.count) overflows u32")
        }
        header.putU32(cloneTotal, at: 0x08)
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

    /// `source` is the data the donor's offsets index into: this DB's own
    /// bytes, or the seed donor DB's when the master copy has no mhip left.
    private func cloneItem(donor: ITunesDB.PlaylistItem, in source: Data,
                           trackID: UInt32,
                           itemID: UInt32, trackDBID: UInt64,
                           itemDBID: UInt64, timestamp: UInt32) throws -> Data {
        let headerSize = Int(try Reader(source).u32(donor.offset + 4))
        // Patched fields end at 0x44; the child mhod100's position value
        // sits at header + 0x18.
        guard headerSize >= 0x44, headerSize + 0x1C <= donor.totalSize else {
            throw WriteError(message: "donor mhip layout too small to clone")
        }
        var blob = source.subdata(in: donor.offset ..< donor.offset + donor.totalSize)
        blob.putU32(itemID, at: 0x14)
        blob.putU32(trackID, at: 0x18)
        blob.putU32(timestamp, at: 0x1C)
        blob.putU64(trackDBID, at: 0x2C)
        blob.putU64(itemDBID, at: 0x3C)
        // mhod100 carries an order/position value: donor's + a small bump.
        let positionOffset = headerSize + 0x18
        let position = try Reader(blob).u32(positionOffset)
        guard let bumped = UInt32(exactly: UInt64(position) + 2) else {
            throw WriteError(message: "mhod100 position \(position) overflows u32")
        }
        blob.putU32(bumped, at: positionOffset)
        return blob
    }

    /// Title/path mhod in Finder's own layout: 0x18 header; payload
    /// encoding=1, byte length, flag=1, pad(u32); UTF-16LE text; total is
    /// EXACT (0x18+16+len, never rounded up). Every Finder-written string
    /// mhod in the golden fixtures is unaligned-exact (totals 86, 118), and
    /// the 2026-07-04 device smoke proved the firmware rejects a padded one
    /// (empty menus) — the reference's `(…+3)&~3` is a latent bug its
    /// selftest never hits (all generated titles happened to be 4-aligned).
    private static func stringMhod(type: UInt32, _ text: String) throws -> Data {
        // Explicit-endian UTF-16 encoding emits no BOM and cannot fail.
        let payload = text.data(using: .utf16LittleEndian)!
        // Title/path length is filesystem-bounded in practice, but a value
        // that overflows the u32 length/total fields must fail loudly as a
        // WriteError, not trap the process (the byte layer's discipline).
        guard let payloadLen = UInt32(exactly: payload.count),
              let total = UInt32(exactly: 0x18 + 16 + payload.count) else {
            throw WriteError(message:
                "string mhod payload \(payload.count) bytes overflows u32")
        }
        var mhod = Data(count: 0x18 + 16 + payload.count)
        mhod.replaceSubrange(0..<4, with: Data("mhod".utf8))
        mhod.putU32(0x18, at: 4)
        mhod.putU32(total, at: 8)
        mhod.putU32(type, at: 12)
        mhod.putU32(1, at: 0x18)                // encoding: UTF-16LE
        mhod.putU32(payloadLen, at: 0x1C)
        mhod.putU32(1, at: 0x20)
        mhod.replaceSubrange(0x28 ..< 0x28 + payload.count, with: payload)
        return mhod
    }

    // MARK: - Lookups

    private func track(withID id: UInt32) throws -> ITunesDB.Track {
        guard let track = db.tracks.first(where: { $0.id == id }) else {
            throw WriteError(message: "no track with id \(id)")
        }
        return track
    }

    /// Superset of the reference's max_id: every track/album/item id in the
    /// DB, so new ids never collide whatever record they came from.
    private func maxUsedID() -> UInt32 {
        var maxID: UInt32 = 0
        for track in db.tracks { maxID = max(maxID, track.id, track.albumID) }
        for album in db.albums { maxID = max(maxID, album.id) }
        for playlist in db.playlists {
            for item in playlist.items {
                maxID = max(maxID, item.itemID, item.trackID)
            }
        }
        return maxID
    }
}

// MARK: - Little-endian stores into clone buffers

private extension Data {
    // The write half of the byte layer mirrors Reader.check's bounds
    // discipline: a miscomputed offset must fail loudly, not corrupt memory.
    mutating func putU32(_ value: UInt32, at offset: Int) {
        precondition(offset >= 0 && offset + 4 <= count, "u32 store out of bounds")
        withUnsafeMutableBytes {
            $0.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
        }
    }

    mutating func putU64(_ value: UInt64, at offset: Int) {
        precondition(offset >= 0 && offset + 8 <= count, "u64 store out of bounds")
        withUnsafeMutableBytes {
            $0.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
        }
    }
}
