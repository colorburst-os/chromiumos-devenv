#!/bin/bash
# Turn a built colorburst image into a language variant, without rebuilding it.
#
#   release/make-variant.sh <region> <image.bin> [output.bin]
#   release/make-variant.sh --show  <image.bin>
#   release/make-variant.sh --file <manifest.json> <image.bin> [output.bin]
#
#   release/make-variant.sh vn colorburst-2026.32.11.bin colorburst-2026.32.11-vi.bin
#
# colorburst ships ONE build. A variant is a single file on the OEM partition,
# and that file is ChromeOS's own OEM customization manifest -- not a colorburst
# invention:
#
#   /opt/oem/etc/startup_manifest.json   (ash/constants/ash_paths.cc)
#
# read by StartupCustomizationDocument, carrying initial_locale,
# initial_timezone and keyboard_layout. The BSP symlinks /opt/oem to
# /usr/share/oem, where the OEM partition mounts.
#
# The OEM partition is the whole trick. It is the only one that survives all
# three of the things that would otherwise wipe a variant:
#
#   install   -- chromeos-install copies it USB -> disk
#   OTA       -- update payloads carry KERN + ROOT only
#   powerwash -- clobber_state wipes STATE (#1)
#
# and it carries neither a dm-verity hash tree nor a signature, so writing to it
# does not invalidate anything: no rebuild, no re-sign, a few hundred bytes
# touched. A device keeps the personality of the stick it was installed from,
# while every variant shares one OTA payload.
#
# It is FAT32 stamped as Microsoft basic data, so a written USB stick shows the
# partition in Windows Explorer -- someone preparing a machine for a relative
# can look at, and if need be replace, the manifest without booting Linux.
#
# WHY A REGION NAME, WHEN THE MANIFEST HAS NO REGION FIELD
# -------------------------------------------------------
# The region is a lookup key here, at repack time -- not a mechanism on the
# device. cros-regions.json inside the image already knows, for every region,
# the right locale, timezone and hardware keyboard list; this script reads them
# out of THAT image and writes them into the manifest. So "vn" stays the one
# word a human has to know, and the device still ends up configured exactly the
# way ChromeOS configures a Vietnamese device -- but through the upstream file,
# with no --cros-region anywhere and no colorburst-specific parser on the
# device.
#
# Run this for EVERY shipped image, English included: an explicit manifest beats
# an implicit default, and the partition type has to be stamped either way.
set -euo pipefail

CONFIG_DIR="etc"                       # inside the OEM partition
CONFIG_NAME="startup_manifest.json"
# Microsoft basic data. Windows assigns a drive letter to this type and to no
# other; the stock ChromeOS "data" type is Linux filesystem data
# (0FC63DAF-...), which Explorer will not show however it is formatted.
BASIC_DATA_GUID="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

usage() { sed -n '2,7p' "$0" | sed 's/^# \?//' >&2; exit 2; }
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
    for lba, h in [(1, primary), (alt_lba, header(f, alt_lba))]:
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
        struct.pack_into("<I", h, 88, binascii.crc32(bytes(entries)) & 0xFFFFFFFF)
        struct.pack_into("<I", h, 16, 0)
        struct.pack_into("<I", h, 16, binascii.crc32(bytes(h[:hsize])) & 0xFFFFFFFF)
        f.seek(lba * 512)
        f.write(bytes(h))
print("type of partition %d set to %s" % (num, want))
PYEOF
}

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
# Read straight out of the image being repacked, so a variant can never be
# configured with a region, locale or input method that this build does not
# actually ship.
regions_json() {
    local img="$1" start count
    read -r start count < <(part_by_label "$img" ROOT-A)
    debugfs -R "cat /usr/share/misc/cros-regions.json" \
            "${img}?offset=$((start * 512))" 2>/dev/null
}

[ $# -ge 2 ] || usage
for t in debugfs mcopy mmd mdir python3; do
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
             "partition -- rebuild it.")
if boot[510:512] != b"\x55\xaa":
    sys.exit("the OEM partition has no FAT filesystem -- wrong image?")
PYEOF
}

# --- --show -------------------------------------------------------------------
if [ "$1" = "--show" ]; then
    IMG="$2"
    extract_oem "$IMG"
    echo "--- ${CONFIG_DIR}/${CONFIG_NAME}"
    mcopy -i "$TMP/oem.img" "::${CONFIG_DIR}/${CONFIG_NAME}" - 2>/dev/null ||
        echo "(absent -- this image runs on Chrome's own defaults: en-US)"
    echo "--- partition 8"
    t=$(get_part_type "$IMG" 8)
    if [ "$t" = "$BASIC_DATA_GUID" ]; then
        echo "type $t (Microsoft basic data -- visible in Windows Explorer)"
    else
        echo "type $t (NOT basic data -- Windows will not show this partition)"
    fi
    exit 0
fi

