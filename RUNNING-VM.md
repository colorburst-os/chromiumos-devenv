# Running the colorburst VM on an Ubuntu machine

This gets a colorburst image booting in a window on your desktop. You
don't need to know anything about crosvm or ChromiumOS internals —
every step is copy-paste. Everything runs in Docker containers; nothing
is installed on your host beyond Docker itself.

## 1. One-time host setup

```bash
sudo apt install docker.io git
sudo usermod -aG docker,kvm $USER
# log out and back in, then check both:
docker run --rm hello-world
ls /dev/kvm        # must exist; if not, enable VT-x/AMD-V in your BIOS
```

**NVIDIA GPU acceleration (optional):** if you have an NVIDIA GPU and
want hardware-accelerated virgl rendering (much faster than software),
install the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html):

```bash
sudo apt install nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

The scripts detect `nvidia-smi` on the host and inject the runtime
automatically — no extra flags needed.

You need roughly 10 GB of RAM free while a VM runs (the guest gets 8 GB)
and a Wayland or X11 desktop session for the VM window.

## 2. Get the repo and an image

```bash
# This repo (colorburst-os/chromium-os) is in the private colorburst-os org;
# clone it over HTTPS with the gh credential helper (`gh auth setup-git`) as an
# org member.
git clone https://github.com/colorburst-os/chromium-os.git
cd chromium-os
mkdir -p chromiumos
```

Put a colorburst image somewhere under `chromiumos/` (only files under
that directory are visible inside the containers):

- If you have a release file (`colorburst-<version>.bin`), copy it to
  `chromiumos/colorburst.bin`.
- If you build from source, the build drops it at
  `chromiumos/src/build/images/colorburst/latest/chromiumos_test_image.bin`
  (see [README.md](README.md) and [chromium/README.md](chromium/README.md)).

A release image needs its boot kernel next to it in
`boot_images/vmlinuz` — release archives ship that directory; a source
build produces it automatically.

## 3. One-time: build the VM runner

Three commands. They build the container, fetch the crosvm sources
(~30 MB, no full checkout needed), and build crosvm (ChromeOS's own
virtual machine monitor) — about 10 minutes:

`tools/fetch-crosvm-src.sh` clones the **crosvm fork**
(`github.com/colorburst-os/crosvm`, branch `colorburst/gpu-display`) plus its
minigbm/minijail dependencies. That fork is in the **private** `colorburst-os`
org, so you need org membership and the `gh` credential helper
(`gh auth setup-git`) for the clone to succeed. It also creates the
`third_party/minijail` symlink the build needs (see the note after step 3 if you
build crosvm from a full ChromiumOS checkout instead).

```bash
docker build --build-arg HOST_UID=$(id -u) -t cros-crosvm docker/crosvm
tools/fetch-crosvm-src.sh

env CROS_IMAGE=cros-crosvm NET=host ./cros-sdk.sh bash -c '
  cd src/platform/minigbm &&
  make install DESTDIR=$HOME/chromiumos/.cache/minigbm LIBDIR=/lib &&
  export CPATH=$HOME/chromiumos/.cache/minigbm/usr/include \
         PKG_CONFIG_PATH=$HOME/chromiumos/.cache/minigbm/lib/pkgconfig \
         RUSTFLAGS="-Lnative=$HOME/chromiumos/.cache/minigbm/lib -Clink-arg=-Wl,-rpath,$HOME/chromiumos/.cache/minigbm/lib"
  cd ../crosvm &&
  cargo build --profile chromeos --features "virgl_renderer,wl-dmabuf,x" \
        --target-dir $HOME/chromiumos/.cache/crosvm-target'
```

**Building crosvm from a FULL ChromiumOS checkout instead of
`fetch-crosvm-src.sh`?** A full checkout ships
`src/platform/crosvm/third_party/minijail` as an **empty stub directory**, so
`cargo build` dies with `failed to read
third_party/minijail/rust/minijail/Cargo.toml`. It needs a symlink to the real
minijail checkout — but because the stub *directory* already exists, a plain
`ln -s ../../minijail third_party/minijail` nests inside it
(`third_party/minijail/minijail`) and does not fix the build. Remove the stub
first, then symlink:

```bash
cd src/platform/crosvm
rm -rf third_party/minijail
ln -s ../../minijail third_party/minijail
```

(`fetch-crosvm-src.sh` already does this for the minimal-fetch path above.)

## 4. Run it

```bash
CROS_VM_SCSI=1 ./run-crosvm.sh chromiumos/colorburst.bin
```

A window opens; after ~60 seconds you're at the colorburst setup screen.
`CROS_VM_SCSI=1` is required for colorburst images (their kernel takes
its disk over virtio-scsi).

- SSH into the guest: `ssh -p 9222 root@localhost`, password `test0000`.
- Stop: close the window or Ctrl-C.
- Window too big/small: `CROS_DISPLAY=1920x1080 ...`
  sets the framebuffer size in pixels. `CROS_SCALE` adjusts desktop
  scaling but only works under Wayland; on X11 only `CROS_DISPLAY`
  has an effect.

The image file is never modified — each run boots a copy-on-write
overlay, so deleting `chromiumos/.vm/0/disk.qcow2` resets the VM to a
fresh install.

## Several VMs at once

```bash
tools/vm-instance.sh alloc mytest    # prints the instance id + ports
CROS_VM_SCSI=1 CROS_VM_IMAGE=$PWD/chromiumos/colorburst.bin \
    tools/vm-instance.sh boot <id>
tools/vm-instance.sh ssh <id> 'uptime'
tools/vm-instance.sh release <id>
```

Each instance has its own overlay, ports (SSH `9222+id`), and network
namespace. RAM is the limit: ~4 GB per extra instance.

## If something goes wrong

| Symptom | Fix |
|---|---|
| `error: image not found` | The image must live under `chromiumos/` inside the repo |
| Boot hangs at `Waiting for root device` | You forgot `CROS_VM_SCSI=1` |
| Black window after the boot splash | Wait 30 s first; if it stays black, the image was built without GPU drivers — use a release image |
| `/dev/kvm` missing | Enable virtualization (VT-x / AMD-V) in your BIOS |
| Docker permission denied | You didn't re-login after `usermod -aG docker` |
| Permission denied on source tree inside container | Your host UID is not 1000 — rebuild with `docker build --build-arg HOST_UID=$(id -u) ...` |
| `failed to connect to compositor` / no window | You're on X11, not Wayland — update to the version of `run-crosvm.sh` that auto-detects the display server |
| Very slow / choppy VM display | Install `nvidia-container-toolkit` and restart Docker (see step 1) for GPU-accelerated rendering |
| Mouse and keyboard don't work in the VM | The kernel needs `CONFIG_VIRTIO_INPUT=y` — see the build guide for the kernel config patch |
