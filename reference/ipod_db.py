#!/usr/bin/env python3
"""
iTunesDB generator for iPod 5G/5.5G (video) — builds the ENTIRE database from
scratch instead of patching it in place (the April 2026 approach that kept
corrupting the DB).

Design: a known-good, Finder-written single-video database
(iTunesDB_finder_dump, DB version 0x75) is used as a byte-exact template.
All track-independent blocks (mhbd header, playlist-column mhod100, jump-table
mhod102, the five smart playlists in mhsd type=5, playlist title) are copied
verbatim from the template; all track-dependent records (mhia, mhit, mhod52
library indexes, mhod53 letter-jump tables, mhip) are generated.

Correctness gate: `python3 ipod_db.py --selftest` regenerates the database for
the exact track contained in the template and byte-diffs the result against
the template. Zero differences == the generator reproduces Finder's output.

Why the April scripts failed (root cause): the firmware builds its menus from
the mhod52 sorted index tables in the master playlist and from the smart
playlists (Movies/Videos/...) in mhsd type=5. In-place insertion of mhit/mhip
left the mhod52/53 counts stale and inconsistent with mhlt, so the firmware
treated the DB as corrupt: the file occupied disk space but never appeared in
any menu.
"""
import struct
import sys
from pathlib import Path

MAC_EPOCH = 2082844800  # seconds between 1904-01-01 and 1970-01-01

# A real Finder-written iTunesDB, anonymized (track title → "Sample Video 1").
# The anonymization also re-blessed the two letter-jump bucket bytes (0xC54,
# 0x16B2) from '0' to 'S' so the fixture stays internally consistent with its
# own title — Finder buckets an "S…" title under 'S', not '0'. Without that the
# --selftest byte-diff fails on those two bytes (B.23).
TEMPLATE_PATH = Path(__file__).parent / 'iTunesDB_finder_dump'

# Order of mhod52 sort fields in the master playlist, as written by Finder.
# True = the mhod52 is followed by an mhod53 letter-jump table.
MHOD52_LAYOUT = [
    (3, True),   # title
    (5, True),   # artist
    (4, True),   # album
    (7, True),   # genre
    (18, True),  # composer
    (35, False),
    (36, False),
    (29, True),  # show
    (30, False),
    (31, False),
]


def r32(d, o):
    return struct.unpack_from('<I', d, o)[0]


def w32(b, o, v):
    struct.pack_into('<I', b, o, v)


# ─────────────────────────────────────────────────────────────────────────────
# Template extraction
# ─────────────────────────────────────────────────────────────────────────────

