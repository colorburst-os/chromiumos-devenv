# Serving Crostini's DLCs on colorburst

`termina-dlc`, `termina-tools-dlc` and `edk2-ovmf-dlc` are the three DLCs
Crostini needs. They are `force-ota` and non-scaled: on a release/OTA device
they are neither preloaded nor factory-installed, so dlcservice asks
update_engine to fetch them on demand.

## How the fetch actually works (and why the old approach was wrong)

For these DLCs, update_engine does **not** use our Omaha server. `dlcservice`
→ `update_engine` → **`InstallAction`**, which downloads the raw `dlc.img` over
HTTPS from a **hardcoded CDN** and verifies it against the on-device
imageloader manifest's `image-sha256-hash`. Stock ChromeOS hardcodes Google's
CDN (`edgedl.me.gvt1.com`, `dl.google.com`). Our own `edk2-ovmf-dlc` is not on
Google's CDN, so it 404s and Crostini install fails right after termina
downloads — the exact symptom seen on the ThinkPad.

An earlier iteration tried to serve these as DLC-over-Omaha payloads
(`gen-dlc-payloads.sh`, `sign-dlc-on-yubikey.sh`, `publish-dlcs.sh`, and an
`appDlcUpdate` path in `update-server/worker.js`). **That approach was wrong**
for these three DLCs: force-ota DLCs bypass Omaha entirely, so the Omaha
manifest we returned was never consulted for the install. The scripts, the
worker branch, the `dlcs` key in `releases.json`, and the `dlcs/` R2 payloads
have all been removed (they live on in git history if a scaled-DLC ever needs
the pattern).

## The fix in place

`platform2-patches/update-engine-dlc-url-0001.patch` redirects `InstallAction`'s
four CDN constants to `https://dl.colorburst.net/dlc`. The object URL it then
requests for a force-ota DLC is (confirmed empirically from `update_engine.log`):

```
https://dl.colorburst.net/dlc / <builder_path> / <slotting> / <id> / package / dlc.img
                                (empty)          (= "dlc")
= https://dl.colorburst.net/dlc/dlc/<id>/package/dlc.img
```

- `builder_path` = `CHROMEOS_RELEASE_BUILDER_PATH`, empty on colorburst.
- `slotting` = `dlc` for force-ota (`kForceOTASlotting`); `dlc-scaled` otherwise.

`dl.colorburst.net` is the `colorburst-updates` R2 bucket's own custom domain,
served directly with no path rewrite — so we host each image at the R2 key
`dlc/dlc/<id>/package/dlc.img`.

**No signing.** InstallAction verifies the bytes against the manifest
`image-sha256-hash` baked into the (signed) OS rootfs, not against a payload
signature. The object we host must be the exact `dlc.img` whose sha256 is in
that manifest.

## Publishing (per release)

After a clean board build (the sysroot holds the freshly built DLC images and
their manifests):

```bash
cd ~/develop/colorburst-os/chromium-os
release/publish-dlc-images.sh          # reads dlc.img + imageloader.json from
                                       # out/build/colorburst, verifies sha256,
                                       # uploads to R2, re-verifies over HTTPS
```

The script refuses to upload on any image↔manifest hash mismatch and verifies
each object over the public domain afterwards. That is the whole runbook — no
YubiKey, no `wrangler deploy`.

## Sharp edge: the CDN path has no version

Because `builder_path` is empty, the URL is the same for every OS version. That
is safe only while the DLC content is identical across the OS versions in the
field. If a future release ships a **different** `dlc.img` (new hash in its
manifest), overwriting the R2 object would break DLC install for devices still
on the older OS — their manifest expects the old hash. `termina`/`edk2` change
rarely; when they do, re-run `publish-dlc-images.sh` and roll every channel
forward to that build together.

If we ever need to ship diverging DLC content per channel simultaneously, set
`CHROMEOS_RELEASE_BUILDER_PATH` in the image so the URL carries a version, and
host per-version under that path.

## Verifying end-to-end

On a device or a test-image VM running a build with the redirect patch:

```bash
dlcservice_util --install --id=edk2-ovmf-dlc      # then termina-dlc, termina-tools-dlc
grep -E "Starting installation using URL|Transferred bytes hash|is valid" \
    /var/log/update_engine.log
```

You should see the URL on `dl.colorburst.net`, a successful transfer, and
`Transferred bytes hash (...) is valid` — after which Crostini can launch.
