#!/usr/bin/env bash
# Boot the Chromium OS image under crosvm (ChromeOS's own VMM) with a
# virgl GPU-accelerated display window, input, and networking.
#
#   ./run-crosvm.sh [path-to-image.bin]
#   CROS_DISPLAY=3840x2160 ./run-crosvm.sh    # custom window size
#   CROS_VM_ID=2 ./run-crosvm.sh              # second instance, ports +2
#
# Instances: several VMs can run at once. Each gets its own workspace under
# chromiumos/.vm/<id>/ holding a qcow2 overlay and its console log, and its
# own host ports (SSH 9222+id, VNC 5900+id). Allocate ids with
# tools/vm-instance.sh rather than by hand.
#
# The base image is never written to: each instance boots a copy-on-write
# qcow2 overlay backed by it. Wiping an instance therefore resets it to a
# pristine image, and two instances cannot corrupt each other.
#
# Networking: a TAP device inside the container with dnsmasq (DHCP+DNS) and
# NAT. The guest NIC has a pinned MAC so it always gets 192.168.77.2, and
# container port 2222 is DNAT'd to guest SSH. Each instance has its own
# network namespace, so the TAP name and guest IP are the same in all of
# them; only the published host port differs:
#   ssh -p $((9222+id)) root@localhost   (password: test0000)
#
# Notes:
#  - crosvm binary: built from src/platform/crosvm (with local patches for
#    window decorations and display scaling) into chromiumos/.cache/crosvm-target.
#  - Direct-kernel boot (vmlinuz + root=/dev/vda3), bypassing dm-verity.
#  - Serial console: chromiumos/.vm/<id>/console.log (earlyprintk required,
#    else this kernel is silent on ttyS0).
#  - Close the window or Ctrl-C to stop the VM. crosvm also exits when the
#    guest reboots.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ID="${CROS_VM_ID:-0}"
case "$ID" in
    ''|*[!0-9]*) echo "error: CROS_VM_ID must be a number, got '$ID'" >&2; exit 1 ;;
esac

# Resolve the image through the `latest` symlink: instances record the base
# path inside their overlay, and a later build-image moves that symlink.
# Image precedence: explicit argument, then CROS_VM_IMAGE (how vm-instance.sh
# callers pick a board), then the colorburst default (the live board;
# amd64-generic is retired).
HOST_IMG="$(readlink -f "${1:-${CROS_VM_IMAGE:-$DIR/chromiumos/src/build/images/colorburst/latest/chromiumos_test_image.bin}}")"
if [ ! -f "$HOST_IMG" ]; then
    echo "error: image not found: $HOST_IMG" >&2
    exit 1
fi
REL="${HOST_IMG#"$DIR/chromiumos/"}"
IMG="/home/cros/chromiumos/$REL"
# CROS_VM_KERNEL overrides the boot kernel (host path under chromiumos/).
# Direct-kernel boot always uses a host-side vmlinuz, not the KERN-A/B
# partitions; after an OTA has switched slots, pass the vmlinuz from the
# UPDATED build here so the kernel matches the new rootfs's modules.
if [ -n "${CROS_VM_KERNEL:-}" ]; then
    KERN_HOST="$(readlink -f "$CROS_VM_KERNEL")"
    [ -f "$KERN_HOST" ] || { echo "error: kernel not found: $KERN_HOST" >&2; exit 1; }
    KERN="/home/cros/chromiumos/${KERN_HOST#"$DIR/chromiumos/"}"
else
    KERN="/home/cros/chromiumos/${REL%/*}/boot_images/vmlinuz"
fi

# Per-instance workspace (host side; also bind-mounted, so same path inside).
WORK_HOST="$DIR/chromiumos/.vm/$ID"
WORK="/home/cros/chromiumos/.vm/$ID"
mkdir -p "$WORK_HOST"
DISK="$WORK/disk.qcow2"
CONSOLE="$WORK/console.log"

SSH_PORT=$((9222 + ID))
VNC_PORT=$((5900 + ID))

# CROS_DISPLAY = guest framebuffer resolution (physical pixels).
# CROS_SCALE   = guest pixels per desktop point. On a HiDPI desktop running
#                at 200% (4K at 1920x1080 points), scale 2 means each guest
#                pixel maps to exactly one physical pixel; scale 1 would
#                blow every guest pixel up to 2x2 physical pixels.
# Defaults: full-4K framebuffer, pixel-perfect on a 200% desktop.
#   Window size in points = (W/SCALE) x (H/SCALE); make sure that fits your
#   desktop's logical resolution.
SIZE="${CROS_DISPLAY:-3840x2160}"
W="${SIZE%%x*}"
H="${SIZE##*x}"
SCALE="${CROS_SCALE:-2}"

# 8 GB is what a single VM wants: with less, the guest silently OOM-kills
# Chrome in a loop. Running several at once needs this lowered -- this host
# has ~30 GB total. tools/vm-instance.sh picks a value based on how many
# instances are live.
MEM="${CROS_VM_MEM:-8192}"
CPUS="${CROS_VM_CPUS:-8}"

