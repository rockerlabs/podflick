#!/usr/bin/env python3
"""
iPod 5G video sync, v3 (2026-07-02) — surgical in-place edits.

History: v1 (April) patched the DB in place with inconsistent sizes/indexes —
rejected. v2 regenerated the whole DB from a byte-exact template — structurally
perfect, still rejected by the firmware (root cause in the regenerated ids /
record style, never pinned down). v3 uses what the on-device experiments
PROVED the firmware accepts:

  * a title-mhod splice with 3 size-field bumps was accepted (2026-07-02);
  * a track that is absent from every mhod52 index, has album id 0 and
    zeroed cross-refs is still listed in Videos and plays («День выборов»).

So v3 never regenerates and never renumbers: to add a video it clones a
proven-visible mhit/mhip byte pattern from the CURRENT database, swaps only
the per-file fields (id, dbid, title, path, size, duration, dates), splices
the records in and bumps the enclosing size fields. mhod52/53 indexes are
left untouched (legal: Finder itself ships DBs whose index count < track
count). The DB on the device is the only source of truth — no manifest.

Usage:
    ./ipod_sync_v3.py list    <ipod_root>
    ./ipod_sync_v3.py add     <ipod_root> <file.m4v> [more files...]
    ./ipod_sync_v3.py rename  <ipod_root> <title substring> <new title>
    ./ipod_sync_v3.py remove  <ipod_root> <title substring>

Every mutating command backs up the current DB to
device_backups/ on the Samsung T5 if present, else next to the DB.
"""
import random
import shutil
import struct
import sys
import time
from pathlib import Path

MAC_EPOCH = 2082844800
BACKUP_DIR = Path('/Volumes/Samsung_T5/ffmpeg/device_backups')


def r32(d, o): return struct.unpack_from('<I', d, o)[0]
def r64(d, o): return struct.unpack_from('<Q', d, o)[0]
def w32(b, o, v): struct.pack_into('<I', b, o, v)
def w64(b, o, v): struct.pack_into('<Q', b, o, v)
def mac_time(): return int(time.time()) + MAC_EPOCH


# ─────────────────────────────────────────────────────────────────────────────
# MP4 duration (mvhd box), no ffprobe needed
# ─────────────────────────────────────────────────────────────────────────────

def mp4_duration_ms(path):
    def walk(f, start, end, wanted):
        f.seek(start)
        while start < end - 8:
            hdr = f.read(8)
            if len(hdr) < 8:
                return None
            size, kind = struct.unpack('>I4s', hdr)
            body = start + 8
            if size == 1:
                size = struct.unpack('>Q', f.read(8))[0]
                body = start + 16
            if size == 0:
                size = end - start
            if kind == wanted[0]:
                if len(wanted) == 1:
                    return body
                r = walk(f, body, start + size, wanted[1:])
                if r:
                    return r
            start += size
            f.seek(start)
        return None

    with open(path, 'rb') as f:
        f.seek(0, 2)
        mvhd = walk(f, 0, f.tell(), [b'moov', b'mvhd'])
        if mvhd is None:
            raise ValueError(f'no moov/mvhd box in {path}')
        f.seek(mvhd)
        version = f.read(4)[0]
        if version == 1:
            f.seek(16, 1)
            timescale, duration = struct.unpack('>IQ', f.read(12))
        else:
            f.seek(8, 1)
            timescale, duration = struct.unpack('>II', f.read(8))
        return int(duration * 1000 / timescale)


# ─────────────────────────────────────────────────────────────────────────────
# DB model: locate records without copying them
# ─────────────────────────────────────────────────────────────────────────────

