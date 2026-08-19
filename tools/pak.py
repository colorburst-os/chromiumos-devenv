#!/usr/bin/env python3
"""Read/patch Chrome .pak (v5) files with the stdlib only.

  pak.py grep  <file.pak> <needle> [--utf16]     # which resource ids contain it
  pak.py dump  <file.pak> <id> [out]             # decompressed payload of one id
  pak.py info  <file.pak>
  pak.py sub   <in.pak> <out.pak> <find> <repl>  # replace in every entry (utf8+utf16)

Entries are gzip, brotli or raw; only gzip and raw are rewritable here
(brotli has no stdlib compressor). Round-trip is byte-identical.
"""
import gzip, struct, sys


WHOLE_GZIP = [False]


def load(p):
    d = open(p, 'rb').read()
    if d[:2] == b'\x1f\x8b':          # ChromeOS gzips whole locale paks
        WHOLE_GZIP[0] = True
        d = gzip.decompress(d)
    ver = struct.unpack_from('<I', d, 0)[0]
    assert ver == 5, f'pak v{ver} unsupported'
    enc = d[4]
    cnt, nal = struct.unpack_from('<HH', d, 8)
    e = [struct.unpack_from('<HI', d, 12 + i * 6) for i in range(cnt + 1)]
    al = [struct.unpack_from('<HH', d, 12 + (cnt + 1) * 6 + i * 4) for i in range(nal)]
    return enc, [(e[i][0], d[e[i][1]:e[i + 1][1]]) for i in range(cnt)], al


def save(p, enc, blobs, al):
    hdr = struct.pack('<IBBBBHH', 5, enc, 0, 0, 0, len(blobs), len(al))
    off = len(hdr) + (len(blobs) + 1) * 6 + len(al) * 4
    idx = b''
    for rid, b in blobs:
        idx += struct.pack('<HI', rid, off); off += len(b)
    idx += struct.pack('<HI', 0, off)
    out = (hdr + idx + b''.join(struct.pack('<HH', a, i) for a, i in al) +
           b''.join(b for _, b in blobs))
    if WHOLE_GZIP[0]:
        out = gzip.compress(out, 9)
    open(p, 'wb').write(out)


def kind(b):
    if b[:2] == b'\x1f\x8b':
        return 'gzip'
    # brotli-compressed pak entries carry a 0x1e 0x9b sentinel + 6-byte size
    if b[:2] == b'\x1e\x9b':
        return 'brotli'
    return 'raw'


def payload(b):
    return gzip.decompress(b) if kind(b) == 'gzip' else b


def main():
    cmd = sys.argv[1]
    if cmd == 'info':
        enc, blobs, al = load(sys.argv[2])
        from collections import Counter
        c = Counter(kind(b) for _, b in blobs)
        print(f'encoding={enc} resources={len(blobs)} aliases={len(al)} {dict(c)}')
    elif cmd == 'grep':
        u16 = '--utf16' in sys.argv
        needle = sys.argv[3]
        pats = [needle.encode()] + ([needle.encode('utf-16-le')] if u16 else [])
        _, blobs, _ = load(sys.argv[2])
        for rid, b in blobs:
            raw = payload(b)
            for pt in pats:
                if pt in raw:
                    i = raw.find(pt)
                    ctx = raw[max(0, i - 60):i + len(pt) + 60]
                    print(f'{rid}\t{kind(b)}\t{len(raw)}\t{ctx!r}')
                    break
    elif cmd == 'dump':
        _, blobs, _ = load(sys.argv[2])
        want = int(sys.argv[3])
        for rid, b in blobs:
            if rid == want:
                out = payload(b)
                if len(sys.argv) > 4:
                    open(sys.argv[4], 'wb').write(out)
                else:
                    sys.stdout.buffer.write(out)
    elif cmd == 'sub':
        src, dst, find, repl = sys.argv[2:6]
        enc, blobs, al = load(src)
        out, n = [], 0
        pairs = [(find.encode(), repl.encode()),
                 (find.encode('utf-16-le'), repl.encode('utf-16-le'))]
        for rid, b in blobs:
            k = kind(b)
            if k in ('gzip', 'raw'):
                raw = payload(b)
                new = raw
                for f, r in pairs:
                    new = new.replace(f, r)
                if new != raw:
                    n += 1
                    b = gzip.compress(new, 9) if k == 'gzip' else new
            out.append((rid, b))
        save(dst, enc, out, al)
        print(f'patched {n} resources -> {dst}')
    else:
        print(__doc__)


main()