class Template:
    """Extracts the constant building blocks from the Finder-written DB."""

    def __init__(self, data=None):
        d = data if data is not None else TEMPLATE_PATH.read_bytes()
        assert d[:4] == b'mhbd', 'template is not an iTunesDB'
        self.mhbd_hdr = bytes(d[:r32(d, 4)])

        # Walk the mhsd sections.
        pos = r32(d, 4)
        sections = {}
        for _ in range(r32(d, 0x14)):
            assert d[pos:pos+4] == b'mhsd'
            stype = r32(d, pos + 12)
            sections[stype] = (pos, r32(d, pos + 8))
            pos += r32(d, pos + 8)
        self.mhsd_hdr_size = 0x60  # constant in template

        # mhsd type=5: smart playlists — fully track-independent, copy verbatim.
        s5_pos, s5_total = sections[5]
        self.smart_section = bytes(d[s5_pos:s5_pos + s5_total])

        # List headers (contain a count field that we patch when building).
        p4, _ = sections[4]
        mhla = p4 + self.mhsd_hdr_size
        self.mhla_hdr = bytes(d[mhla:mhla + r32(d, mhla + 4)])
        p1, _ = sections[1]
        mhlt = p1 + self.mhsd_hdr_size
        self.mhlt_hdr = bytes(d[mhlt:mhlt + r32(d, mhlt + 4)])
        p3, _ = sections[3]
        mhlp = p3 + self.mhsd_hdr_size
        self.mhlp_hdr = bytes(d[mhlp:mhlp + r32(d, mhlp + 4)])

        # Master playlist: header + title/mhod100/mhod102 blobs.
        mhyp = mhlp + r32(d, mhlp + 4)
        assert d[mhyp:mhyp+4] == b'mhyp'
        self.mhyp_hdr = bytes(d[mhyp:mhyp + r32(d, mhyp + 4)])
        c = mhyp + r32(d, mhyp + 4)
        self.master_mhods = []  # title (type 1), mhod100, mhod102 — verbatim
        for _ in range(3):
            assert d[c:c+4] == b'mhod'
            self.master_mhods.append(bytes(d[c:c + r32(d, c + 8)]))
            c += r32(d, c + 8)

        # Reference mhit fields (self-test only; absent in an empty DB).
        try:
            mhit = mhlt + r32(d, mhlt + 4)
            assert d[mhit:mhit+4] == b'mhit'
            self.ref = self._read_ref_track(d, mhit, p4)
        except Exception:
            self.ref = None

    @staticmethod
    def _read_ref_track(d, mhit, p4):
        hdr = r32(d, mhit + 4)
        mhods = {}
        c = mhit + hdr
        for _ in range(r32(d, mhit + 12)):
            t = r32(d, c + 12)
            mh = r32(d, c + 4)
            slen = r32(d, c + mh + 4)
            mhods[t] = d[c + mh + 16:c + mh + 16 + slen].decode('utf-16-le')
            c += r32(d, c + 8)
        mhia = p4 + 0x60
        mhia += r32(d, mhia + 4)  # skip mhla header
        mhip = d.find(b'mhip')
        return {
            'track_id': r32(d, mhit + 0x10),
            'dbid': struct.unpack_from('<Q', d, mhit + 0x70)[0],
            'album_dbid': struct.unpack_from('<Q', d, mhia + 0x14)[0],
            'item_dbid': struct.unpack_from('<Q', d, mhip + 0x3C)[0],
            'size': r32(d, mhit + 0x24),
            'duration_ms': r32(d, mhit + 0x28),
            'date_modified': r32(d, mhit + 0x20),
            'date_added': r32(d, mhit + 0x68),
            'title': mhods[1],
            'ipod_path': mhods[2],
        }


# ─────────────────────────────────────────────────────────────────────────────
# Generated records (layouts calibrated against the Finder template)
# ─────────────────────────────────────────────────────────────────────────────

def make_mhod_string(mhod_type, text):
    """mhod type 1 (title) / 2 (path): 24-byte header, then
    encoding(4) len(4) unk(8), UTF-16LE string, padded to 4 bytes."""
    enc = text.encode('utf-16-le')
    total = (0x18 + 16 + len(enc) + 3) & ~3
    b = bytearray(total)
    b[0:4] = b'mhod'
    w32(b, 4, 0x18)
    w32(b, 8, total)
    w32(b, 12, mhod_type)
    w32(b, 0x18, 1)            # encoding: UTF-16LE
    w32(b, 0x1C, len(enc))
    w32(b, 0x20, 1)
    b[0x28:0x28 + len(enc)] = enc
    return bytes(b)


def make_mhod_kind(text='MPEG-4 video file'):
    """mhod type 6 (file kind): same shape but no trailing padding and the
    encoding flag sits at +8 of the payload."""
    enc = text.encode('utf-16-le')
    total = 0x18 + 16 + len(enc)
    b = bytearray(total)
    b[0:4] = b'mhod'
    w32(b, 4, 0x18)
    w32(b, 8, total)
    w32(b, 12, 6)
    w32(b, 0x18, 1)
    w32(b, 0x1C, len(enc))
    w32(b, 0x20, 1)
    b[0x28:0x28 + len(enc)] = enc
    return bytes(b)


