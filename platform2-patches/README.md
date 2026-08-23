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
- **update-engine-dlc-url-0001.patch** — force-OTA DLCs (Crostini's termina)
  bypass Omaha entirely: `InstallAction` fetches a raw `dlc.img` from a
  hardcoded CDN and verifies it against the on-device imageloader manifest
  hash. That CDN is Google's. Point it at `dl.colorburst.net` so "Install
  Linux" works on a de-Googled image. See `release/DLC-RELEASE.md`.
- **regions-drop-vi-tcvn-0001.patch** — removes `m17n:vi_tcvn` from the `vn`
  region's input methods. colorburst's Chrome drops TCVN from
  `m17n_manifest.json`, so no descriptor exists for that id; OOBE walks the
  region's list and hits a `NOTREACHED()` on the null descriptor, which is
  fatal in current Chromium. This is what crash-looped OOBE on 2026.32.9.
- **login-manager-oem-region-0001.patch** — session_manager reads
  `/usr/share/oem/colorburst.txt` from the OEM partition and passes
  `--cros-region` to Chrome, defaulting to `us`. This is what makes one build
  serve every variant: the OEM partition (#8) carries no verity and no
  signature, so a variant is made by rewriting a few hundred bytes of an
  already-built image (`release/make-variant.sh`), and it is the only partition
  that survives install, OTA and powerwash alike — so a device keeps the
  personality of the stick it was installed from.

  The parser (`colorburst_config.{h,cc}`) is its own component because this
  file is where behaviour beyond language will land. It is `key=value`, and it
  is deliberately forgiving: the partition is FAT and the intended editor is
  Notepad on Windows, so CRLF, a UTF-8 BOM, `;` comments, quotes and any
  capitalisation all work. A line that will not parse is skipped and a value
  that fails validation falls back to that setting's default — a device that
  will not boot is far worse than one in the wrong language. Values are still
  validated hard before reaching Chrome's command line, because anyone holding
  the disk can now write that partition.