# --- OPTIONAL SECOND DISK (installer target) -------------------------------
# CROS_VM_DISK2=<path>  attaches a second raw/qcow2 block device as /dev/vdb.
#   Path may be absolute on the host under chromiumos/, or a bare name, in
#   which case it lives in this instance's workspace.
# CROS_VM_DISK2_SIZE=<n>G  creates it as a sparse raw file if missing.
# CROS_VM_BOOT_DISK2=1  boots from /dev/vdb3 instead of /dev/vda3 (i.e. boots
#   the system you just installed onto the second disk).
# Unset -> behaviour is exactly as before (single --block, root=/dev/vda3).
#
# The kernel cmdline also carries `cros_efi` (what grub/syslinux put there on a
# real EFI boot, create_legacy_bootloader_templates.sh:159). Without a
# `cros_XXX` token, `chromeos-install`'s postinst step aborts with
# "No recognized cros_XXX bios option on kernel command line"
# (installer/chromeos_postinst.cc:155).
DISK2_ARG=""
ROOTDEV="/dev/vda3"

# CROS_VM_SCSI presents the disk over virtio-scsi instead of virtio-blk.
# The reven-based kernel (6.12, colorburst board) builds virtio_blk as a
# module but virtio-scsi in (CONFIG_SCSI_VIRTIO=y), and we boot noinitrd, so
# on that image a --block root disk hangs at "Waiting for root device
# /dev/vda3". SCSI disks appear as /dev/sda instead of /dev/vda.
#
# It therefore defaults to ON: the live board is colorburst, which REQUIRES it.
# Set CROS_VM_SCSI=0 explicitly to boot an old amd64-generic (virtio_blk) image.
BLOCK_FLAG="--block"
if [ "${CROS_VM_SCSI:-1}" = 1 ]; then
    BLOCK_FLAG="--scsi-block"
    ROOTDEV="/dev/sda3"
fi

