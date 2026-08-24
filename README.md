# Building colorburst

This repository is the workshop for **colorburst**: ChromeOS Flex without the
Google account. It boots the same kind of old x86 laptop, but the account is
created on the device, there is no Gaia sign-in anywhere in the UI, no Google
services, and updates come from its own signed update server.

Language is not baked into the build. One image serves every region: a USB
variant is made by writing ChromeOS's own OEM customization manifest onto an
already-built image, and a device keeps that language through installs, updates
and powerwashes. Vietnamese is
the first variant that got the full treatment — a native IME on the UniKey
engine with Telex, VNI and VIQR — which is the proof that localizing this
properly is a variant's worth of work, not a fork's.

If you just want to *use* colorburst, you're in the wrong repo — see
[`colorburst-os/colorburst`](https://github.com/colorburst-os/colorburst).
If you want to build the OS yourself, read on.

This page is everything you need to produce a bootable image. Nothing
ChromiumOS-related is installed on your host; the whole toolchain lives in a
Docker container.

## Two different tools, two different jobs

These get confused constantly, so to be explicit:

| | What it is | When you need it |
|---|---|---|
| **Docker** | Runs the ChromiumOS SDK and every compiler in a container | **To build.** Required by everything on this page |
| **crosvm** | ChromeOS's own virtual machine monitor | **To run** the finished image in a window. Not involved in building at all |

You can build colorburst without ever touching crosvm, and without KVM. If
you later want to boot the image in a VM instead of on real hardware, that is
a separate one-time setup documented in [RUNNING-VM.md](RUNNING-VM.md).

The target board is `colorburst`, based on reven (the board behind ChromeOS
Flex), kernel 6.12. It runs on ordinary x86_64 laptops and in VMs.

## What you need

- **Linux with Docker.** That's the only thing installed on the host:
  ```bash
  sudo apt install docker.io git
  sudo usermod -aG docker $USER     # log out and back in
  docker run --rm hello-world       # must succeed before you continue
  ```
- **~200 GB of free disk.** The ChromiumOS checkout alone is ~176 GB,
  Chromium another ~30 GB.
- **Time.** Budget a large source sync plus 2–4 hours of compiling on a cold
  machine — most of it Chrome. Later rebuilds are minutes.
- **`repo` and `git`** on the host, for the source sync in step 1.

You do **not** need KVM, a GPU, or a desktop session to build. Those matter
only when you run the image.

## 1. Assemble the ChromiumOS tree (one-time, ~176 GB)

The tree is 287 git projects, so it lives outside this repo and is assembled
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
cd ..
```

Only two projects come from our forks; everything else is upstream at a
pinned SHA:

| Fork | Replaces | What the branch carries |
|---|---|---|
| `colorburst-os/board-overlays` (`colorburst/virgl`) | `chromiumos/overlays/board-overlays` | the colorburst appid, `/etc/os-release` fields, Gaia-less session_manager flags |
| `colorburst-os/crosvm` (`colorburst/gpu-display`) | `chromiumos/platform/crosvm` | window decorations, configurable display scale, pointer coordinate scaling |

The crosvm fork is swapped in here only so the tree matches what we ship;
building the OS image does not compile it.

(For the two forks the *branch tip* is what resolves — their SHAs in
`pinned-manifest.xml` are advisory. The other ~285 projects are exact.)

## 2. Fetch Chromium and apply the patch series

colorburst builds its own Chrome from a pinned Chromium base (r153,
`831a446cd4`) plus a series of ~30 patches — local accounts, the de-Googling,
branding, and the Vietnamese IME. `chromium-patches/apply-all.sh` applies the
whole series in the right order and leaves a clean tree:

```bash
chromium/fetch.sh                                    # ~30 GB
git -C ../chromium-src/src checkout -b colorburst 831a446cd4
chromium-patches/apply-all.sh ../chromium-src/src
```

What each patch does, and how the series is maintained, is documented in
[chromium/README.md](chromium/README.md).

## 3. Build the image

One command, no decisions:

```bash
chromium/rebuild-release.sh
```

This normalises both patched trees to the committed series, wipes the board's
build cache, bootstraps the board (which compiles *your* patched Chrome —
this is the 2–4 hour part), builds the verity-enabled release image, verifies
it in place, and stages an unsigned OTA payload. The result depends only on
the committed tree, which is the point: two people who run it on the same
commit get the same image.

Signing that payload (YubiKey) and publishing it are maintainer steps — see
`release/` — but the image itself is yours to boot.

If you're going to hack on the OS day to day, you don't want the full clean
build every time. After one `chromium/bootstrap-board.sh`, use
`chromium/build-image.sh` to cut a **test image** in minutes:

| You want… | Run | You get |
|---|---|---|
| The shippable release image | `chromium/rebuild-release.sh` | verity release image + unsigned OTA payload under `chromiumos/ota-release/<ver>/` |
| Fast iteration | `chromium/bootstrap-board.sh` once, then `chromium/build-image.sh` | test image (SSH-able, writable rootfs, no signing) at `…/images/colorburst/latest/chromiumos_test_image.bin` |

One warning worth reading twice: **never run plain `cros build-packages`
yourself.** It force-fetches Google's prebuilt Chrome from the binhost and
silently throws the entire patch series away. The scripts above pass the
flags that prevent this.

## 4. You have an image — now what

The build prints the path; release images land in
`chromiumos/src/build/images/colorburst/latest/`.

**Pick a language, without building again.** A variant is one file on the OEM
partition — and it is ChromeOS's own OEM customization manifest, not something
colorburst invented: `/opt/oem/etc/startup_manifest.json`, read by
`StartupCustomizationDocument`, carrying `initial_locale`, `initial_timezone`
and `keyboard_layout`.

```bash
release/make-variant.sh vn <image>.bin <image>-vi.bin    # Vietnamese
release/make-variant.sh --show <image>.bin               # what is this image?
```

Needs `mtools` and `e2fsprogs` on the host (`sudo apt install mtools
e2fsprogs`); no root, no loop devices.

The region name is a lookup key at repack time, not a mechanism on the device.
`make-variant.sh` reads the locale, timezone and hardware keyboard list for
that region out of the image's own `cros-regions.json` and writes them into the
manifest — so `vn` stays the one word you have to know, the device ends up
configured the way ChromeOS configures a Vietnamese device, and nothing sets
`--cros-region` at runtime.

That partition carries neither a verity hash tree nor a signature, so this is a
few hundred bytes of edit to a 6.6 GB image: no rebuild, no re-sign, kernel and
rootfs byte-identical, which is why every variant shares one OTA payload. It is
also the only partition that survives all three of install, OTA and powerwash —
so a machine keeps the language of the stick it was installed from.

It is **FAT32, typed as Microsoft basic data**, so after writing the image to a
USB stick Windows shows the partition in Explorer.

Two limits worth knowing. Windows shows it on **removable** media; once
installed to an internal disk the partition is retyped by the installer from
the board layout, so a dual-boot Windows will not mount it. And **nothing may
set a region** — a region populates the same statistics from `cros-regions.json`
and `StartupCustomizationDocument` applies statistics *over* the manifest, so a
single `--cros-region` anywhere silently beats every variant file. A release
gate checks for that.

**Run it in a VM.** This is where crosvm comes in, and it needs its own
one-time setup (KVM, a desktop session, building the VM runner). All of it is
in **[RUNNING-VM.md](RUNNING-VM.md)** — start there once you have an image.

**Or write it to USB and boot real hardware:**

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
| `docker/` | Container images: `cros-build` (sync + build — the one this page uses), `cros-vm` (QEMU), `cros-crosvm` (crosvm, for RUNNING-VM.md) |
| `chromiumos/` | The source checkout, SDK chroot, and built images (bind-mounted into every container) |
| `chromium/` | Chrome-side tooling: fetch, build, deploy-to-VM, image cutting — see [chromium/README.md](chromium/README.md) |
| `chromium-patches/` | The patch series + vendored IME payloads, applied by `apply-all.sh` |
| `platform2-patches/` | ChromeOS system-code patches (device id, DLC fetch host, region input methods) |
| `release/` | Version cutting, payload generation, language variants (`make-variant.sh`), YubiKey signing, publishing — maintainer territory. See [releases/README.md](releases/README.md) for the versioning and branch scheme |
| `tools/` | `vm-instance.sh` (parallel VMs), `cdp.py` (drive Chrome via DevTools), `guest-type.py`, and friends |

## Keeping the forks fresh

Each fork keeps upstream as a remote named `cros`. The patches touch files
upstream changes actively, so rebase rather than merge:

```bash
git fetch cros && git rebase cros/chromeos   # e.g. in src/overlays
```

## The one thing people always hit

**GPU-accelerated graphics require the virgl Mesa driver *inside the image*.**
On the colorburst board this comes for free (inherited from the `reven:base`
profile). But if you ever see every VMM display go black right after the boot
splash while the system otherwise runs — that's the guest silently falling
back to llvmpipe, and it means the image you built lost the virgl driver.
Check the board profile before debugging anything else.
