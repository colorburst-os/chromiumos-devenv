# platform2 patches

Un-upstreamed changes to first-party ChromeOS system code (platform2) that
colorburst carries but does not maintain as a fork repo. Apply them to a
platform2 checkout before building:

    ./apply.sh /path/to/chromiumos/src/platform2

The build then picks them up via `cros_workon start <pkg>` + emerge (see
chromium/build-image.sh and chromium/build-release.sh, which already start
workon for update_engine).

## Patches
- **update-engine-device-id-0001.patch** — `update_engine` adds
  `colorburst_device_id` to the Omaha update request, read once from
  `/var/lib/colorburst/device-id` (minted by the colorburst-device-id upstart
  job in the board overlay). Lets the update server tell installations apart
  for staged rollouts and honest fleet counts. Absent on USB/live boots.
