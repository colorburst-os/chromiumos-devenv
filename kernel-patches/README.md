# kernel patches

Un-upstreamed changes to first-party ChromeOS kernel config that colorburst
carries but does not maintain as a fork repo. Apply them to a kernel checkout
before building:

    ./apply.sh /path/to/chromiumos/src/third_party/kernel/v6.12

The build then picks them up via `cros_workon start <pkg>` + emerge (see
chromium/build-image.sh and chromium/build-release.sh, which already start
workon for update_engine and regions the same way).

## Patches
- **reven-virtio-input-0001.patch** — sets `CONFIG_VIRTIO_INPUT=m` in the
  `chromeos-x86_64-reven` flavour config. `CONFIG_VIRTIO_INPUT` was absent
  from `base.config`, the x86_64 `common.config`, and the reven flavour
  config alike, so Kconfig's default (`n`) left the driver compiled out
  entirely. crosvm's `--display-window-keyboard`/`--display-window-mouse`
  deliver guest input over virtio-input (`drivers/virtio/virtio_input.c`),
  so without this, every VM built on the colorburst/reven kernel booted
  with a dead mouse and keyboard even though crosvm was sending the events
  correctly. Built as a module (`=m`), matching the style of its virtio
  siblings a few lines down (`VIRTIO_BLK=m`, `VIRTIO_NET=m`) — loaded by
  udev after root mounts, same as `virtio_blk` already is despite the
  `noinitrd` direct-kernel boot `run-crosvm.sh` uses.
