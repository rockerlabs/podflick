import Foundation

/// Parsed, read-only view of an iPod classic iTunesDB (the version-0x75
/// family written by Finder/iTunes 12.x for 5G/5.5G devices).
///
/// Record layouts and firmware constraints: docs/itunesdb-format.md.
/// This layer only reads, but it preserves the structural skeleton the
/// byte-exact mutation layer (B.2) splices against: section table, record
/// offsets and sizes, and the byte ranges of the string mhods.
///
/// `parse(_:)` expects the COMPLETE file as read from disk; all exposed
/// offsets and ranges are absolute positions in that file. (Passing a Data
/// slice is safe — the reader re-bases it — but the offsets then refer to
/// the slice's own content, not the parent buffer.)
struct ITunesDB {

    struct ParseError: Error, CustomStringConvertible {
        let offset: Int
        let message: String
        var description: String {
            "iTunesDB parse error @0x\(String(offset, radix: 16)): \(message)"
        }
    }

    /// One mhsd section: the splice recipes bump its total-size field.
    struct Section {
        let offset: Int
        let type: UInt32            // 1 tracks, 2/3 playlists, 4 albums, 5 smart
        let headerSize: Int
        let totalSize: Int
        var listOffset: Int { offset + headerSize }  // the mhlt/mhla/mhlp child
    }

    struct Track {
        let offset: Int             // mhit position in the file
        let totalSize: Int          // donor cloning copies offset..<offset+totalSize
        let id: UInt32
        let title: String
        let path: String            // iPod-style, e.g. ":iPod_Control:Music:F16:JHBI.m4v"
        let fileSize: UInt32
        let durationMs: UInt32
        let dbid: UInt64
        let mediaType: UInt32       // 2 = movie
        let albumID: UInt32         // 0 = no album record
        let titleMhodRange: Range<Int>?   // rename splices this range
        let pathMhodRange: Range<Int>?
        let kindMhodRange: Range<Int>?    // type 6; donor cloning copies it verbatim
    }

    struct PlaylistItem {
        let offset: Int             // mhip position
        let totalSize: Int
        let itemID: UInt32
        let trackID: UInt32
        let trackDBID: UInt64
    }

    struct Playlist {
        let offset: Int             // mhyp position
        let totalSize: Int
        let section: Section        // enclosing mhsd — its size field is bumped too
        let isMaster: Bool
        let isSmart: Bool           // has mhod 50/51 rule blobs
        let title: String
        let persistentID: UInt64
        let items: [PlaylistItem]
    }

    struct Album {
        let offset: Int             // mhia position
        let totalSize: Int
        let id: UInt32
        let persistentID: UInt64
    }

    let version: UInt32
    let sections: [Section]
    let tracks: [Track]
    let albums: [Album]
    let playlists: [Playlist]       // file order; both master copies included

    var masterPlaylists: [Playlist] { playlists.filter(\.isMaster) }
    var smartPlaylists: [Playlist] { playlists.filter(\.isSmart) }