def make_mhit(v):
    """Track record, 0x270-byte Finder layout. `v` is a video dict."""
    children = (make_mhod_string(1, v['title'])
                + make_mhod_kind()
                + make_mhod_string(2, v['ipod_path']))
    HDR = 0x270
    b = bytearray(HDR)
    tid = v['track_id']
    b[0:4] = b'mhit'
    w32(b, 0x04, HDR)
    w32(b, 0x08, HDR + len(children))
    w32(b, 0x0C, 3)                                  # mhod count
    w32(b, 0x10, tid)
    w32(b, 0x14, 1)                                  # visible
    w32(b, 0x18, 0x4D345620)                         # filetype 'M4V '
    w32(b, 0x20, v['date_modified'])
    w32(b, 0x24, v['size'] & 0xFFFFFFFF)
    w32(b, 0x28, v['duration_ms'])
    b[0x38] = 0x7D
    w32(b, 0x68, v['date_added'])
    struct.pack_into('<Q', b, 0x70, v['dbid'])
    b[0x90] = 0x33
    b[0x93] = 0x01
    b[0xA4:0xA7] = b'\x02\x01\x01'
    b[0xB1] = 0x01
    b[0xB2] = 0x02
    w32(b, 0xD0, 2)                                  # mediatype: Movie
    w32(b, 0x100, 1)
    w32(b, 0x120, tid + 6)                           # album (mhia) id
    w32(b, 0x12C, v['size'] & 0xFFFFFFFF)
    b[0x134:0x13A] = b'\x80' * 6                     # volume normalization
    w32(b, 0x168, 1)
    b[0x195] = 0x01
    w32(b, 0x1E0, tid + 7)
    w32(b, 0x1F4, tid + 1)
    w32(b, 0x20C, 2)
    return bytes(b) + children


def make_mhia(v):
    """Album record referenced by mhit field 0x120 (id = track_id + 6)."""
    b = bytearray(0x58)
    b[0:4] = b'mhia'
    w32(b, 4, 0x58)
    w32(b, 8, 0x58)
    w32(b, 0x10, v['track_id'] + 6)
    struct.pack_into('<Q', b, 0x14, v['album_dbid'])
    w32(b, 0x1C, 2)
    return bytes(b)


def make_mhip(v):
    """Playlist member. item_id = track_id + 5, child mhod100 echoes it."""
    tid = v['track_id']
    b = bytearray(0x4C)
    b[0:4] = b'mhip'
    w32(b, 0x04, 0x4C)
    w32(b, 0x08, 0x78)          # total incl. child mhod100
    w32(b, 0x0C, 1)             # child mhod count
    w32(b, 0x14, tid + 5)
    w32(b, 0x18, tid)
    w32(b, 0x1C, v['date_added'])
    struct.pack_into('<Q', b, 0x2C, v['dbid'])
    struct.pack_into('<Q', b, 0x3C, v['item_dbid'])
    m = bytearray(0x2C)
    m[0:4] = b'mhod'
    w32(m, 4, 0x18)
    w32(m, 8, 0x2C)
    w32(m, 12, 100)
    w32(m, 0x18, tid + 5)
    return bytes(b) + bytes(m)


def make_mhod52(sort_field, order):
    """Sorted library index: 24-byte header, field(4), count(4), unk(40),
    then count × u32 track positions (indexes into mhlt order)."""
    total = 0x18 + 4 + 4 + 40 + 4 * len(order)
    b = bytearray(total)
    b[0:4] = b'mhod'
    w32(b, 4, 0x18)
    w32(b, 8, total)
    w32(b, 12, 52)
    w32(b, 0x18, sort_field)
    w32(b, 0x1C, len(order))
    for i, idx in enumerate(order):
        w32(b, 0x48 + 4 * i, idx)
    return bytes(b)


def _bucket_letter(key):
    """Letter-jump bucket for a sort key, as Finder computes it:
    0x00 for an empty value, the uppercase ASCII letter for A-Z,
    '0' for digits and anything non-Latin."""
    if not key:
        return 0
    c = key[0].upper()
    return ord(c) if 'A' <= c <= 'Z' else 0x30


def make_mhod53(sort_field, keys_sorted):
    """Letter jump table for the preceding mhod52: header, field(4),
    bucket_count(4), unk(8), then per bucket {letter(4), first(4), count(4)}.
    `keys_sorted` are the sort-key strings in mhod52 order."""
    buckets = []  # (letter, first_index, count)
    for i, key in enumerate(keys_sorted):
        letter = _bucket_letter(key)
        if buckets and buckets[-1][0] == letter:
            buckets[-1][2] += 1
        else:
            buckets.append([letter, i, 1])
    total = 0x18 + 4 + 4 + 8 + 12 * len(buckets)
    b = bytearray(total)
    b[0:4] = b'mhod'
    w32(b, 4, 0x18)
    w32(b, 8, total)
    w32(b, 12, 53)
    w32(b, 0x18, sort_field)
    w32(b, 0x1C, len(buckets))
    for i, (letter, first, count) in enumerate(buckets):
        w32(b, 0x28 + 12 * i, letter)
        w32(b, 0x2C + 12 * i, first)
        w32(b, 0x30 + 12 * i, count)
    return bytes(b)