class DB:
    def __init__(self, data):
        self.d = bytearray(data)
        assert self.d[:4] == b'mhbd', 'not an iTunesDB'

    def sections(self):
        """[(mhsd_pos, type, total)] in file order."""
        out, pos = [], r32(self.d, 4)
        for _ in range(r32(self.d, 0x14)):
            assert self.d[pos:pos+4] == b'mhsd'
            out.append((pos, r32(self.d, pos+12), r32(self.d, pos+8)))
            pos += r32(self.d, pos+8)
        return out

    def tracks(self):
        """[(mhit_pos, total, track_id, title, path)] from mhsd type=1."""
        out = []
        for pos, stype, total in self.sections():
            if stype != 1:
                continue
            mhlt = pos + r32(self.d, pos+4)
            c = mhlt + r32(self.d, mhlt+4)
            for _ in range(r32(self.d, mhlt+8)):
                assert self.d[c:c+4] == b'mhit'
                out.append((c, r32(self.d, c+8), r32(self.d, c+0x10),
                            self._mhod_str(c, 1), self._mhod_str(c, 2)))
                c += r32(self.d, c+8)
        return out

    def _mhod_str(self, mhit, want_type):
        c = mhit + r32(self.d, mhit+4)
        for _ in range(r32(self.d, mhit+0xC)):
            if self.d[c:c+4] != b'mhod':
                break
            if r32(self.d, c+12) == want_type:
                h = r32(self.d, c+4)
                slen = r32(self.d, c+h+4)
                return self.d[c+h+16:c+h+16+slen].decode('utf-16-le')
            c += r32(self.d, c+8)
        return ''

    def master_playlists(self):
        """[(mhyp_pos, mhsd_pos)] for the two master-playlist copies."""
        out = []
        for pos, stype, total in self.sections():
            if stype not in (2, 3):
                continue
            mhlp = pos + r32(self.d, pos+4)
            c = mhlp + r32(self.d, mhlp+4)
            for _ in range(r32(self.d, mhlp+8)):
                assert self.d[c:c+4] == b'mhyp'
                if self.d[c+20]:  # master flag
                    out.append((c, pos))
                c += r32(self.d, c+8)
        return out

    def mhips(self, mhyp):
        """[(mhip_pos, total, track_id, item_id)] inside one mhyp."""
        c = mhyp + r32(self.d, mhyp+4)
        for _ in range(r32(self.d, mhyp+12)):      # skip mhods
            c += r32(self.d, c+8)
        out = []
        for _ in range(r32(self.d, mhyp+16)):
            assert self.d[c:c+4] == b'mhip'
            out.append((c, r32(self.d, c+8), r32(self.d, c+0x18),
                        r32(self.d, c+0x14)))
            c += r32(self.d, c+8)
        return out

    def max_id(self):
        """Max id used by tracks, playlist items and albums."""
        m = 0
        for pos, total, tid, _, _ in self.tracks():
            m = max(m, tid, r32(self.d, pos+0x120))
        for mhyp, _ in self.master_playlists():
            for _, _, tid, iid in self.mhips(mhyp):
                m = max(m, tid, iid)
        return m

    # ── splicing ────────────────────────────────────────────────────────────

    def splice(self, at, new, old_len=0):
        """Replace old_len bytes at `at` with `new`; bump every enclosing
        size field (mhbd, containing mhsd, and containing mhit/mhyp/mhlt
        bookkeeping is the caller's job beyond what's listed)."""
        self.d[at:at+old_len] = new

    def bump(self, off, delta):
        w32(self.d, off, r32(self.d, off) + delta)


def string_mhod(mhod_type, text):
    """Title/path mhod in the live-DB layout (flag 1 at +0x20)."""
    enc = text.encode('utf-16-le')
    total = (0x18 + 16 + len(enc) + 3) & ~3
    b = bytearray(total)
    b[0:4] = b'mhod'
    w32(b, 4, 0x18)
    w32(b, 8, total)
    w32(b, 12, mhod_type)
    w32(b, 0x18, 1)
    w32(b, 0x1C, len(enc))
    w32(b, 0x20, 1)
    b[0x28:0x28+len(enc)] = enc
    return bytes(b)


# ─────────────────────────────────────────────────────────────────────────────
# Clone-based record builders (donor = a proven-visible track in this DB)
# ─────────────────────────────────────────────────────────────────────────────

def clone_mhit(db, donor_pos, tid, dbid, title, path, size, dur_ms):
    d = db.d
    hdr = r32(d, donor_pos+4)
    body = bytearray(d[donor_pos:donor_pos+hdr])
    now = mac_time()
    w32(body, 0x10, tid)
    w32(body, 0x20, now)                   # date_modified
    w32(body, 0x24, size & 0xFFFFFFFF)
    w32(body, 0x28, dur_ms)
    w32(body, 0x68, now)                   # date_added
    w64(body, 0x70, dbid)
    w32(body, 0x12C, size & 0xFFFFFFFF)
    # donor cross-refs stay as-is when zero (the proven pattern); if the
    # donor had album refs, zero them — we do not create mhia records.
    w32(body, 0x120, 0)
    w32(body, 0x1E0, 0)
    w32(body, 0x1F4, 0)
    children = (string_mhod(1, title)
                + bytes(_donor_kind_mhod(db, donor_pos))
                + string_mhod(2, path))
    w32(body, 0x0C, 3)
    w32(body, 0x08, hdr + len(children))
    return bytes(body) + children


