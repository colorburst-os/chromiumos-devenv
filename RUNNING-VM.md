# Running a colorburst image in a VM

This page is only about **running** an image you already have. It does not
build colorburst — for that see [README.md](README.md), which is
self-contained and needs none of this.

## What crosvm is, and why not QEMU

**crosvm** is ChromeOS's own virtual machine monitor. We use it rather than
QEMU because it is what ChromeOS is developed against: it speaks the Wayland
and virtio-gpu protocols the guest expects, so you get **GPU-accelerated
graphics through virglrenderer** and a real desktop instead of a software
framebuffer. A colorburst guest under crosvm behaves like the same image on
hardware; under plain QEMU it falls back to llvmpipe and crawls.

crosvm plays no part in building an image. It is a separate one-time setup,
below.

The runner itself is built and executed inside a Docker container, so the only
things installed on your host are Docker and the KVM permissions.

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

## 2. Put an image where the container can see it

Only files under `chromiumos/` are visible inside the containers, so the image
has to live there:

- **Built it yourself?** It is already in the right place —
  `chromiumos/src/build/images/colorburst/latest/`.
- **Downloaded a release?** Unpack it and copy the `.bin` to
  `chromiumos/colorburst.bin`.

A release image also needs its boot kernel beside it, either as
`boot_images/vmlinuz` next to the `.bin` or as a file named `vmlinuz` in the
same directory — colorburst boots the kernel directly rather than through the
image's own bootloader. A source build produces `boot_images/` automatically.

## 3. One-time: build the VM runner

Three commands: build the container, fetch the crosvm sources (~30 MB — no
full ChromiumOS checkout needed), and compile crosvm. About 10 minutes.

`tools/fetch-crosvm-src.sh` clones the **crosvm fork**
([`colorburst-os/crosvm`](https://github.com/colorburst-os/crosvm), branch
`colorburst/gpu-display`) plus its minigbm and minijail dependencies, and
creates the `third_party/minijail` symlink the build needs.

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

**Building crosvm from a FULL ChromiumOS checkout instead?** A full checkout
ships `src/platform/crosvm/third_party/minijail` as an **empty stub
directory**, so `cargo build` dies with `failed to read
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

## 4. Run it

```bash
./run-crosvm.sh chromiumos/colorburst.bin
```

A window opens; after ~60 seconds you are at the colorburst setup screen.

The disk is attached over **virtio-scsi** by default, because the colorburst
kernel builds `virtio_blk` as a module — a virtio-blk boot disk never appears
and the guest hangs at `Waiting for root device`. `CROS_VM_SCSI=0` exists only
for old amd64-generic images.

- SSH into the guest: `ssh -p 9222 root@localhost`, password `test0000`.
- Stop: close the window or Ctrl-C.
- Window too big/small: `CROS_DISPLAY=1920x1200 CROS_SCALE=1 ./run-crosvm.sh …`
  sets the framebuffer size in pixels. `CROS_SCALE` adjusts desktop
  scaling but only works under Wayland; on X11 only `CROS_DISPLAY`
  has an effect.
- Start over from a clean system: delete `chromiumos/.vm/0/disk.qcow2`.

The image file is never modified — each run boots a copy-on-write overlay on
top of it.

## Several VMs at once

```bash
tools/vm-instance.sh alloc mytest    # prints the instance id + ports
CROS_VM_IMAGE=$PWD/chromiumos/colorburst.bin tools/vm-instance.sh boot <id>
tools/vm-instance.sh ssh <id> 'uptime'
tools/vm-instance.sh release <id>    # kill + wipe; next alloc starts pristine
```

Each instance gets its own overlay, ports (SSH `9222+id`, VNC `5900+id`), and
network namespace — so the TAP device and the guest's `192.168.77.2` are
identical inside every instance. RAM is the limit, not disk: ~4 GB per extra
instance.

## If something goes wrong

| Symptom | Fix |
|---|---|
| `error: image not found` | The image must live under `chromiumos/` inside the repo |
| `found the disk image but not its kernel` | Put `vmlinuz` next to the `.bin`, or a `boot_images/` directory beside it |
| Boot hangs at `Waiting for root device` | The disk was attached as virtio-blk. Do not set `CROS_VM_SCSI=0` for colorburst images |
| Black window after the boot splash | Wait 30 s first. If it stays black, the image was built without the virgl driver — see the last section of [README.md](README.md) |
| `/dev/kvm` missing | Enable virtualization (VT-x / AMD-V) in your BIOS |
| Docker permission denied | You didn't re-login after `usermod -aG docker` |
| Permission denied on source tree inside container | Your host UID is not 1000 — rebuild with `docker build --build-arg HOST_UID=$(id -u) ...` |
| `failed to connect to compositor` / no window | You're on X11, not Wayland — update to the version of `run-crosvm.sh` that auto-detects the display server |
| Very slow / choppy VM display | Install `nvidia-container-toolkit` and restart Docker (see step 1) for GPU-accelerated rendering |
| Mouse and keyboard don't work in the VM | The kernel needs `CONFIG_VIRTIO_INPUT=y` — see the build guide for the kernel config patch |
