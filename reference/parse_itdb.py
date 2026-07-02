#!/usr/bin/env python3
"""Full structural parser for iTunesDB — walks the real tree (not naive find())."""
import struct, sys

def r32(d, o): return struct.unpack_from('<I', d, o)[0]
def r64(d, o): return struct.unpack_from('<Q', d, o)[0]

MHOD_TYPES = {
    1:'title', 2:'path', 3:'album', 4:'artist', 5:'genre', 6:'filetype',
    7:'eq', 8:'comment', 9:'category', 12:'composer', 13:'grouping',
    14:'desc', 15:'podcast-enc', 16:'podcast-rss', 17:'chapter',
    18:'subtitle', 19:'show', 20:'episode', 21:'tv-network',
    22:'albumartist', 23:'artist-sort', 24:'keywords', 25:'locale',
    27:'title-sort', 28:'album-sort', 29:'albumartist-sort',
    30:'composer-sort', 31:'show-sort', 32:'video-binary?',
    50:'smart-data', 51:'smart-rules', 52:'libraryindex', 53:'index53',
    100:'playlist-column', 102:'jump-table?', 200:'album(mhia)',
    201:'artist(mhia)', 202:'artist-sort(mhia)',
}

def mhod_str(d, pos):
    hdr = r32(d, pos+4); t = r32(d, pos+12)
    if t in (1,2,3,4,5,6,8,14,18,19,22,27,28) :
        # try both layouts: enc@hdr+0,len@hdr+4,str@hdr+16
        slen = r32(d, pos+hdr+4)
        raw = d[pos+hdr+16 : pos+hdr+16+slen]
        try: return repr(raw.decode('utf-16-le'))
        except Exception: return '?'
    return ''

def walk_mhod(d, pos, depth):
    hdr = r32(d, pos+4); total = r32(d, pos+8); t = r32(d, pos+12)
    name = MHOD_TYPES.get(t, f'type{t}')
    extra = mhod_str(d, pos)
    print(f"{'  '*depth}mhod @0x{pos:X} type={t}({name}) hdr=0x{hdr:X} total={total} {extra}")
    if t == 52:
        # library index: hdr+? -> sort field, count, then u32 indexes
        sort_field = r32(d, pos+hdr)
        count = r32(d, pos+hdr+4)
        idxs = [r32(d, pos+hdr+8+40+4*i) for i in range(min(count,10))]
        print(f"{'  '*depth}  index: sort_field={sort_field} count={count} first={idxs}")
    return total

def walk_mhit(d, pos, depth):
    hdr = r32(d, pos+4); total = r32(d, pos+8); n = r32(d, pos+12)
    tid = r32(d, pos+16)
    print(f"{'  '*depth}mhit @0x{pos:X} hdr=0x{hdr:X} total={total} nmhod={n} track_id={tid}")
    # dump interesting fields
    fields = {
        'visible@0x14': r32(d,pos+0x14), 'filetype@0x18': hex(r32(d,pos+0x18)),
        'bitrate?@0x34': r32(d,pos+0x34)&0xffff, 'size@0x24': r32(d,pos+0x24),
        'len_ms@0x28': r32(d,pos+0x28), 'date_add@0x68': r32(d,pos+0x68),
        'dbid@0x70': hex(r64(d,pos+0x70)), 'mediatype@0xD0': hex(r32(d,pos+0xD0)),
        'movieflag@0xBD': d[pos+0xBD], '0x90': d[pos+0x90:pos+0x94].hex(),
        '0xA4': d[pos+0xA4:pos+0xA8].hex(), '0xB0': d[pos+0xB0:pos+0xB4].hex(),
    }
    print(f"{'  '*depth}  {fields}")
    c = pos + hdr
    for _ in range(n):
        if d[c:c+4] != b'mhod': print(f"{'  '*depth}  !! expected mhod at 0x{c:X}, got {d[c:c+4]}"); break
        c += walk_mhod(d, c, depth+1)
    return total

