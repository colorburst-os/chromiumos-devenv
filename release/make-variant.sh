#!/bin/bash
# Turn a built colorburst image into a variant, without rebuilding it.
#
#   release/make-variant.sh <region> <image.bin> [output.bin]
#   release/make-variant.sh --show  <image.bin>
#   release/make-variant.sh --file <config.txt> <image.bin> [output.bin]
#
#   release/make-variant.sh vn colorburst-2026.32.11.bin colorburst-2026.32.11-vi.bin
#
# colorburst ships ONE build. How a device behaves -- today its language, in
# time more than that -- is a plain-text file on the OEM partition (#8), read at
# boot by session_manager (login_manager/colorburst_config.cc).
#
# That partition is the whole trick. It is the only one that survives all three
# of the things that would otherwise wipe a variant:
#
#   install   -- chromeos-install copies it USB -> disk
#   OTA       -- update payloads carry KERN + ROOT only
#   powerwash -- clobber_state wipes STATE (#1)
#
# and it carries neither a dm-verity hash tree nor a signature, so writing to it
# does not invalidate anything: no rebuild, no re-sign, a few hundred bytes
# touched. A device therefore keeps the personality of the stick it was
# installed from, for good, while every variant shares one OTA stream.
#
# The partition is FAT32 and this script also stamps it with the Microsoft
# basic-data type GUID, which together are what make it visible in Windows
# Explorer: someone preparing a stick can open colorburst.txt in Notepad and
# change the language without booting anything. See the note on --show below
# for what that does and does not extend to.
#
# Run this for EVERY shipped image, including the English one -- an explicit
# config beats an implicit default, and the type GUID has to be stamped either
# way.
set -euo pipefail

CONFIG_NAME="colorburst.txt"       # at the root of the OEM partition
# Microsoft basic data. Windows assigns a drive letter to this type and to no
# other; the stock ChromeOS "data" type is Linux filesystem data
# (0FC63DAF-...), which Explorer will not show however it is formatted.
BASIC_DATA_GUID="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

usage() { sed -n '2,9p' "$0" | sed 's/^# \?//' >&2; exit 2; }
die() { echo "error: $*" >&2; exit 1; }

# --- locate a GPT partition by label -----------------------------------------
# Prints "<start_sector> <sector_count>".
part_by_label() {
    python3 - "$1" "$2" <<'PYEOF'
import struct, sys
img, want = sys.argv[1], sys.argv[2]
with open(img, "rb") as f:
    f.seek(512)
    hdr = f.read(92)
    if hdr[:8] != b"EFI PART":
        sys.exit("not a GPT image: " + img)
    lba = struct.unpack("<Q", hdr[72:80])[0]
    n = struct.unpack("<I", hdr[80:84])[0]
    sz = struct.unpack("<I", hdr[84:88])[0]
    f.seek(lba * 512)
    for _ in range(n):
        e = f.read(sz)
        first, last = struct.unpack("<QQ", e[32:48])
        if e[56:128].decode("utf-16-le").rstrip("\x00") == want:
            print(first, last - first + 1)
            break
    else:
        sys.exit("no partition labelled %r in %s" % (want, img))
PYEOF
}

# --- set a partition's type GUID, in place -----------------------------------
# Rewrites 16 bytes in the primary and backup partition-entry arrays and fixes
# the four checksums that cover them. Deliberately not `sfdisk --part-type`:
# sfdisk rewrites the whole table, and on these images it "corrects" the PMBR
# size and relocates the backup GPT, neither of which we want.
set_part_type() {
    python3 - "$1" "$2" "$3" <<'PYEOF'
import binascii, struct, sys, uuid
img, num, want = sys.argv[1], int(sys.argv[2]), uuid.UUID(sys.argv[3])

def header(f, lba):
    f.seek(lba * 512)
    h = bytearray(f.read(512))
    if h[:8] != b"EFI PART":
        sys.exit("no GPT header at LBA %d" % lba)
    return h

with open(img, "r+b") as f:
    primary = header(f, 1)
    alt_lba = struct.unpack("<Q", primary[32:40])[0]
    headers = [(1, primary), (alt_lba, header(f, alt_lba))]

    for lba, h in headers:
        hsize = struct.unpack("<I", h[12:16])[0]
        entries_lba = struct.unpack("<Q", h[72:80])[0]
        count = struct.unpack("<I", h[80:84])[0]
        esize = struct.unpack("<I", h[84:88])[0]
        if not 1 <= num <= count:
            sys.exit("no partition %d" % num)

        f.seek(entries_lba * 512)
        entries = bytearray(f.read(count * esize))
        off = (num - 1) * esize
        entries[off:off + 16] = want.bytes_le

        f.seek(entries_lba * 512)
        f.write(entries)

        # Entry-array CRC, then the header CRC over the zeroed-CRC header.
        struct.pack_into("<I", h, 88, binascii.crc32(bytes(entries)) & 0xFFFFFFFF)
        struct.pack_into("<I", h, 16, 0)
        struct.pack_into("<I", h, 16,
                         binascii.crc32(bytes(h[:hsize])) & 0xFFFFFFFF)
        f.seek(lba * 512)
        f.write(bytes(h))
print("type of partition %d set to %s" % (num, want))
PYEOF
}

