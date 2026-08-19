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

You need roughly 10 GB of RAM free while a VM runs (the guest gets 8 GB)
and a Wayland or X11 desktop session for the VM window.

## 2. Get the repo and an image

```bash
git clone https://github.com/colorburst-os/chromiumos-devenv.git
cd chromiumos-devenv
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

```bash
docker build -t cros-crosvm docker/crosvm
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

## 4. Run it

```bash
CROS_VM_SCSI=1 ./run-crosvm.sh chromiumos/colorburst.bin
```

A window opens; after ~60 seconds you're at the colorburst setup screen.
`CROS_VM_SCSI=1` is required for colorburst images (their kernel takes
its disk over virtio-scsi).

- SSH into the guest: `ssh -p 9222 root@localhost`, password `test0000`.
- Stop: close the window or Ctrl-C.
- Window too big/small: `CROS_DISPLAY=1920x1200 CROS_SCALE=1 ...`
  (framebuffer size and desktop scaling).

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
