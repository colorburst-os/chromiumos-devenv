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
| `chromium-patches/` | The four patches that make Chromium into colorburst's Chrome, plus the 86-file rule-based IME payload |
| `tools/` | `vm-instance.sh` (isolated VMs), `cdp.py` (drive Chrome over DevTools), `guest-type.py` (type on a real keyboard device in the guest), `pak.py`, `local-account-walk.sh` |

## Quick start

```bash
# Build. This builds our patched Chrome, then the BSP package, then an image.
# 2-3 h cold, ~10 min warm.  NEVER plain `cros build-packages`: it force-fetches
# Chrome from the binhost and throws our patches away. See chromium/README.md.
chromium/build-image.sh

# Run (see RUNNING-VM.md for the from-scratch guide)
CROS_VM_SCSI=1 ./run-crosvm.sh   # crosvm, GPU window + network (colorburst images need CROS_VM_SCSI=1)
```

All VMs: `ssh -p 9222 root@localhost`, password `test0000`.

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
| `colorburst-os/board-overlays` | `chromiumos/overlays/board-overlays` | branch `colorburst/virgl` — `virgl` in `VIDEO_CARDS`, the colorburst appid and `/etc/os-release` fields, and the Gaia-less session_manager flags |

```bash
mkdir chromiumos && cd chromiumos
repo init -u https://chromium.googlesource.com/chromiumos/manifest -b stable
mkdir -p .repo/local_manifests
ln -s ../../../local_manifests/colorburst.xml .repo/local_manifests/
repo sync -j8
```

`local_manifests/colorburst.xml` swaps those two projects to the forks;
everything else still comes from upstream.

`pinned-manifest.xml` records the exact SHA of all 287 projects as of the
last known-good build. To reproduce that tree byte for byte, pass it to
`repo init -m` instead. Note it pins crosvm and board-overlays to commits
that exist only in our forks, so it needs the local manifest (or the forks
fetched) to resolve.

Each fork keeps upstream as a remote named `cros`. The patches are
un-upstreamed and touch files upstream actively changes, so expect to
rebase rather than merge:

```bash
git fetch cros && git rebase cros/chromeos   # in src/platform/crosvm
```

## The one thing to never forget

**GPU-accelerated graphics require the *image* to contain the virgl Mesa
driver.** `overlay-amd64-generic/profiles/base/make.defaults` must have
`virgl` in `VIDEO_CARDS`, or the guest silently falls back to llvmpipe and
every VMM display shows black after the boot splash.