def _donor_kind_mhod(db, donor_pos):
    """Copy the donor's type-6 'MPEG-4 video file' mhod verbatim."""
    d = db.d
    c = donor_pos + r32(d, donor_pos+4)
    for _ in range(r32(d, donor_pos+0xC)):
        if r32(d, c+12) == 6:
            return d[c:c+r32(d, c+8)]
        c += r32(d, c+8)
    raise ValueError('donor has no filetype mhod')


def clone_mhip(db, donor_pos, tid, item_id, dbid):
    d = db.d
    total = r32(d, donor_pos+8)
    body = bytearray(d[donor_pos:donor_pos+total])
    w32(body, 0x14, item_id)
    w32(body, 0x18, tid)
    w32(body, 0x1C, mac_time())
    w64(body, 0x2C, dbid)
    w64(body, 0x3C, random.getrandbits(63) | 1)
    # child mhod100 carries a position value: reuse donor's + a small bump
    hdr = r32(d, donor_pos+4)
    w32(body, hdr+0x18, r32(body, hdr+0x18) + 2)
    return bytes(body)


# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────

def db_path_of(ipod_root):
    p = Path(ipod_root) / 'iPod_Control' / 'iTunes' / 'iTunesDB'
    if not p.exists():
        sys.exit(f'error: {p} not found — is the iPod mounted?')
    return p


def backup(db_path):
    dest_dir = BACKUP_DIR if BACKUP_DIR.parent.exists() else db_path.parent
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f'iTunesDB.{time.strftime("%Y%m%d-%H%M%S")}'
    shutil.copy2(db_path, dest)
    print(f'  backup: {dest}')


def find_one(db, pattern):
    hits = [t for t in db.tracks() if pattern.casefold() in t[3].casefold()]
    if len(hits) != 1:
        sys.exit(f'error: {pattern!r} matches {len(hits)} track(s), need 1')
    return hits[0]


def cmd_list(ipod_root):
    db = DB(db_path_of(ipod_root).read_bytes())
    for pos, total, tid, title, path in db.tracks():
        dur = r32(db.d, pos+0x28) // 60000
        size = r32(db.d, pos+0x24) // 2**20
        print(f'  [{tid}] {title!r}  —  {dur} min, {size} MB, {path}')


def pick_donor(db):
    """A donor mhit: prefer a track with album id 0 (the proven minimal
    pattern), else any track."""
    tracks = db.tracks()
    if not tracks:
        sys.exit('error: DB has no tracks to clone from')
    for t in tracks:
        if r32(db.d, t[0]+0x120) == 0:
            return t[0]
    return tracks[0][0]


def cmd_add(ipod_root, files):
    root = Path(ipod_root)
    db_path = db_path_of(ipod_root)
    backup(db_path)
    for f in files:
        src = Path(f)
        if not src.is_file():
            print(f'  skip (not found): {src}')
            continue
        db = DB(db_path.read_bytes())
        title = src.stem
        if any(title == t[3] for t in db.tracks()):
            print(f'  skip (already on iPod): {title}')
            continue
        dur = mp4_duration_ms(src)
        size = src.stat().st_size

        folder = f'F{random.randint(0, 49):02d}'
        name = ''.join(random.choices('ABCDEFGHIJKLMNOPQRSTUVWXYZ', k=4)) \
            + src.suffix
        dest_dir = root / 'iPod_Control' / 'Music' / folder
        dest_dir.mkdir(parents=True, exist_ok=True)
        print(f'  copying {src.name} -> Music/{folder}/{name} '
              f'({size // 2**20} MB)...')
        shutil.copy2(src, dest_dir / name)
        ipod_path = f':iPod_Control:Music:{folder}:{name}'

        add_track(db, title, ipod_path, size, dur)
        db_path.write_bytes(db.d)
        print(f'  added: {title} ({dur // 60000} min), '
              f'DB now {len(db.d)} bytes')