# The rootfs is mounted read-only, as on a real device. It is ext2 with no
# journal, so a VM that is killed while root is mounted rw comes back with a
# damaged filesystem -- the symptom is `ui` respawning forever and never
# reaching a screen, which reads as a hang. Set CROS_VM_ROOTFS_RW=1 if you
# genuinely need to write to the rootfs; remember to `sync` before stopping.
ROOTFLAG="ro"
[ "${CROS_VM_ROOTFS_RW:-0}" = 1 ] && ROOTFLAG="rw"
if [ -n "${CROS_VM_DISK2:-}" ]; then
    case "$CROS_VM_DISK2" in
        /*) D2_HOST="$CROS_VM_DISK2" ;;
        *)  D2_HOST="$WORK_HOST/$CROS_VM_DISK2" ;;
    esac
    if [ ! -e "$D2_HOST" ]; then
        truncate -s "${CROS_VM_DISK2_SIZE:-16G}" "$D2_HOST"
        echo ">>> created second disk $D2_HOST (${CROS_VM_DISK2_SIZE:-16G}, sparse)"
    fi
    D2_REL="${D2_HOST#"$DIR/chromiumos/"}"
    # The second disk follows the primary's transport: on the colorburst
    # kernel virtio_blk is a module (see CROS_VM_SCSI above), so a --block
    # second disk could never be the boot root, and mixing transports just
    # confuses device naming. SCSI: sda/sdb; blk: vda/vdb.
    D2_DEV="/dev/vdb" && [ "${CROS_VM_SCSI:-1}" = 1 ] && D2_DEV="/dev/sdb"
    DISK2_ARG="$BLOCK_FLAG path=/home/cros/chromiumos/$D2_REL,ro=false"
    echo ">>> second disk: $D2_HOST -> guest $D2_DEV"
    # CROS_VM_ROOT_PART picks the rootfs partition on the boot disk
    # (default 3 = ROOT-A; 5 = ROOT-B, e.g. after an OTA switched slots).
    [ "${CROS_VM_BOOT_DISK2:-0}" = 1 ] && \
        ROOTDEV="${D2_DEV}${CROS_VM_ROOT_PART:-3}" && \
        echo ">>> booting from the SECOND disk (root=$ROOTDEV)"
fi

# CROS_VM_OFFICIAL=1 drops cros_debug from the kernel command line.
# crossystem debug_build is literally "is cros_debug on the cmdline", and
# update_engine's IsOfficialBuild() is "debug_build == 0": without
# cros_debug the guest runs update_engine in official mode (periodic
# checks on, payload signature verification mandatory against
# /usr/share/update_engine/update-payload-key.pub.pem). Used by
# release/verify-vm-update.sh with a build-ota-test-image.sh image.
CROS_DEBUG_FLAG="cros_debug"
[ "${CROS_VM_OFFICIAL:-0}" = 1 ] && CROS_DEBUG_FLAG="" && \
    echo ">>> OFFICIAL boot: no cros_debug on the kernel cmdline (debug_build=0)"

echo ">>> Instance $ID: booting $HOST_IMG under crosvm (virgl, ${W}x${H}, ${MEM}MB)"
echo ">>> SSH: ssh -p $SSH_PORT root@localhost (password: test0000)"
echo ">>> Serial console: chromiumos/.vm/$ID/console.log"
echo ">>> Overlay disk: chromiumos/.vm/$ID/disk.qcow2 (base image is not modified)"

exec env CROS_IMAGE=cros-crosvm GUI=1 PUBLISH_PORTS=1 \
    VM_SSH_PORT="$SSH_PORT" VM_VNC_PORT="$VNC_PORT" \
    CONTAINER_NAME="cros-vm-$ID" \
    "$DIR/cros-sdk.sh" bash -c "
  export CROSVM_DISPLAY_SCALE=$SCALE
  CROSVM=.cache/crosvm-target/chromeos/crosvm

  # crosvm's qcow2 backing-file reads EOF-fail on the final PARTIAL 64 KiB
  # cluster of a raw backing image, wedging all guest disk I/O the moment
  # anything reads the backup GPT at disk end (update_engine does, ~60s in;
  # the guest then panics on hung tasks). Pad the base to a cluster multiple
  # before creating the overlay. Zero-filled padding past the backup GPT is
  # harmless -- same layout as any image dd'd to a larger disk.
  SZ=\$(stat -c%s '$IMG')
  PAD=\$(( (65536 - SZ % 65536) % 65536 ))
  if [ \$PAD -ne 0 ]; then
      echo \">>> padding base image by \$PAD bytes to a 64 KiB multiple (crosvm qcow2 quirk)\"
      truncate -s \$((SZ + PAD)) '$IMG'
  fi

  # --- disk: qcow2 overlay (default) or a raw full copy (CROS_VM_RAW=1) ---
  # The qcow2 create_qcow2 --backing-file path EOF-faults on a backing file
  # whose size is not a clean cluster multiple; padding mitigates but does
  # not always eliminate it, and the resulting I/O hangs look like a guest
  # boot-loop. CROS_VM_RAW=1 sidesteps qcow2 entirely with a writable raw
  # copy of the image -- slower to set up and not copy-on-write, but a
  # faithful block device, so a guest boot-loop under CROS_VM_RAW is real.
  if [ '${CROS_VM_RAW:-0}' = 1 ]; then
      if [ ! -s '$DISK' ]; then
          echo '>>> CROS_VM_RAW: copying base image to a raw writable disk (no qcow2)'
          cp --reflink=auto '$IMG' '$DISK'
      fi
  elif [ ! -s '$DISK' ]; then
      # Test for a NON-EMPTY file: a failed create_qcow2 leaves a 0-byte stub
      # behind, which would otherwise look like a usable overlay forever.
      rm -f '$DISK'
      echo '>>> creating qcow2 overlay backed by the base image'
      \$CROSVM create_qcow2 --backing-file '$IMG' '$DISK' || {
          rm -f '$DISK'
          echo 'error: could not create overlay (is the base image built?)' >&2
          exit 1
      }
  fi

  # --- network: TAP + DHCP + NAT, all inside this container's netns ---
  sudo ip tuntap add mode tap user cros vnet_hdr crosvm_tap
  sudo ip addr add 192.168.77.1/24 dev crosvm_tap
  sudo ip link set crosvm_tap up
  sudo sysctl -q -w net.ipv4.ip_forward=1
  sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  sudo iptables -t nat -A PREROUTING -p tcp --dport 2222 \
      -j DNAT --to-destination 192.168.77.2:22
  sudo iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 2222 \
      -j DNAT --to-destination 192.168.77.2:22
  sudo dnsmasq --interface=crosvm_tap --bind-interfaces \
      --dhcp-range=192.168.77.10,192.168.77.100 \
      --dhcp-host=52:54:00:c0:ff:ee,192.168.77.2

  DISPLAY_FLAGS=()
  if [ -n \"\${WAYLAND_DISPLAY:-}\" ] && [ -e \"\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY\" ]; then
      DISPLAY_FLAGS+=(--wayland-sock \"\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY\")
  elif [ -n \"\${DISPLAY:-}\" ]; then
      DISPLAY_FLAGS+=(--x-display \"\$DISPLAY\")
  else
      echo 'error: no WAYLAND_DISPLAY or DISPLAY available' >&2; exit 1
  fi

  exec \$CROSVM run \
    --disable-sandbox \
    \"\${DISPLAY_FLAGS[@]}\" \
    --display-window-keyboard --display-window-mouse \
    --mem $MEM --cpus $CPUS \
    --net tap-name=crosvm_tap,mac=52:54:00:c0:ff:ee \
    --gpu 'backend=virglrenderer,context-types=virgl2,egl=true,displays=[[mode=windowed[$W,$H]]]' \
    $BLOCK_FLAG 'path=$DISK,ro=false' \
    $DISK2_ARG \
    --serial 'type=file,path=$CONSOLE,hardware=serial,console=true,num=1,earlycon=true' \
    -p 'root=$ROOTDEV $ROOTFLAG rootwait noinitrd $CROS_DEBUG_FLAG cros_efi loglevel=7 console=ttyS0 earlyprintk=serial,ttyS0,115200 vt.global_cursor_default=0' \
    '$KERN'"
