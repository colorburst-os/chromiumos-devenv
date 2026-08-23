#!/bin/bash
# Turn a built colorburst image into a language variant, without rebuilding it.
#
#   release/make-variant.sh <region> <image.bin> [output.bin]
#   release/make-variant.sh --show  <image.bin>
#
#   release/make-variant.sh vn colorburst-2026.32.11.bin colorburst-2026.32.11-vi.bin
#
# colorburst ships ONE build. The OOBE language, keyboard list and timezone all
# follow the region, and the region is a single line of text on the OEM
# partition (#8), read at boot by session_manager
# (login_manager/chrome_setup.cc, AddColorburstRegionFlag) and handed to Chrome
# as --cros-region.
#
# That partition is the whole trick. It is the only one that survives all three
# of the things that would otherwise wipe a variant:
#
#   install   -- chromeos-install copies it USB -> disk
#   OTA       -- update payloads carry KERN + ROOT only
#   powerwash -- clobber_state wipes STATE (#1)
#
# and it carries neither a dm-verity hash tree nor a signature, so writing to it
# does not invalidate anything: no rebuild, no re-sign, ~16 MiB touched. A
# device therefore keeps the personality of the stick it was installed from, for
# good, while every variant shares one OTA stream.
#
# An image with an untouched OEM partition is the English (region "us") build --
# that is the default in chrome_setup.cc -- so the en-US artifact ships exactly
# as built and only the other variants are repacked.
set -euo pipefail

VARIANT_DIR="colorburst"          # directory inside the OEM partition
VARIANT_FILE="variant"            # the file session_manager reads

usage() { sed -n '2,8p' "$0" | sed 's/^# \?//' >&2; exit 2; }

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
    lba, n, sz = struct.unpack("<Q", hdr[72:80])[0], \
                 struct.unpack("<I", hdr[80:84])[0], \
                 struct.unpack("<I", hdr[84:88])[0]
    f.seek(lba * 512)
    for _ in range(n):
        e = f.read(sz)
        first, last = struct.unpack("<QQ", e[32:48])
        name = e[56:128].decode("utf-16-le").rstrip("\x00")
        if name == want:
            print(first, last - first + 1)
            break
    else:
        sys.exit("no partition labelled %r in %s" % (want, img))
PYEOF
}

# --- read the image's own region database ------------------------------------
# The single best check available: the image knows which regions it supports, so
# a typo cannot ship. cros-regions.json lives on ROOT-A.
known_regions() {
    local img="$1" start count
    read -r start count < <(part_by_label "$img" ROOT-A)
    debugfs -R "cat /usr/share/misc/cros-regions.json" \
            "${img}?offset=$((start * 512))" 2>/dev/null |
        python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))'
}

