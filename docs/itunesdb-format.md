# iTunesDB format — iPod Video 5G/5.5G, DB version 0x75

Distilled from byte-level reverse engineering and on-device experiments
(2026-07-02, two devices: HFS+/Mac-formatted and FAT32/Windows-formatted).
This is the spec for PodFlick's Swift DB layer. The reference Python
implementation and golden fixtures live in `reference/`.

## Scope and ground rules

- Applies to iPod Video 5G/5.5G ("classic" pre-2007). These devices do NOT
  checksum the DB (no `SysInfoExtended` on device = no hash needed).
  iPod classic 6G+ requires hash58/72 — out of scope for v1.
- All integers little-endian. Strings UTF-16LE.
- Timestamps are Mac epoch: unix time + 2082844800.
- The DB lives at `iPod_Control/iTunes/iTunesDB` on the (FAT32 or HFS+)
  data partition. Everything is plain file I/O — no USB protocol work.

## PROVEN firmware behaviors (each verified on a real device)

1. **Wholesale DB regeneration is rejected** even when structurally perfect
   (our regenerated DB parsed clean, matched every header, and the firmware
   still showed an empty library). Suspected causes: id magnitude / wholesale
   dbid replacement / album-record scheme. Never pinned — irrelevant, because:
2. **Surgical in-place splices are accepted**: replace/insert a record, bump
   the size fields of every enclosing record (mhbd, mhsd, mhit/mhyp), done.
   This is the ONLY mutation strategy PodFlick uses.
3. **New tracks: clone a proven-visible donor** mhit/mhip from the current
   DB, swap only per-file fields (ids, dbid, title, path, size, duration,
   dates). Zero divergence from accepted byte patterns.
4. A track **absent from all mhod52/53 indexes still lists and plays** in
   Videos. Album id 0 and zeroed cross-refs are fine too. So `add` does not
   touch indexes, albums, or smart playlists.
5. `iTunesPrefs.plist` `MovieTrackIDs` stays EMPTY on working Finder-synced
   iPods — do not touch iTunesPrefs (April 2026 red herring).
6. Delete `Play Counts` after rewriting the DB (it indexes tracks by mhlt
   position; iTunes deletes it after sync too). Firmware recreates it.
7. **Eject discipline**: after writing, `sync` + a CLEAN eject. Spotlight
   (`mds_stores`) often dissents iPod ejects; kill it and retry rather than
   force-eject. A `.metadata_never_index` marker on the volume helps.

## Record tree (as written by Finder/iTunes 12.x, version 0x75)

```
mhbd (header 0xF4)                      — database header
├── mhsd type=4 → mhla → mhia*          — album list
├── mhsd type=1 → mhlt → mhit*          — track list
│                        └── mhod 1,6,2 — title, "MPEG-4 video file", path
├── mhsd type=3 → mhlp → mhyp (master)  — playlist set, copy #1
├── mhsd type=2 → mhlp → mhyp (master)  — identical copy #2 (legacy slot)
│         master mhyp children: mhod1 title, mhod100 (648 B), mhod102 (356 B),
│         10× mhod52 (sorted indexes) + 6× mhod53 (letter jump tables),
│         then mhip* (one per track) each with a child mhod100 (44 B)
└── mhsd type=5 → mhlp → 5× mhyp        — SMART playlists: Audiobooks, Movies,
          Music, TV Shows, Videos — mhod 50/51 rule blobs, track-independent.
          The device's Videos/Movies menus come from these + the master list.
```

Every record: `magic(4) header_size(4) total_size(4) ...`. List headers
(mhlt/mhlp/mhla) have `count` at +8 instead of total_size; their children's
sizes are covered by the enclosing mhsd's total.

## mhbd header (0xF4 bytes)

| off  | field |
|------|-------|
| 0x08 | total file size (the ONLY field to bump on edits) |
| 0x10 | version (0x75 here) |
| 0x14 | number of mhsd sections (5) |
| 0x18 | db persistent id (u64) |
| 0x24 | library persistent id — also embedded in the binary `iTunesPrefs` (frpd); must stay consistent, so never regenerate it |

Copy the whole header verbatim from the device's own DB; only 0x08 changes.

## mhit — track record (header 0x270, Finder layout)

| off   | field |
|-------|-------|
| 0x0C  | number of child mhods |
| 0x10  | track id |
| 0x14  | visible = 1 |
| 0x18  | filetype: 'M4V ' as LE u32 = 0x4D345620 (or 'MP4 ' 0x4D503420) |
| 0x20  | date modified (Mac ts) |
| 0x24  | file size (u32; duplicated at 0x12C) |
| 0x28  | duration ms |
| 0x38  | 0x7D constant |
| 0x68  | date added (Mac ts) |
| 0x70  | dbid (u64, random, nonzero) |
| 0x90  | 0x33; 0x93 flag varies 0/1 (both accepted) |
| 0xA4  | 02 01 01 |
| 0xB1  | 01; 0xB2 = 02 |
| 0xD0  | mediatype: 2 = Movie |
| 0x100 | 1 (0 also seen on a working track) |
| 0x120 | album (mhia) id — 0 is legal (no album) |
| 0x134 | 6× 0x80 volume normalization |
| 0x168 | 1 |
| 0x195 | flag varies 0/1 |
| 0x1E0 | related id (0 is legal) |
| 0x1F4 | related id, usually track_id+1 (0 is legal) |
| 0x20C | 2 |

