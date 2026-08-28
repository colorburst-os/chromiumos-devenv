# Building colorburst

This repository builds **colorburst**: ChromeOS Flex without a Google account. It boots on old x86 laptops, creates the account on-device, removes Gaia sign-in and Google services from the UI, and gets updates from its own signed update server.

Language is not baked into the build. One image serves every region. A USB variant writes ChromeOS's OEM customization manifest to an existing image, and the device preserves that language through installs, updates, and powerwashes. Vietnamese is the first full variant, with a native IME using UniKey and Telex, VNI, and VIQR. Proper localization is therefore a variant, not a fork.

If you want to use colorburst, see [`colorburst-os/colorburst`](https://github.com/colorburst-os/colorburst). To build the OS, continue here.

This page covers everything needed to produce a bootable image. The host does not need ChromiumOS tooling; the toolchain runs in Docker.

## VM types

| | What it is | When you need it |
|---|---|---|
| **Docker** | Runs the ChromiumOS SDK and compilers in a container | **Builds.** Required by everything here |
| **crosvm** | ChromeOS's virtual machine monitor | **Runs** a finished image in a window. Not used to build |

You can build colorburst without crosvm or KVM. Running the image in a VM is a separate one-time setup documented in [RUNNING-VM.md](RUNNING-VM.md).

The target board is `colorburst`, based on `reven` (the board behind ChromeOS Flex), with kernel 6.12. It runs on x86_64 laptops and in VMs.

## What you need

- **Linux with Docker.** The host only needs:
  ```bash
  sudo apt install docker.io git
  sudo usermod -aG docker $USER     # log out and back in
  docker run --rm hello-world       # must succeed before continuing
  ```
- **The `cros-build` image, built for your UID.** `docker/Dockerfile` bakes in a
  fixed UID (default 1000) for the container's build user, and every script here
  bind-mounts `chromiumos/` and `$CHROME` from the host into that user. If your
  UID differs, the container user can't write to them and you'll see
  `PermissionError: ... Permission denied` partway through `chromium/fetch.sh`
  or a build. Build the image against your own UID before starting:
  ```bash
  docker build --build-arg HOST_UID=$(id -u) -t cros-build docker/
  ```
- **~200 GB free disk.** The ChromiumOS checkout is ~176 GB; Chromium adds ~30 GB.
- **Time.** Allow a large source sync and 2–4 hours to compile on a cold machine, mostly for Chrome. Later rebuilds take minutes.
- **`repo` and `git`** on the host for the source sync.

KVM, a GPU, and a desktop session are not required to build. They are required only to run the image.

## 1. Assemble the ChromiumOS tree

The tree contains 287 git projects and lives outside this repository. `repo` assembles it from a pinned manifest:

```bash
gh repo clone colorburst-os/chromiumos-devenv && cd chromiumos-devenv
mkdir -p chromiumos && cd chromiumos
# Init any manifest first so .repo/manifests exists as a git repo.
repo init -u https://chromium.googlesource.com/chromiumos/manifest
# Install the pinned manifest and re-init against it.
cp ../pinned-manifest.xml .repo/manifests/
repo init -m pinned-manifest.xml
# Swap crosvm and board-overlays to the colorburst forks.
mkdir -p .repo/local_manifests
ln -s ../../../local_manifests/colorburst.xml .repo/local_manifests/
repo sync -j8
cd ..
```

Only two projects come from forks; the rest use upstream pinned SHAs:

| Fork | Replaces | What the branch carries |
|---|---|---|
| `colorburst-os/board-overlays` (`colorburst/virgl`) | `chromiumos/overlays/board-overlays` | colorburst appid, `/etc/os-release` fields, Gaia-less `session_manager` flags |
| `colorburst-os/crosvm` (`colorburst/gpu-display`) | `chromiumos/platform/crosvm` | window decorations, configurable display scale, pointer coordinate scaling |

The crosvm fork is included to match the shipped tree; building the OS image does not compile it.

For the two forks, the branch tip resolves; their SHAs in `pinned-manifest.xml` are advisory. The other ~285 projects are exact.

## 2. Fetch Chromium and apply the patch series

colorburst builds Chrome from pinned Chromium r153 (`831a446cd4`) plus ~30 patches for local accounts, de-Googling, branding, and the Vietnamese IME. `chromium-patches/apply-all.sh` applies them in order:

```bash
chromium/fetch.sh                                    # ~30 GB
git -C ../chromium-src/src checkout -b colorburst 831a446cd4
chromium-patches/apply-all.sh ../chromium-src/src
```

See [chromium/README.md](chromium/README.md) for patch details and maintenance.

## 3. Build the image

```bash
chromium/rebuild-release.sh
```

This normalizes both patched trees to the committed series, clears the board build cache, bootstraps the board, compiles the patched Chrome, builds and verifies a verity-enabled release image, and stages an unsigned OTA payload. A given commit produces the same image.

Signing the payload with a YubiKey and publishing it are maintainer steps; see `release/`.

For day-to-day development, after one `chromium/bootstrap-board.sh`, use `chromium/build-image.sh` for test images:

| You want | Run | Result |
|---|---|---|
| Shippable release image | `chromium/rebuild-release.sh` | Verity release image + unsigned OTA payload under `chromiumos/ota-release/<ver>/` |
| Fast iteration | `chromium/bootstrap-board.sh` once, then `chromium/build-image.sh` | Test image (SSH-able, writable rootfs, unsigned) at `…/images/colorburst/latest/chromiumos_test_image.bin` |

**Do not run plain `cros build-packages`.** It fetches Google's prebuilt Chrome from the binhost and discards the patch series. The scripts above pass the required flags.

## 4. Use the image

Release images are in `chromiumos/src/build/images/colorburst/latest/`.

**Create a language variant without rebuilding.** A variant is an OEM customization manifest on the OEM partition:

`/opt/oem/etc/startup_manifest.json`

ChromeOS reads it through `StartupCustomizationDocument`. It contains `initial_locale`, `initial_timezone`, and `keyboard_layout`.

```bash
release/make-variant.sh vn <image>.bin <image>-vi.bin    # Vietnamese
release/make-variant.sh --show <image>.bin               # show variant
```

Requires `mtools` and `e2fsprogs` on the host:

```bash
sudo apt install mtools e2fsprogs
```

No root or loop devices are required.

`make-variant.sh` uses the region name as a lookup key. It reads the region's locale, timezone, and hardware keyboard list from the image's `cros-regions.json` and writes them to the manifest. `vn` is therefore only a repack-time key; the device does not use `--cros-region`.

The OEM partition has no verity hash tree or signature, so changing it edits only a few hundred bytes of a 6.6 GB image. No rebuild or re-signing is required; the kernel and rootfs remain byte-identical, so all variants share one OTA payload. The partition also survives install, OTA, and powerwash, preserving the language selected by the source USB image.

The partition is FAT32 with the Microsoft basic data type, so Windows shows it on a USB stick.

On removable media, Windows shows the partition. After installation to an internal disk, the installer retypes it according to the board layout, so Windows dual-boot will not mount it.

**Do not set a region.** A region populates the same data from `cros-regions.json`, and `StartupCustomizationDocument` applies it over the manifest. Any `--cros-region` setting therefore overrides the variant file. A release gate checks for this.

**Run in a VM.** crosvm requires one-time KVM, desktop-session, and VM-runner setup. See [RUNNING-VM.md](RUNNING-VM.md).

**Write to USB and boot real hardware:**

```bash
# Verify the device with lsblk.
sudo dd if=chromiumos/src/build/images/colorburst/latest/chromiumos_test_image.bin \
        of=/dev/sdX bs=4M conv=fsync status=progress

# Verify the write.
sudo cmp chromiumos/src/build/images/colorburst/latest/chromiumos_test_image.bin /dev/sdX
```

Disable Secure Boot in UEFI, boot from the USB stick, and select **local image A**. USB boot does not touch the internal disk. The graphical installer erases the disk it installs to.

## Repository layout

| Path | What it is |
|---|---|
| `cros-sdk.sh` | Runs commands inside the build container. Options: `CROS_IMAGE=` (image), `GUI=1` (Wayland/X + GPU), `PUBLISH_PORTS=1` (VNC 5900, SSH 9222), `NET=host` |
| `docker/` | Container images: `cros-build` (sync + build), `cros-vm` (QEMU), `cros-crosvm` (crosvm for `RUNNING-VM.md`) |
| `chromiumos/` | Source checkout, SDK chroot, and built images; bind-mounted into every container |
| `chromium/` | Chrome tooling: fetch, build, VM deployment, image cutting; see [chromium/README.md](chromium/README.md) |
| `chromium-patches/` | Patch series and vendored IME payloads, applied by `apply-all.sh` |
| `platform2-patches/` | ChromeOS system-code patches: device ID, DLC fetch host, region input methods |
| `kernel-patches/` | ChromeOS kernel config patches: virtio-input on reven, for crosvm mouse/keyboard |
| `release/` | Version cutting, payload generation, language variants, YubiKey signing, publishing; see [releases/README.md](releases/README.md) |
| `tools/` | `vm-instance.sh` (parallel VMs), `cdp.py` (Chrome via DevTools), `guest-type.py`, and related tools |

## Keeping the forks fresh

Each fork has upstream as a remote named `cros`. Because the patches touch actively changing upstream files, rebase rather than merge:

```bash
git fetch cros && git rebase cros/chromeos   # e.g. in src/overlays
```

## GPU troubleshooting

**GPU-accelerated graphics require the virgl Mesa driver inside the image.**

The `colorburst` board inherits it from the `reven:base` profile. If every VMM display goes black after the boot splash while the system continues running, the guest likely fell back to llvmpipe because the image lost the virgl driver. Check the board profile before debugging further.