# Prints the type GUID of partition <num>.
get_part_type() {
    python3 - "$1" "$2" <<'PYEOF'
import struct, sys, uuid
with open(sys.argv[1], "rb") as f:
    f.seek(512)
    h = f.read(92)
    lba = struct.unpack("<Q", h[72:80])[0]
    esize = struct.unpack("<I", h[84:88])[0]
    f.seek(lba * 512 + (int(sys.argv[2]) - 1) * esize)
    print(str(uuid.UUID(bytes_le=f.read(16))).upper())
PYEOF
}

# --- the image's own region database ------------------------------------------
# The best check available: the image knows which regions it supports, so a typo
# cannot ship.
known_regions() {
    local img="$1" start count
    read -r start count < <(part_by_label "$img" ROOT-A)
    debugfs -R "cat /usr/share/misc/cros-regions.json" \
            "${img}?offset=$((start * 512))" 2>/dev/null |
        python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))'
}

[ $# -ge 2 ] || usage
for t in debugfs mcopy mdir python3; do
    command -v "$t" >/dev/null || die "$t not found (apt install e2fsprogs mtools)"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extracts the OEM partition of $1 into $TMP/oem.img, setting OEM_START/COUNT.
extract_oem() {
    read -r OEM_START OEM_COUNT < <(part_by_label "$1" OEM)
    dd if="$1" of="$TMP/oem.img" bs=512 skip="$OEM_START" count="$OEM_COUNT" \
       status=none
    python3 - "$TMP/oem.img" <<'PYEOF'
import sys
with open(sys.argv[1], "rb") as f:
    boot = f.read(512)
    f.seek(1024 + 56)
    ext = f.read(2)
if ext == b"\x53\xef":
    sys.exit("the OEM partition is ext4. This image predates the FAT OEM "
             "partition -- rebuild it, or use an older make-variant.sh.")
if boot[510:512] != b"\x55\xaa":
    sys.exit("the OEM partition has no FAT filesystem -- wrong image?")
PYEOF
}

# --- --show -------------------------------------------------------------------
if [ "$1" = "--show" ]; then
    IMG="$2"
    extract_oem "$IMG"
    echo "--- $CONFIG_NAME"
    mcopy -i "$TMP/oem.img" "::${CONFIG_NAME}" - 2>/dev/null ||
        echo "(absent -- this image runs on defaults: region us)"
    echo "--- partition 8"
    t=$(get_part_type "$IMG" 8)
    if [ "$t" = "$BASIC_DATA_GUID" ]; then
        echo "type $t (Microsoft basic data -- visible in Windows Explorer)"
    else
        echo "type $t (NOT basic data -- Windows will not show this partition)"
    fi
    exit 0
fi

# --- argument handling --------------------------------------------------------
if [ "$1" = "--file" ]; then
    [ $# -ge 3 ] || usage
    SRC_CONFIG="$2"; SRC="$3"; DST="${4:-$3}"
    [ -f "$SRC_CONFIG" ] || die "no such config file: $SRC_CONFIG"
    REGION=$(sed -e 's/[;#].*//' -e 's/[[:space:]]//g' "$SRC_CONFIG" |
             sed -n 's/^[Rr][Ee][Gg][Ii][Oo][Nn]=//p' | head -1 |
             tr -d '"'"'" | tr 'A-Z' 'a-z')
    [ -n "$REGION" ] || die "$SRC_CONFIG sets no region="
else
    REGION="$1"; SRC="$2"; DST="${3:-$2}"
    SRC_CONFIG=""
fi

[[ "$REGION" =~ ^[a-z0-9][a-z0-9.-]*$ && ${#REGION} -le 32 ]] ||
    die "bad region '$REGION': lowercase letters, digits, '.' and '-' only"
[ -f "$SRC" ] || die "no such image: $SRC"

# Refuse a region this image cannot serve. Without this the device boots and
# quietly falls back to English, which looks like the variant plumbing is broken
# when in fact the region name was wrong.
if ! known_regions "$SRC" | grep -qx "$REGION"; then
    echo "region '$REGION' is not in this image's cros-regions.json." >&2
    echo "Known regions: $(known_regions "$SRC" | tr '\n' ' ')" >&2
    exit 1
fi

if [ "$DST" != "$SRC" ]; then
    echo ">>> copying $SRC -> $DST"
    cp --reflink=auto "$SRC" "$DST"
fi

extract_oem "$DST"
echo ">>> OEM partition: start=$OEM_START sectors=$OEM_COUNT ($((OEM_COUNT / 2048)) MiB)"

# --- the config ---------------------------------------------------------------
# CRLF, because this file exists to be opened in Notepad. Older Notepad shows a
# LF-only file as one run-on line.
if [ -n "$SRC_CONFIG" ]; then
    sed 's/\r*$/\r/' "$SRC_CONFIG" > "$TMP/$CONFIG_NAME"
else
    sed 's/$/\r/' > "$TMP/$CONFIG_NAME" <<EOF
# colorburst configuration
#
# This file decides how this computer behaves. It is read once at every boot,
# and it survives updates and a full reset -- so whatever you set here is what
# this machine stays.
#
# region: the language, keyboard and clock the computer starts with.
#         "us" = English, "vn" = Tiếng Việt.
#         The user can still change the language afterwards; this is only what
#         a fresh or freshly-reset machine starts as.

region=$REGION
EOF
fi

mdel -i "$TMP/oem.img" "::${CONFIG_NAME}" 2>/dev/null || true
mcopy -i "$TMP/oem.img" "$TMP/$CONFIG_NAME" "::${CONFIG_NAME}"

# --- verify the filesystem before putting it back -----------------------------
got=$(mcopy -i "$TMP/oem.img" "::${CONFIG_NAME}" - 2>/dev/null |
      tr -d '\r' | sed -n 's/^[Rr]egion=//p' | head -1)
[ "$got" = "$REGION" ] ||
    die "verification failed: the config reads region '$got', expected '$REGION'"
fsck.vfat -n "$TMP/oem.img" >"$TMP/fsck.log" 2>&1 ||
    { cat "$TMP/fsck.log" >&2
      die "the rewritten OEM filesystem does not fsck clean -- refusing to ship it"; }

dd if="$TMP/oem.img" of="$DST" bs=512 seek="$OEM_START" conv=notrunc status=none

# --- make it visible to Windows ----------------------------------------------
if [ "$(get_part_type "$DST" 8)" != "$BASIC_DATA_GUID" ]; then
    echo ">>> stamping partition 8 as Microsoft basic data (for Windows)"
    set_part_type "$DST" 8 "$BASIC_DATA_GUID"
fi
sfdisk -J "$DST" >/dev/null 2>&1 ||
    die "the partition table no longer parses after the type change -- STOP"

# --- verify again, in place ---------------------------------------------------
extract_oem "$DST"
final=$(mcopy -i "$TMP/oem.img" "::${CONFIG_NAME}" - 2>/dev/null |
        tr -d '\r' | sed -n 's/^[Rr]egion=//p' | head -1)
[ "$final" = "$REGION" ] ||
    die "wrote the partition but the image does not read it back -- STOP"
[ "$(get_part_type "$DST" 8)" = "$BASIC_DATA_GUID" ] ||
    die "the partition type did not take -- STOP"

echo ">>> $DST is now region '$REGION'"
echo "    Everything outside the OEM partition is byte-identical to the input:"
echo "    same kernel, same rootfs, same verity hash, same OTA payload."