# --- arguments ----------------------------------------------------------------
SRC_MANIFEST=""
if [ "$1" = "--file" ]; then
    [ $# -ge 3 ] || usage
    SRC_MANIFEST="$2"; SRC="$3"; DST="${4:-$3}"
    [ -f "$SRC_MANIFEST" ] || die "no such manifest: $SRC_MANIFEST"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SRC_MANIFEST" ||
        die "$SRC_MANIFEST is not valid JSON"
    REGION="(from $SRC_MANIFEST)"
else
    REGION="$1"; SRC="$2"; DST="${3:-$2}"
    [[ "$REGION" =~ ^[a-z0-9][a-z0-9.-]*$ && ${#REGION} -le 32 ]] ||
        die "bad region '$REGION': lowercase letters, digits, '.' and '-' only"
fi
[ -f "$SRC" ] || die "no such image: $SRC"

# --- derive the manifest from the image's region database ---------------------
if [ -z "$SRC_MANIFEST" ]; then
    regions_json "$SRC" > "$TMP/regions.json"
    [ -s "$TMP/regions.json" ] || die "could not read cros-regions.json from $SRC"
    python3 - "$TMP/regions.json" "$REGION" > "$TMP/$CONFIG_NAME" <<'PYEOF'
import json, sys
db = json.load(open(sys.argv[1]))
region = sys.argv[2]
if region not in db:
    sys.exit("region %r is not in this image's cros-regions.json.\n"
             "Known regions: %s" % (region, " ".join(sorted(db))))
r = db[region]
# initial_locale and keyboard_layout are comma-separated lists upstream:
# StartupCustomizationDocument splits the locales, and
# InputMethodUtil::UpdateHardwareLayoutCache splits the keyboards. Passing the
# whole list keeps the OOBE language and keyboard pickers exactly as a region
# would have set them.
manifest = {
    "version": "1.0",
    "initial_locale": ",".join(r["locales"]),
    "initial_timezone": r["time_zones"][0],
    "keyboard_layout": ",".join(r["keyboards"]),
}
json.dump(manifest, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
PYEOF
else
    cp "$SRC_MANIFEST" "$TMP/$CONFIG_NAME"
fi

echo ">>> manifest for '$REGION':"
sed 's/^/    /' "$TMP/$CONFIG_NAME"

if [ "$DST" != "$SRC" ]; then
    echo ">>> copying $SRC -> $DST"
    cp --reflink=auto "$SRC" "$DST"
fi

extract_oem "$DST"
echo ">>> OEM partition: start=$OEM_START sectors=$OEM_COUNT ($((OEM_COUNT / 2048)) MiB)"

# Idempotent: re-running with another region replaces the manifest.
mmd  -i "$TMP/oem.img" "::${CONFIG_DIR}" 2>/dev/null || true
mdel -i "$TMP/oem.img" "::${CONFIG_DIR}/${CONFIG_NAME}" 2>/dev/null || true
mcopy -i "$TMP/oem.img" "$TMP/$CONFIG_NAME" "::${CONFIG_DIR}/${CONFIG_NAME}"

# --- verify before writing back -----------------------------------------------
mcopy -i "$TMP/oem.img" "::${CONFIG_DIR}/${CONFIG_NAME}" - 2>/dev/null \
    > "$TMP/readback.json" || die "cannot read the manifest back out of the image"
cmp -s "$TMP/$CONFIG_NAME" "$TMP/readback.json" ||
    die "the manifest read back differs from what was written"
fsck.vfat -n "$TMP/oem.img" > "$TMP/fsck.log" 2>&1 ||
    { cat "$TMP/fsck.log" >&2
      die "the rewritten OEM filesystem does not fsck clean -- refusing to ship it"; }

dd if="$TMP/oem.img" of="$DST" bs=512 seek="$OEM_START" conv=notrunc status=none

# --- make it visible to Windows -----------------------------------------------
if [ "$(get_part_type "$DST" 8)" != "$BASIC_DATA_GUID" ]; then
    echo ">>> stamping partition 8 as Microsoft basic data (for Windows)"
    set_part_type "$DST" 8 "$BASIC_DATA_GUID"
fi
sfdisk -J "$DST" >/dev/null 2>&1 ||
    die "the partition table no longer parses after the type change -- STOP"

# --- verify again, in place ----------------------------------------------------
extract_oem "$DST"
mcopy -i "$TMP/oem.img" "::${CONFIG_DIR}/${CONFIG_NAME}" - 2>/dev/null \
    > "$TMP/final.json" || die "wrote the partition but the image will not read it back"
cmp -s "$TMP/$CONFIG_NAME" "$TMP/final.json" ||
    die "wrote the partition but the image reads back something else -- STOP"
[ "$(get_part_type "$DST" 8)" = "$BASIC_DATA_GUID" ] ||
    die "the partition type did not take -- STOP"

echo ">>> $DST carries the '$REGION' manifest"
echo "    Everything outside the OEM partition is byte-identical to the input:"
echo "    same kernel, same rootfs, same verity hash, same OTA payload."