def walk_mhip(d, pos, depth):
    hdr = r32(d, pos+4); total = r32(d, pos+8); nmhod = r32(d, pos+0xC)
    piid = r32(d, pos+0x14); tid = r32(d, pos+0x18)
    print(f"{'  '*depth}mhip @0x{pos:X} hdr=0x{hdr:X} total={total} nmhod={nmhod} item_id={piid} track_id={tid} dbid=0x{r64(d,pos+0x2C):X}")
    c = pos + hdr
    for _ in range(nmhod):
        if d[c:c+4] != b'mhod': break
        c += walk_mhod(d, c, depth+1)
    return total

def walk_mhyp(d, pos, depth):
    hdr = r32(d, pos+4); total = r32(d, pos+8)
    nmhod = r32(d, pos+12); nmhip = r32(d, pos+16); master = d[pos+20]
    ts = r32(d, pos+24); plid = r64(d, pos+28)
    print(f"{'  '*depth}mhyp @0x{pos:X} hdr=0x{hdr:X} total={total} nmhod={nmhod} nmhip={nmhip} master={master} plid=0x{plid:X}")
    c = pos + hdr
    for _ in range(nmhod):
        if d[c:c+4] != b'mhod': print(f"{'  '*depth}  !! expected mhod @0x{c:X} got {d[c:c+4]}"); break
        c += walk_mhod(d, c, depth+1)
    for _ in range(nmhip):
        if d[c:c+4] != b'mhip': print(f"{'  '*depth}  !! expected mhip @0x{c:X} got {d[c:c+4]}"); break
        c += walk_mhip(d, c, depth+1)
    return total

def walk_mhia(d, pos, depth):
    hdr = r32(d, pos+4); total = r32(d, pos+8); n = r32(d, pos+12)
    print(f"{'  '*depth}mhia @0x{pos:X} hdr=0x{hdr:X} total={total} nmhod={n}")
    c = pos + hdr
    for _ in range(n):
        if d[c:c+4] != b'mhod': break
        c += walk_mhod(d, c, depth+1)
    return total

def walk_list(d, pos, depth, child_walker, magic):
    hdr = r32(d, pos+4); count = r32(d, pos+8)
    kind = d[pos:pos+4].decode()
    print(f"{'  '*depth}{kind} @0x{pos:X} hdr=0x{hdr:X} count={count}")
    c = pos + hdr
    for i in range(count):
        if d[c:c+4] != magic:
            print(f"{'  '*depth}  !! expected {magic} @0x{c:X} got {d[c:c+4]}"); break
        c += child_walker(d, c, depth+1)
    return c

def main(path):
    d = open(path,'rb').read()
    assert d[:4] == b'mhbd'
    hdr = r32(d,4); total = r32(d,8)
    ver = r32(d,0x10); nsec = r32(d,0x14)
    print(f"mhbd hdr=0x{hdr:X} total={total} file={len(d)} version=0x{ver:X} num_mhsd={nsec}")
    print(f"  raw 0x20-0x30: {d[0x20:0x30].hex()}")
    pos = hdr
    for i in range(nsec):
        assert d[pos:pos+4] == b'mhsd', f"@0x{pos:X}"
        shdr = r32(d,pos+4); stotal = r32(d,pos+8); stype = r32(d,pos+12)
        child = d[pos+shdr:pos+shdr+4]
        print(f"\nmhsd[{i}] @0x{pos:X} type={stype} total={stotal} child={child}")
        cp = pos + shdr
        if child == b'mhlt':
            walk_list(d, cp, 1, walk_mhit, b'mhit')
        elif child == b'mhlp':
            walk_list(d, cp, 1, walk_mhyp, b'mhyp')
        elif child == b'mhla':
            walk_list(d, cp, 1, walk_mhia, b'mhia')
        else:
            print(f"  (unhandled child {child})")
        pos += stotal

if __name__ == '__main__':
    main(sys.argv[1])
