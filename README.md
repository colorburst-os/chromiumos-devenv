# colorburst build & VM environment (Dockerized)

Everything here builds and runs **colorburst** — a ChromiumOS fork for
Vietnamese users — **inside Docker containers**; nothing is installed on the
host. The board is `colorburst` — based on reven (ChromeOS Flex), kernel 6.12,
validated on real laptops and in VMs. (`amd64-generic` was the original
board; retired.)

The user-facing repository is [`colorburst-os/colorburst`](https://github.com/colorburst-os/colorburst).
This one is the workshop: build tooling, VM tooling, the Chrome patch series,
and the notes behind every decision.

## Layout

| Path | What it is |
|---|---|
| `cros-sdk.sh` | Runs any command in a container. Env knobs: `CROS_IMAGE=` (image to use), `GUI=1` (Wayland/X + GPU render node access), `PUBLISH_PORTS=1` (VNC 5900, SSH 9222 on localhost), `NET=host` (host networking, for flaky container DNS) |
| `docker/Dockerfile` | `cros-build` image: Ubuntu 24.04 + depot_tools; used for repo sync, cros_sdk chroot, package/image builds |
| `docker/vm/Dockerfile` | `cros-vm` image: Ubuntu 26.04 with QEMU 10.x (new enough for GL display paths) |
| `docker/crosvm/Dockerfile` | `cros-crosvm` image: Rust toolchain + wayland/virgl dev libs to build crosvm, plus dnsmasq/iptables for VM networking |
| `chromiumos/` | The source checkout + SDK chroot + built images (bind-mounted into every container) |
| `chromium/` | Chrome-side build tooling: fetch a Chromium tree, build it, deploy it to a running VM, cut an image. See [chromium/README.md](chromium/README.md) |
| `chromium-patches/` | The ~25-patch series that makes Chromium into colorburst's Chrome, plus the rule-based IME and UniKey payloads. Applied in order by `chromium-patches/apply-all.sh` — see [chromium/README.md](chromium/README.md) |
| `tools/` | `vm-instance.sh` (isolated VMs), `cdp.py` (drive Chrome over DevTools), `guest-type.py` (type on a real keyboard device in the guest), `pak.py`, `local-account-walk.sh` |

## Quick start — from nothing to a VM, end to end

Five steps, in order. On a cold machine budget **one long build (2–4 h)** plus a
big first-time source sync; after that, rebuilds are minutes. Everything runs in
containers — the only thing on your host is Docker.

**Before you start (once):** Docker + KVM (`/dev/kvm` must exist), ~200 GB free
disk, and membership in the private `colorburst-os` GitHub org with the `gh`
credential helper set up (`gh auth setup-git`) — the source sync pulls two forks
over HTTPS. See RUNNING-VM.md §1 for the exact host setup.

```bash
# 1. Assemble the pinned ChromiumOS tree into chromiumos/  (one-time, ~176 GB).
#    Full recipe under "Reproducing the checkout" below.

# 2. Fetch the pinned Chromium base and apply the colorburst patch series.
#    (Details + the full patch list: chromium/README.md.)
chromium/fetch.sh                                    # ~30 GB, pinned base 831a446cd4
git -C ../chromium-src/src checkout -b colorburst 831a446cd4
chromium-patches/apply-all.sh ../chromium-src/src    # applies the whole series, in order

# 3. Build — ONE command, no decisions. This is the deterministic clean build:
#    it normalises every patch tree, nukes the board cache, bootstraps the board
#    (setup_board + build-packages, which compiles OUR patched Chrome), builds
#    the verity release image, and stages the unsigned OTA payload. Just run it
#    and wait (2–4 h cold). Signing the payload is a separate maintainer step.
chromium/rebuild-release.sh

# 4. Run it in a VM — a window on your desktop in ~60 s. Full copy-paste guide:
#    RUNNING-VM.md.  (CROS_VM_SCSI=1 is required for colorburst images.)
CROS_VM_SCSI=1 ./run-crosvm.sh \
    chromiumos/src/build/images/colorburst/latest/colorburst-*-release.bin
```

All VMs: `ssh -p 9222 root@localhost`, password `test0000`.

**Two kinds of build — pick by what you're doing:**

| You want… | Run | Produces |
|---|---|---|
| The shippable, OTA-signable image (what releases are cut from) | `chromium/rebuild-release.sh` | verity **release** image + unsigned payload under `chromiumos/ota-release/<ver>/` |
| Fast day-to-day iteration in a VM (SSH-able, writable, no signing) | `chromium/bootstrap-board.sh` once, then `chromium/build-image.sh` | **test** image at `…/images/colorburst/latest/chromiumos_test_image.bin` |

`rebuild-release.sh` is the "even a dumb agent just runs this and watches it
finish" path: it is fully deterministic — the image depends on the committed
tree, not on who drives it. **Never** run plain `cros build-packages`: it
force-fetches Chrome from the binhost and throws our patches away.

## Running several VMs at once

Instances are isolated, so multiple people (or agents) can each have their own
machine:

```bash
tools/vm-instance.sh alloc alice     # claims a free id, prints its ports
tools/vm-instance.sh boot 0          # ~60s to the login screen
tools/vm-instance.sh ssh 0 'uptime'
tools/vm-instance.sh list
tools/vm-instance.sh release 0       # kills it and wipes the workspace
```

Each instance gets a **qcow2 overlay** over the shared base image (so the 11 GB
base is never written and instances can't corrupt each other), its own host
ports (SSH `9222+id`, VNC `5900+id`), its own container — hence its own netns,
so the TAP device and the guest's `192.168.77.2` are identical inside every
instance — and its own workspace at `chromiumos/.vm/<id>/`.

Releasing wipes the workspace, so the next `alloc` of that id starts from a
pristine image. Customise an instance by changing its guest, never the base.

**RAM is the limit, not disk.** This host has ~30 GB and a comfortable ChromeOS
guest wants 8 GB, so `alloc` gives the first instance 8 GB and later ones 4 GB.
Four concurrent instances is realistic; five will swap. 4 GB reaches the login
screen but has not been tested under a full session.

## Testing on real hardware (USB)

```bash
# The image (also hardlinked as colorburst-<version>.bin):
ls chromiumos/src/build/images/colorburst/latest/

# Flash (check the device letter with lsblk first!):
sudo dd if=chromiumos/src/build/images/colorburst/latest/chromiumos_test_image.bin \
        of=/dev/sdX bs=4M conv=fsync status=progress

# Verify the write before booting -- catches dying sticks:
sudo cmp chromiumos/src/build/images/colorburst/latest/chromiumos_test_image.bin /dev/sdX
```

On the target machine: disable Secure Boot in UEFI, boot from USB, pick
**local image A** at the boot menu. Trying from USB never touches the
internal disk; the graphical installer erases the disk it installs to.

## Reproducing the checkout

The ChromiumOS tree is 287 projects and ~176 GB, so it is not stored here.
It is rebuilt with `repo`, and only the two projects we patch come from
our own forks:

| Fork | Upstream | Patch |
|---|---|---|
| `colorburst-os/crosvm` | `chromiumos/platform/crosvm` | branch `colorburst/gpu-display` — window decorations, configurable display scale, pointer coordinate scaling |
| `colorburst-os/board-overlays` | `chromiumos/overlays/board-overlays` | branch `colorburst/virgl` — the colorburst appid and `/etc/os-release` fields, and the Gaia-less session_manager flags (video comes from `reven:base`, not this overlay) |

**Access prerequisite:** the two forks live in the **private** `colorburst-os`
GitHub org. Authorized builders reach them over HTTPS with the `gh` credential
helper (`gh auth setup-git`) once they are a member of the org — the local
manifest below fetches them by `https://github.com/colorburst-os/…`. Without
org access `repo sync` cannot check them out, and the tree cannot be assembled.

Sync the **exact pinned tree** the patch series targets (Chromium r153). The
`-b stable` branch is a *moving* target and will drift from the pinned SHAs, so
reproduce byte-for-byte via `pinned-manifest.xml`:

```bash
mkdir chromiumos && cd chromiumos
# 1. Init any manifest first, so .repo/manifests exists as a git repo.
repo init -u https://chromium.googlesource.com/chromiumos/manifest
# 2. Drop the pinned manifest in and re-init against it. pinned-manifest.xml is
#    a bare file (not in a manifest git repo), so it must be copied inside.
cp ../pinned-manifest.xml .repo/manifests/
repo init -m pinned-manifest.xml
# 3. Install the local manifest that swaps crosvm/board-overlays to the forks.
mkdir -p .repo/local_manifests
ln -s ../../../local_manifests/colorburst.xml .repo/local_manifests/
repo sync -j8
```

`local_manifests/colorburst.xml` swaps those two projects to the forks;
everything else still comes from upstream.

`pinned-manifest.xml` records the exact SHA of all 287 projects as of the last
known-good build. **The local manifest is authoritative for the two forks:** it
overrides crosvm and board-overlays to *branch refs*
(`refs/heads/colorburst/gpu-display`, `refs/heads/colorburst/virgl`), so the
fork SHAs baked into `pinned-manifest.xml` are advisory only — the branch tip
resolves, not the pinned SHA, and the two can differ. For the ~285 upstream
projects the pinned SHA is exact. Because those fork revisions exist only in our
forks, the pinned manifest needs the local manifest (or the forks fetched) to
resolve at all.

Each fork keeps upstream as a remote named `cros`. The patches are
un-upstreamed and touch files upstream actively changes, so expect to
rebase rather than merge:

```bash
git fetch cros && git rebase cros/chromeos   # in src/platform/crosvm
```

## The one thing to never forget

**GPU-accelerated graphics require the *image* to contain the virgl Mesa
driver.** On the live `colorburst` board this comes for free: `overlay-colorburst`
sets no `VIDEO_CARDS` of its own and inherits `virgl` from its `reven:base`
profile. (The retired `overlay-amd64-generic` board carried `virgl` explicitly
in `profiles/base/make.defaults`; that overlay is no longer used.) Either way,
if the driver is missing the guest silently falls back to llvmpipe and every VMM
display shows black after the boot splash.