    // Minimum record extents for the fixed-offset fields this parser reads.
    // Records that claim to be smaller are rejected rather than silently
    // decoded out of neighboring bytes.
    private static let minSectionHeader = 0x10
    private static let minTrackHeader = 0x124    // fields up to albumID@0x120
    private static let minPlaylistHeader = 0x30  // fields up to persistentID@28
    private static let minItemSize = 0x34        // fields up to trackDBID@0x2C

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> ITunesDB {
        let r = Reader(data)
        try r.expectMagic("mhbd", at: 0)
        let headerSize = Int(try r.u32(4))
        let totalSize = Int(try r.u32(8))
        guard totalSize == data.count else {
            throw ParseError(offset: 8, message:
                "mhbd total \(totalSize) != file size \(data.count)")
        }
        let version = try r.u32(0x10)
        let sectionCount = Int(try r.u32(0x14))

        var sections: [Section] = []
        var tracks: [Track] = []
        var albums: [Album] = []
        var playlists: [Playlist] = []

        var pos = headerSize
        for _ in 0..<sectionCount {
            try r.expectMagic("mhsd", at: pos)
            let section = Section(offset: pos,
                                  type: try r.u32(pos + 12),
                                  headerSize: Int(try r.u32(pos + 4)),
                                  totalSize: Int(try r.u32(pos + 8)))
            let sectionEnd = pos + section.totalSize
            // The size guards double as loop-progress guards: a zero-sized
            // section would otherwise walk in place for sectionCount rounds.
            guard section.headerSize >= minSectionHeader,
                  section.totalSize >= section.headerSize,
                  sectionEnd <= data.count else {
                throw ParseError(offset: pos, message:
                    "mhsd sizes invalid (header \(section.headerSize), total \(section.totalSize))")
            }
            sections.append(section)

            let list = section.listOffset
            let firstRecord = list + Int(try r.u32(list + 4))
            let recordCount = Int(try r.u32(list + 8))
            switch try r.magic(list) {
            case "mhlt":
                try walkChildren(r, magic: "mhit", from: firstRecord,
                                 count: recordCount, limit: sectionEnd) {
                    tracks.append(try parseTrack(r, at: $0, totalSize: $1))
                }
            case "mhla":
                try walkChildren(r, magic: "mhia", from: firstRecord,
                                 count: recordCount, limit: sectionEnd,
                                 minSize: 0x1C) {
                    albums.append(Album(offset: $0, totalSize: $1,
                                        id: try r.u32($0 + 0x10),
                                        persistentID: try r.u64($0 + 0x14)))
                }
            case "mhlp":
                try walkChildren(r, magic: "mhyp", from: firstRecord,
                                 count: recordCount, limit: sectionEnd) {
                    playlists.append(try parsePlaylist(
                        r, at: $0, totalSize: $1, section: section))
                }
            case let other:
                throw ParseError(offset: list, message:
                    "unknown section child '\(other)' in mhsd type \(section.type)")
            }
            pos = sectionEnd
        }
        guard pos == data.count else {
            throw ParseError(offset: pos, message:
                "sections cover 0x\(String(pos, radix: 16)) of 0x\(String(data.count, radix: 16)) bytes")
        }

        return ITunesDB(version: version, sections: sections, tracks: tracks,
                        albums: albums, playlists: playlists)
    }

    // MARK: - Record parsers

    private static func parseTrack(
        _ r: Reader, at pos: Int, totalSize: Int
    ) throws -> Track {
        let headerSize = Int(try r.u32(pos + 4))
        guard headerSize >= minTrackHeader, headerSize <= totalSize else {
            throw ParseError(offset: pos, message:
                "mhit header \(headerSize) too small — pre-0x75 format?")
        }
        var title: (text: String, range: Range<Int>)?
        var path: (text: String, range: Range<Int>)?
        var kind: Range<Int>?
        try walkChildren(r, magic: "mhod", from: pos + headerSize,
                         count: Int(try r.u32(pos + 0x0C)),
                         limit: pos + totalSize) { mhod, mhodTotal in
            // First occurrence wins, matching the reference implementation.
            switch try r.u32(mhod + 12) {
            case 1 where title == nil:
                title = (try stringPayload(r, at: mhod, totalSize: mhodTotal),
                         mhod..<(mhod + mhodTotal))
            case 2 where path == nil:
                path = (try stringPayload(r, at: mhod, totalSize: mhodTotal),
                        mhod..<(mhod + mhodTotal))
            case 6 where kind == nil:
                kind = mhod..<(mhod + mhodTotal)
            default:
                break
            }
        }
        return Track(
            offset: pos,
            totalSize: totalSize,
            id: try r.u32(pos + 0x10),
            title: title?.text ?? "",
            path: path?.text ?? "",
            fileSize: try r.u32(pos + 0x24),
            durationMs: try r.u32(pos + 0x28),
            dbid: try r.u64(pos + 0x70),
            mediaType: try r.u32(pos + 0xD0),
            albumID: try r.u32(pos + 0x120),
            titleMhodRange: title?.range,
            pathMhodRange: path?.range,
            kindMhodRange: kind)
    }

    private static func parsePlaylist(
        _ r: Reader, at pos: Int, totalSize: Int, section: Section
    ) throws -> Playlist {
        let headerSize = Int(try r.u32(pos + 4))
        guard headerSize >= minPlaylistHeader, headerSize <= totalSize else {
            throw ParseError(offset: pos, message:
                "mhyp header \(headerSize) too small")
        }
        var title = ""
        var isSmart = false
        let itemsStart = try walkChildren(
            r, magic: "mhod", from: pos + headerSize,
            count: Int(try r.u32(pos + 12)),
            limit: pos + totalSize, exactEnd: false) { mhod, mhodTotal in
            switch try r.u32(mhod + 12) {
            case 1: title = try stringPayload(r, at: mhod, totalSize: mhodTotal)
            case 50, 51: isSmart = true
            default: break
            }
        }

        var items: [PlaylistItem] = []
        try walkChildren(r, magic: "mhip", from: itemsStart,
                         count: Int(try r.u32(pos + 16)),
                         limit: pos + totalSize, minSize: minItemSize) { mhip, mhipTotal in
            items.append(PlaylistItem(offset: mhip,
                                      totalSize: mhipTotal,
                                      itemID: try r.u32(mhip + 0x14),
                                      trackID: try r.u32(mhip + 0x18),
                                      trackDBID: try r.u64(mhip + 0x2C)))
        }

        return Playlist(offset: pos, totalSize: totalSize, section: section,
                        isMaster: try r.byte(pos + 20) != 0,
                        isSmart: isSmart, title: title,
                        persistentID: try r.u64(pos + 28), items: items)
    }