def add_track(db, title, ipod_path, size, dur_ms):
    donor = pick_donor(db)
    base = db.max_id()
    tid, item_id = base + 2, base + 3
    dbid = random.getrandbits(63) | 1
    mhit = clone_mhit(db, donor, tid, dbid, title, ipod_path, size, dur_ms)

    # Collect all edits against CURRENT offsets, then apply high-to-low.
    edits = []   # (insert_at, blob, [(size_field_off, delta)...])
    # 1. mhit at the end of the track list
    for pos, stype, total in db.sections():
        if stype == 1:
            mhlt = pos + r32(db.d, pos+4)
            insert_at = pos + total
            edits.append((insert_at, mhit,
                          [(pos+8, len(mhit)), (8, len(mhit))],
                          (mhlt+8, 1)))
    # 2. one mhip at the end of each master playlist
    for mhyp, mhsd in db.master_playlists():
        donor_mhip = db.mhips(mhyp)[-1][0]
        blob = clone_mhip(db, donor_mhip, tid, item_id, dbid)
        insert_at = mhyp + r32(db.d, mhyp+8)
        edits.append((insert_at, blob,
                      [(mhyp+8, len(blob)), (mhsd+8, len(blob)),
                       (8, len(blob))],
                      (mhyp+16, 1)))

    for insert_at, blob, bumps, count_bump in sorted(edits, reverse=True):
        db.d[insert_at:insert_at] = blob
        for off, delta in bumps:
            db.bump(off, delta)
        off, delta = count_bump
        db.bump(off, delta)


def cmd_rename(ipod_root, pattern, new_title):
    db_path = db_path_of(ipod_root)
    backup(db_path)
    db = DB(db_path.read_bytes())
    mhit, total, tid, old_title, _ = find_one(db, pattern)
    c = mhit + r32(db.d, mhit+4)
    for _ in range(r32(db.d, mhit+0xC)):
        if r32(db.d, c+12) == 1:
            break
        c += r32(db.d, c+8)
    else:
        sys.exit('error: track has no title mhod')
    old_len = r32(db.d, c+8)
    new = string_mhod(1, new_title)
    delta = len(new) - old_len
    db.d[c:c+old_len] = new
    db.bump(mhit+8, delta)
    mhsd = db.d.rfind(b'mhsd', 0, mhit)
    db.bump(mhsd+8, delta)
    db.bump(8, delta)
    db_path.write_bytes(db.d)
    print(f'  renamed [{tid}] {old_title!r} -> {new_title!r}, '
          f'DB now {len(db.d)} bytes')


def cmd_remove(ipod_root, pattern):
    if not pattern.strip():
        sys.exit('error: remove needs a non-empty title substring')
    root = Path(ipod_root)
    db_path = db_path_of(ipod_root)
    backup(db_path)
    db = DB(db_path.read_bytes())
    mhit, total, tid, title, ipod_path = find_one(db, pattern)

    edits = []   # (pos, length, [(size_field_off, -delta)...], count_off)
    for pos, stype, stotal in db.sections():
        if stype == 1:
            mhlt = pos + r32(db.d, pos+4)
            edits.append((mhit, total, [(pos+8, -total), (8, -total)],
                          (mhlt+8, -1)))
    for mhyp, mhsd in db.master_playlists():
        for p, ptotal, ptid, _ in db.mhips(mhyp):
            if ptid == tid:
                edits.append((p, ptotal,
                              [(mhyp+8, -ptotal), (mhsd+8, -ptotal),
                               (8, -ptotal)],
                              (mhyp+16, -1)))

    for pos, length, bumps, count_bump in sorted(edits, reverse=True):
        del db.d[pos:pos+length]
        for off, delta in bumps:
            db.bump(off, delta)
        off, delta = count_bump
        db.bump(off, delta)

    db_path.write_bytes(db.d)
    rel = ipod_path.replace(':', '/').lstrip('/')
    (root / rel).unlink(missing_ok=True)
    print(f'  removed [{tid}] {title!r} (+file {rel}), '
          f'DB now {len(db.d)} bytes')


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    cmd, root = sys.argv[1], sys.argv[2]
    if cmd == 'list':
        cmd_list(root)
    elif cmd == 'add':
        cmd_add(root, sys.argv[3:])
    elif cmd == 'rename':
        if len(sys.argv) < 5:
            sys.exit('usage: rename <ipod_root> <pattern> <new title>')
        cmd_rename(root, sys.argv[3], ' '.join(sys.argv[4:]))
    elif cmd == 'remove':
        cmd_remove(root, ' '.join(sys.argv[3:]))
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    main()