Child mhods, in order: type 1 (title), type 6 (kind string
"MPEG-4 video file"), type 2 (path like `:iPod_Control:Music:F16:JHBI.m4v`).

## mhod — string types 1 (title) / 2 (path)

`hdr 0x18; total = 0x18+16+len` — EXACT, never rounded up: Finder writes
unaligned totals (86, 118 in the fixtures) and the firmware rejects a DB
whose title mhod carries trailing alignment padding (proven on device
2026-07-04: 2 pad bytes → empty menus). Payload: `encoding=1(u32),
byte_len(u32), flag=1(u32), pad(u32)`, then UTF-16LE bytes. Type 6 (kind) is
similar with the flag at payload+8 — clone it from a donor.

## mhip — playlist member (0x4C header, 0x78 total incl. child)

| off  | field |
|------|-------|
| 0x0C | child mhod count = 1 |
| 0x14 | item id (unique; Finder allocates from a global counter) |
| 0x18 | track id |
| 0x1C | Mac ts |
| 0x2C | track dbid (u64) |
| 0x3C | item dbid (u64, random) |

Child mhod100 (0x2C total): u32 at payload+0 = an order/position value
(NOT an item-id echo; any increasing value works).

## mhod52 / mhod53 — library indexes (informational; PodFlick never edits)

- mhod52: `hdr 0x18; sort_field(u32) count(u32) unk[40] entries(u32×count)` —
  entries are positions in mhlt order, sorted by the field. Sort fields seen:
  3 title, 4 album, 5 artist, 7 genre, 18 composer, 29/30/31/35/36 show-era.
- mhod53: `hdr 0x18; sort_field(u32) bucket_count(u32) unk[8]` then per
  bucket `{letter(u32), first_index(u32), count(u32)}`. Letters: uppercase
  ASCII for A–Z, 0x30 ('0') for digits/non-Latin, 0x00 for empty values.
- Firmware tolerates index count < track count (Finder ships such DBs).

## mhia — album record (0x58, no children required)

`+0x10 album id (= mhit 0x120 of referencing tracks), +0x14 album dbid (u64),
+0x1C = 2`. Finder dedupes; tracks may share one mhia or reference none (0).

## Mutation recipes (what the Swift layer implements)

**add(track)**: pick donor mhit (prefer one with album id 0) → clone header,
swap fields, rebuild the 3 child mhods → splice at the end of the mhlt
section (bump mhsd1 total, mhlt count, mhbd total) → for each of the two
master mhyps, clone its last mhip, swap ids, splice at mhyp end (bump mhyp
total & mhip count, that mhsd total, mhbd total). Apply splices in
descending file-offset order; new ids = max(existing)+2, +3.

**rename(track, title)**: replace the title mhod in place; bump mhit total,
enclosing mhsd total, mhbd total by the length delta.

**remove(track)**: delete the mhit and both mhips; decrement the same
counters/sizes; delete the media file.

**Invariant test**: add then remove must return the DB byte-identical.
**Golden test**: the parser must round-trip `reference/fixtures/*` and the
writer's `--selftest` must regenerate the single-track fixture byte-exactly.

## Video file requirements (5G vs 5.5G stock firmware)

5G: H.264 Baseline ≤L1.3 ≤320×240 ≤768 kbps. 5.5G adds a Low-Complexity
640×480 ≤1.5 Mbps H.264 mode. Both: ≤30fps + AAC-LC stereo ≤160 kbps
≤48 kHz, in .m4v/.mp4/.mov. The firmware lists what the DB says but won't
play out-of-spec files — a 640×480 L3.0 file on the real 5G decodes to a
black screen with a running timer (B.5.1 smoke, 2026-07-04); every file
proven playing on it is 320×240 L1.3. BOTH operator devices proved
5G-class this way: the 640×480 L3.0 test clip decodes black on each
(B.5.3 verdict, 2026-07-04) — neither is a 5.5G. Legacy MPEG-4 SP alternative:
≤2.5 Mbps. PodFlick encodes to the 5G limit so output plays on both;
`reference/convert_to_ipod.sh`'s 640×480 recipe is the 5.5G-only variant.
Beware pre-UTF-8 metadata: a Windows-1251 `©nam` tag gave Finder an empty
title (PodFlick should transcode/set the title tag itself).