[ $# -ge 2 ] || usage
command -v debugfs >/dev/null || { echo "debugfs not found (apt install e2fsprogs)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- --show: read the variant back out of an image ---------------------------
if [ "$1" = "--show" ]; then
    IMG="$2"
    read -r OEM_START OEM_COUNT < <(part_by_label "$IMG" OEM)
    if out=$(debugfs -R "cat /${VARIANT_DIR}/${VARIANT_FILE}" \
                     "${IMG}?offset=$((OEM_START * 512))" 2>/dev/null) &&
       [ -n "$out" ]; then
        echo "$out"
    else
        echo "# no variant marker -- this image is the default (region us)"
    fi
    exit 0
fi

REGION="$1"
SRC="$2"
DST="${3:-$SRC}"

[[ "$REGION" =~ ^[a-z0-9][a-z0-9.-]*$ && ${#REGION} -le 32 ]] ||
    { echo "bad region '$REGION': lowercase letters, digits, '.' and '-' only" >&2; exit 1; }
[ -f "$SRC" ] || { echo "no such image: $SRC" >&2; exit 1; }

# Refuse a region this image cannot serve. Without this the image boots and
# silently falls back to Chrome's own default, which looks like the variant
# plumbing is broken when in fact the region name was wrong.
if ! known_regions "$SRC" | grep -qx "$REGION"; then
    echo "region '$REGION' is not in this image's cros-regions.json." >&2
    echo "Known regions: $(known_regions "$SRC" | tr '\n' ' ')" >&2
    exit 1
fi

if [ "$DST" != "$SRC" ]; then
    echo ">>> copying $SRC -> $DST"
    cp --reflink=auto "$SRC" "$DST"
fi

read -r OEM_START OEM_COUNT < <(part_by_label "$DST" OEM)
echo ">>> OEM partition: start=$OEM_START sectors=$OEM_COUNT ($((OEM_COUNT / 2048)) MiB)"

# Work on the partition alone rather than on the whole multi-GB image: the write
# is 16 MiB, and a bad offset can only damage a scratch file.
dd if="$DST" of="$TMP/oem.img" bs=512 skip="$OEM_START" count="$OEM_COUNT" status=none

python3 - "$TMP/oem.img" <<'PYEOF'
import struct, sys
with open(sys.argv[1], "rb") as f:
    f.seek(1024 + 56)
    if struct.unpack("<H", f.read(2))[0] != 0xEF53:
        sys.exit("the OEM partition has no ext filesystem -- wrong image?")
PYEOF

printf '# colorburst variant marker -- read by session_manager at boot.\n' \
       > "$TMP/$VARIANT_FILE"
printf '# Survives install, OTA and powerwash: see release/make-variant.sh.\n' \
       >> "$TMP/$VARIANT_FILE"
printf 'region=%s\n' "$REGION" >> "$TMP/$VARIANT_FILE"

# Idempotent: re-running with another region replaces the marker rather than
# failing on an existing file.
debugfs -w -f - "$TMP/oem.img" >/dev/null 2>&1 <<EOF || true
rm /${VARIANT_DIR}/${VARIANT_FILE}
EOF
debugfs -w -f - "$TMP/oem.img" >/dev/null 2>&1 <<EOF || true
mkdir /${VARIANT_DIR}
EOF
debugfs -w -f - "$TMP/oem.img" >"$TMP/debugfs.log" 2>&1 <<EOF
cd /${VARIANT_DIR}
write $TMP/$VARIANT_FILE ${VARIANT_FILE}
set_inode_field /${VARIANT_DIR} mode 040755
set_inode_field /${VARIANT_DIR}/${VARIANT_FILE} mode 0100644
EOF

# --- verify before writing back ----------------------------------------------
got=$(debugfs -R "cat /${VARIANT_DIR}/${VARIANT_FILE}" "$TMP/oem.img" 2>/dev/null |
      sed -n 's/^region=//p')
[ "$got" = "$REGION" ] || {
    echo "verification failed: marker reads '$got', expected '$REGION'" >&2
    cat "$TMP/debugfs.log" >&2
    exit 1
}
e2fsck -fn "$TMP/oem.img" >"$TMP/fsck.log" 2>&1 || {
    echo "the rewritten OEM filesystem does not fsck clean -- refusing to ship it" >&2
    cat "$TMP/fsck.log" >&2
    exit 1
}

dd if="$TMP/oem.img" of="$DST" bs=512 seek="$OEM_START" conv=notrunc status=none

# --- verify again, in place ---------------------------------------------------
final=$(debugfs -R "cat /${VARIANT_DIR}/${VARIANT_FILE}" \
                "${DST}?offset=$((OEM_START * 512))" 2>/dev/null |
        sed -n 's/^region=//p')
[ "$final" = "$REGION" ] || {
    echo "wrote the partition but the image does not read it back -- STOP" >&2
    exit 1
}

echo ">>> $DST is now region '$REGION'"
echo "    everything outside the OEM partition is byte-identical to $SRC:"
echo "    same kernel, same rootfs, same verity hash, same OTA payload."