# ─────────────────────────────────────────────────────────────────────────────
# Assembly
# ─────────────────────────────────────────────────────────────────────────────

def _mhsd(stype, payload, hdr_size=0x60):
    b = bytearray(hdr_size)
    b[0:4] = b'mhsd'
    w32(b, 4, hdr_size)
    w32(b, 8, hdr_size + len(payload))
    w32(b, 12, stype)
    return bytes(b) + payload


def _list(hdr_blob, count, payload):
    b = bytearray(hdr_blob)
    w32(b, 8, count)
    return bytes(b) + payload


def _master_playlist(tpl, videos, order):
    mhods = b''.join(tpl.master_mhods)
    n_mhod = 3
    # Only titles carry values for videos; every other sort field is empty.
    title_keys = [videos[i]['title'] for i in order]
    for field, has53 in MHOD52_LAYOUT:
        mhods += make_mhod52(field, order)
        n_mhod += 1
        if has53:
            keys = title_keys if field == 3 else [''] * len(videos)
            mhods += make_mhod53(field, keys)
            n_mhod += 1
    mhips = b''.join(make_mhip(v) for v in videos)
    hdr = bytearray(tpl.mhyp_hdr)
    w32(hdr, 8, len(hdr) + len(mhods) + len(mhips))
    w32(hdr, 12, n_mhod)
    w32(hdr, 16, len(videos))
    return bytes(hdr) + mhods + mhips


def build_db(videos, template=None):
    """videos: list of dicts with keys
    title, ipod_path, size, duration_ms, track_id, dbid, album_dbid,
    date_added, date_modified. Returns the complete iTunesDB as bytes."""
    tpl = template or Template()
    # Sort order shared by every mhod52: by title, case-insensitive.
    order = sorted(range(len(videos)), key=lambda i: videos[i]['title'].casefold())

    s4 = _mhsd(4, _list(tpl.mhla_hdr, len(videos),
                        b''.join(make_mhia(v) for v in videos)))
    s1 = _mhsd(1, _list(tpl.mhlt_hdr, len(videos),
                        b''.join(make_mhit(v) for v in videos)))
    master = _master_playlist(tpl, videos, order)
    s3 = _mhsd(3, _list(tpl.mhlp_hdr, 1, master))
    s2 = _mhsd(2, _list(tpl.mhlp_hdr, 1, master))
    body = s4 + s1 + s3 + s2 + tpl.smart_section

    hdr = bytearray(tpl.mhbd_hdr)
    w32(hdr, 8, len(hdr) + len(body))
    return bytes(hdr) + body


# ─────────────────────────────────────────────────────────────────────────────
# Self-test: regenerate the template's own DB and byte-diff it
# ─────────────────────────────────────────────────────────────────────────────

def selftest():
    ref_data = TEMPLATE_PATH.read_bytes()
    tpl = Template(ref_data)
    generated = build_db([tpl.ref], template=tpl)
    if generated == ref_data:
        print(f'SELFTEST OK: generated DB is byte-identical to the Finder '
              f'template ({len(generated)} bytes)')
        return 0
    print(f'SELFTEST FAIL: generated {len(generated)} bytes, '
          f'template {len(ref_data)} bytes')
    n = 0
    for off in range(min(len(generated), len(ref_data))):
        if generated[off] != ref_data[off]:
            print(f'  diff @0x{off:X}: gen={generated[off]:02X} '
                  f'ref={ref_data[off]:02X}')
            n += 1
            if n >= 30:
                print('  ... (truncated)')
                break
    return 1


if __name__ == '__main__':
    if '--selftest' in sys.argv:
        sys.exit(selftest())
    print(__doc__)
