# Building colorburst

This repository is the workshop for **colorburst**, a ChromiumOS fork for
Vietnamese users: Gaia-less local accounts, a native Vietnamese IME (UniKey
engine, Telex/VNI/VIQR), no Google services, its own update server. If you
just want to *use* colorburst, you're in the wrong repo — see
[`colorburst-os/colorburst`](https://github.com/colorburst-os/colorburst).
If you want to build the OS yourself, read on.

Everything builds and runs inside Docker containers; nothing ChromiumOS-related
is installed on your host. The target board is `colorburst`, based on reven
(the board behind ChromeOS Flex), kernel 6.12. It runs on ordinary x86_64
laptops and in VMs.

## What you need

- Linux with Docker and KVM (`/dev/kvm` must exist — check with `ls /dev/kvm`)
- ~200 GB of free disk. The ChromiumOS checkout alone is ~176 GB, Chromium
  another ~30 GB
- Patience for the first build: budget a big source sync plus 2–4 hours of
  compile on a cold machine. After that, rebuilds take minutes
- Membership in the `colorburst-os` GitHub org (it is private for now), with
  git set up to reach it over HTTPS: `gh auth login && gh auth setup-git`.
  Two of the source projects are pulled from our forks during the sync, so
  without org access the tree cannot be assembled

Host setup details (packages, KVM group membership, Docker) are in
[RUNNING-VM.md](RUNNING-VM.md) §1.

## The build, end to end

Four steps. Each is a command or two; the work happens in containers.

### 1. Assemble the ChromiumOS tree (one-time, ~176 GB)

The tree is 287 git projects, so it lives outside this repo and is rebuilt
with `repo` from a pinned manifest — you get the exact revisions the patch
series was written against, not whatever upstream moved to overnight:

```bash
mkdir chromiumos && cd chromiumos
# Init any manifest first, so .repo/manifests exists as a git repo…
repo init -u https://chromium.googlesource.com/chromiumos/manifest
# …then drop in the pinned manifest and re-init against it.
cp ../pinned-manifest.xml .repo/manifests/
repo init -m pinned-manifest.xml
# Swap crosvm + board-overlays to the colorburst forks.
mkdir -p .repo/local_manifests
ln -s ../../../local_manifests/colorburst.xml .repo/local_manifests/
repo sync -j8        # go make dinner
```

Only two projects come from our forks; everything else is upstream at a
pinned SHA:

| Fork | Replaces | What the branch carries |
|---|---|---|
| `colorburst-os/crosvm` (`colorburst/gpu-display`) | `chromiumos/platform/crosvm` | window decorations, configurable display scale, pointer coordinate scaling |
| `colorburst-os/board-overlays` (`colorburst/virgl`) | `chromiumos/overlays/board-overlays` | the colorburst appid, `/etc/os-release` fields, Gaia-less session_manager flags |

(For the two forks, the *branch tip* is what resolves — their SHAs in
`pinned-manifest.xml` are advisory. The other ~285 projects are exact.)

### 2. Fetch Chromium and apply the patch series

colorburst builds its own Chrome from a pinned Chromium base (r153,
`831a446cd4`) plus a series of ~30 patches — local accounts, the Vietnamese
IME, the de-Googling, branding. `chromium-patches/apply-all.sh` applies the
whole series in the right order and leaves a clean tree:

```bash
chromium/fetch.sh                                    # ~30 GB
git -C ../chromium-src/src checkout -b colorburst 831a446cd4
chromium-patches/apply-all.sh ../chromium-src/src
```

What each patch does, and how the series is maintained, is documented in
[chromium/README.md](chromium/README.md).

### 3. Build the OS image

One command, no decisions:

```bash
chromium/rebuild-release.sh
```

This normalises both patched trees to the committed series, wipes the board's
build cache, bootstraps the board (which compiles *your* patched Chrome —
this is the 2–4 hour part, mostly Chrome), builds the verity-enabled release
image, verifies it in place, and stages an unsigned OTA payload. The result
depends only on the committed tree, which is the point: two people who run it
on the same commit get the same image.

Signing that payload (YubiKey) and publishing it are maintainer steps — see
`release/` — but the image itself is yours to boot.

If you're going to hack on the OS day to day, you don't want the full clean
build every time. After one `chromium/bootstrap-board.sh`, use
`chromium/build-image.sh` to cut a **test image** in minutes: SSH-able,
writable rootfs, no signing. The two image types:

| You want… | Run | You get |
|---|---|---|
| The shippable release image | `chromium/rebuild-release.sh` | verity release image + unsigned OTA payload under `chromiumos/ota-release/<ver>/` |
| Fast iteration in a VM | `chromium/bootstrap-board.sh` once, then `chromium/build-image.sh` | test image at `…/images/colorburst/latest/chromiumos_test_image.bin` |

One warning worth reading twice: **never run plain `cros build-packages`
yourself.** It force-fetches Google's prebuilt Chrome from the binhost and
silently throws the entire patch series away. The scripts above pass the
flags that prevent this.

### 4. Boot it

In a VM — a window on your desktop about a minute later:

```bash
./run-crosvm.sh chromiumos/src/build/images/colorburst/latest/colorburst-*-release.bin
```

(The disk is presented over virtio-scsi by default — the colorburst kernel
builds virtio_blk as a module, so a virtio-blk boot disk would hang waiting
for root. `CROS_VM_SCSI=0` exists only for old amd64-generic images.)
Every VM is reachable with `ssh -p 9222 root@localhost`,
password `test0000` (test images only — release images have no remote
access, by design). The full VM guide, including GPU acceleration and
troubleshooting, is [RUNNING-VM.md](RUNNING-VM.md).

On real hardware — write a test image to USB and boot it:

```bash
# Double-check the device letter with lsblk. Really.
sudo dd if=chromiumos/src/build/images/colorburst/latest/chromiumos_test_image.bin \
        of=/dev/sdX bs=4M conv=fsync status=progress
# Verify the write — catches dying USB sticks before they waste your evening:
sudo cmp chromiumos/src/build/images/colorburst/latest/chromiumos_test_image.bin /dev/sdX
```

Disable Secure Boot in the target's UEFI, boot from the stick, and pick
**local image A** at the boot menu. Running from USB never touches the
internal disk; the graphical installer, if you choose to run it, erases the
disk it installs to.

## Repository layout

| Path | What it is |
|---|---|
| `cros-sdk.sh` | Run any command inside the build container. Knobs: `CROS_IMAGE=` (image), `GUI=1` (Wayland/X + GPU), `PUBLISH_PORTS=1` (VNC 5900, SSH 9222), `NET=host` |
| `docker/` | The three container images: `cros-build` (sync + build), `cros-vm` (QEMU), `cros-crosvm` (crosvm + VM networking) |
| `chromiumos/` | The source checkout, SDK chroot, and built images (bind-mounted into every container) |
| `chromium/` | Chrome-side tooling: fetch, build, deploy-to-VM, image cutting — see [chromium/README.md](chromium/README.md) |
| `chromium-patches/` | The patch series + vendored IME payloads, applied by `apply-all.sh` |
| `platform2-patches/` | update_engine patches (device id, DLC fetch host) |
| `release/` | Payload generation, YubiKey signing, publishing — maintainer territory |
| `tools/` | `vm-instance.sh` (parallel VMs), `cdp.py` (drive Chrome via DevTools), `guest-type.py`, and friends |

## Several VMs at once

Instances are isolated — each gets a qcow2 overlay over the shared base image
(the base is never written), its own container and network namespace, and its
own host ports (SSH `9222+id`, VNC `5900+id`):

```bash
tools/vm-instance.sh alloc alice     # claims a free id, prints its ports
tools/vm-instance.sh boot 0          # ~60 s to the login screen
tools/vm-instance.sh ssh 0 'uptime'
tools/vm-instance.sh list
tools/vm-instance.sh release 0      # kill + wipe; next alloc starts pristine
```

RAM is the limit, not disk: a comfortable ChromeOS guest wants 8 GB, and a
minimal one boots in 4 GB. Size your instance count to your machine.

## Keeping the forks fresh

Each fork keeps upstream as a remote named `cros`. The patches touch files
upstream changes actively, so rebase rather than merge:

```bash
git fetch cros && git rebase cros/chromeos   # e.g. in src/platform/crosvm
```

## The one thing people always hit

**GPU-accelerated graphics require the virgl Mesa driver *inside the image*.**
On the colorburst board this comes for free (inherited from the `reven:base`
profile). But if you ever see every VMM display go black right after the boot
splash while the system otherwise runs — that's the guest silently falling
back to llvmpipe, and it means the image you built lost the virgl driver.
Check the board profile before debugging anything else.