    /// Walks a chain of same-magic children, enforcing that every record is
    /// at least `minSize` bytes (so fixed-offset reads stay inside it and
    /// the walk always advances), stays inside `limit`, and (when
    /// `exactEnd`) that the chain lands exactly on it. Returns the position
    /// after the last child.
    @discardableResult
    private static func walkChildren(
        _ r: Reader, magic: String, from start: Int, count: Int, limit: Int,
        exactEnd: Bool = true, minSize: Int = 16,
        visit: (_ offset: Int, _ totalSize: Int) throws -> Void
    ) throws -> Int {
        var pos = start
        for _ in 0..<count {
            try r.expectMagic(magic, at: pos)
            let total = Int(try r.u32(pos + 8))
            guard total >= minSize, pos + total <= limit else {
                throw ParseError(offset: pos, message:
                    "'\(magic)' record size \(total) invalid for its parent")
            }
            try visit(pos, total)
            pos += total
        }
        guard !exactEnd || pos == limit else {
            throw ParseError(offset: pos, message:
                "'\(magic)' chain ends at 0x\(String(pos, radix: 16)), expected 0x\(String(limit, radix: 16))")
        }
        return pos
    }

    /// UTF-16LE payload of a string mhod: byte length at header+4,
    /// characters at header+16 — all bounded by the mhod's own size.
    private static func stringPayload(
        _ r: Reader, at pos: Int, totalSize: Int
    ) throws -> String {
        let headerSize = Int(try r.u32(pos + 4))
        let byteLength = Int(try r.u32(pos + headerSize + 4))
        guard headerSize + 16 + byteLength <= totalSize else {
            throw ParseError(offset: pos, message:
                "string payload (\(byteLength) bytes) overruns its mhod")
        }
        let bytes = try r.bytes(pos + headerSize + 16, count: byteLength)
        guard let s = String(data: bytes, encoding: .utf16LittleEndian) else {
            throw ParseError(offset: pos, message: "undecodable UTF-16 string")
        }
        return s
    }
}

// MARK: - Bounds-checked little-endian reader

/// Shared by the parser and the splice writer (ITunesDBWriter).
struct Reader {
    private let data: Data

    // Re-base to zero-indexed storage: Data slices (prefix/dropFirst/…)
    // keep their parent's indices and would trap in subdata(in:).
    init(_ data: Data) { self.data = Data(data) }

    private func check(_ offset: Int, count: Int) throws {
        guard offset >= 0, count >= 0, offset + count <= data.count else {
            throw ITunesDB.ParseError(offset: offset, message:
                "read of \(count) bytes past end of file")
        }
    }

    /// In-place unaligned little-endian load — no intermediate Data copy.
    private func load<T: FixedWidthInteger>(_ offset: Int) throws -> T {
        try check(offset, count: MemoryLayout<T>.size)
        return data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        }.littleEndian
    }

    func byte(_ offset: Int) throws -> UInt8 { try load(offset) }
    func u32(_ offset: Int) throws -> UInt32 { try load(offset) }
    func u64(_ offset: Int) throws -> UInt64 { try load(offset) }

    /// Payload extraction (string contents) — the one legitimate copy.
    func bytes(_ offset: Int, count: Int) throws -> Data {
        try check(offset, count: count)
        return data.subdata(in: offset..<(offset + count))
    }

    func magic(_ offset: Int) throws -> String {
        String(decoding: try bytes(offset, count: 4), as: UTF8.self)
    }

    func expectMagic(_ expected: String, at offset: Int) throws {
        let found = try magic(offset)
        guard found == expected else {
            throw ITunesDB.ParseError(offset: offset, message:
                "expected '\(expected)', found '\(found)'")
        }
    }
}
