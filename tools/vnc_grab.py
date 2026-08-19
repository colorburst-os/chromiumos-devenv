#!/usr/bin/env python3
"""Minimal RFB 3.8 client: grab one raw framebuffer update, save as PNG.
Usage: vnc_grab.py host port out.png"""
import socket, struct, sys, zlib

host, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.create_connection((host, port), timeout=10)
f = s.makefile("rwb")

def rd(n):
    buf = b""
    while len(buf) < n:
        chunk = f.read(n - len(buf))
        if not chunk:
            raise RuntimeError("EOF")
        buf += chunk
    return buf

ver = rd(12)
f.write(b"RFB 003.008\n"); f.flush()
nsec = rd(1)[0]
secs = rd(nsec)
if 1 not in secs:
    raise RuntimeError(f"no None security offered: {list(secs)}")
f.write(bytes([1])); f.flush()
if struct.unpack(">I", rd(4))[0] != 0:
    raise RuntimeError("security failed")
f.write(bytes([1])); f.flush()  # ClientInit, shared
w, h = struct.unpack(">HH", rd(4))
pf = rd(16)
bpp, depth, big_endian, true_color = pf[0], pf[1], pf[2], pf[3]
rmax, gmax, bmax = struct.unpack(">HHH", pf[4:10])
rsh, gsh, bsh = pf[10], pf[11], pf[12]
namelen = struct.unpack(">I", rd(4))[0]
name = rd(namelen)
print(f"server: {name.decode()} {w}x{h} bpp={bpp} depth={depth} shifts={rsh},{gsh},{bsh}")

# SetEncodings: raw only
f.write(struct.pack(">BxH", 2, 1) + struct.pack(">i", 0)); f.flush()
# FramebufferUpdateRequest, non-incremental, full screen
f.write(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h)); f.flush()

fb = bytearray(w * h * 4)
if rd(1)[0] != 0:
    raise RuntimeError("expected FramebufferUpdate")
rd(1)
nrects = struct.unpack(">H", rd(2))[0]
Bpp = bpp // 8
for _ in range(nrects):
    x, y, rw, rh, enc = struct.unpack(">HHHHi", rd(12))
    if enc != 0:
        raise RuntimeError(f"unexpected encoding {enc}")
    data = rd(rw * rh * Bpp)
    for row in range(rh):
        for col in range(rw):
            off = (row * rw + col) * Bpp
            px = int.from_bytes(data[off:off + Bpp],
                                "big" if big_endian else "little")
            r = (px >> rsh & rmax) * 255 // rmax
            g = (px >> gsh & gmax) * 255 // gmax
            b = (px >> bsh & bmax) * 255 // bmax
            o = ((y + row) * w + (x + col)) * 4
            fb[o:o + 4] = bytes((r, g, b, 255))
s.close()

# stats: is it all black?
pixels = [fb[i] + fb[i + 1] + fb[i + 2] for i in range(0, len(fb), 4)]
nonblack = sum(1 for p in pixels if p > 30)
print(f"non-black pixels: {nonblack}/{len(pixels)} ({100*nonblack//len(pixels)}%)")

# write PNG manually (no PIL dependency)
def png_chunk(typ, data):
    c = typ + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

raw = b"".join(b"\x00" + bytes(fb[y * w * 4:(y + 1) * w * 4]) for y in range(h))
png = (b"\x89PNG\r\n\x1a\n"
       + png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
       + png_chunk(b"IDAT", zlib.compress(raw, 6))
       + png_chunk(b"IEND", b""))
open(out, "wb").write(png)
print(f"wrote {out}")
