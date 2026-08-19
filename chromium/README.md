# Building colorburst's Chrome

colorburst does not ship stock Chromium. Several things are patched into it, and
they are all user-visible:

| Patch | What it does | Doc |
|---|---|---|
| `local-account-ui-0001.patch`, `-0002.patch` | the OOBE screen that creates an account with no Google account behind it | [LOCAL-ACCOUNT-UI.md](../LOCAL-ACCOUNT-UI.md) |
| `0001-restore-rulebased-ime-engine.patch` + `rulebased-payload/` | Chromium's own rule-based IME engine, deleted upstream in M113, restored so Vietnamese Telex types without Google's closed decoder blob | [VIETNAMESE-IME.md](../VIETNAMESE-IME.md) |
| `apply-unikey.sh` (`unikey-payload/` + `ime-unikey-0001`, `ime-routing-0001`, `ime-tcvn-0001`) | the UniKey Vietnamese engine — word-level tone placement and non-Vietnamese-word restore — behind the mojo IME, with Vietnamese routed to it and legacy TCVN dropped | [VIETNAMESE-IME.md](../VIETNAMESE-IME.md) |
| `telex-default-0001.patch` | a Vietnamese profile defaults to Telex, not TCVN | [VIETNAMESE-IME.md §7](../VIETNAMESE-IME.md) |
| `branding-0001.patch` | Chromium → colorburst, Chromebook → computer, and the Google mark off the OOBE screens | [BRANDING.md §6](../BRANDING.md) |

The patches live in [`../chromium-patches/`](../chromium-patches/). They are the
artefact of record; the Chromium checkout itself is not in any repository,
because it is 30 GB and reconstructible.

## The tree

The checkout lives **outside** this repository, next to it by default:

```
~/develop/
  chromium-os/      <- this repo (contains chromiumos/, the ChromiumOS checkout)
  chromium-src/     <- Chromium, 30 GB, made by ./fetch.sh
    src/            <- the git checkout; apply patches here
```

Set `CHROME=/some/other/path` if you keep it elsewhere. Everything below runs
inside the same Docker container as the rest of the tooling — nothing is
installed on the host.

## From nothing to an image

```bash
chromium/fetch.sh                       # ~30 GB, ~10 min

cd "$CHROME/src"                        # apply our patches
git checkout -b colorburst
git am ../../chromium-os/chromium-patches/local-account-ui-000*.patch
../../chromium-os/chromium-patches/apply-rulebased.sh .     # payload + wiring
../../chromium-os/chromium-patches/apply-unikey.sh .        # UniKey engine (after rulebased)
git am ../../chromium-os/chromium-patches/telex-default-0001.patch
git am ../../chromium-os/chromium-patches/branding-0001.patch

cd -
chromium/build-image.sh                 # Chrome, BSP, image. 2-3 h cold
```

The image lands in
`chromiumos/src/build/images/amd64-generic/latest/chromiumos_test_image.bin`.

## The fast loop

A cold Chrome build is hours; iterating is not. Edit, then:

```bash
chromium/ninja.sh                       # 3-5 edges + link, ~2 min
chromium/deploy.sh 9222                 # onto a running VM instance
```

`ninja.sh` and the emerge in `build.sh` share one output tree
(`/var/cache/chromeos-chrome/...` in the chroot), so a `ninja.sh` run leaves the
next `build-image.sh` almost nothing to compile. That is why a resource-only
change — a string, an icon — costs minutes rather than a rebuild.

## Two traps that have cost real time

1. **Never run plain `cros build-packages` after building Chrome locally.** It
   passes `--force-remote-binary=chromeos-base/chromeos-chrome` and silently
   replaces the build with the binhost's, patches and codecs and all. Use
   `build-image.sh`, which emerges Chrome explicitly and then builds the image.
2. **The board sysroot persists between builds.** An ebuild edit that is not
   accompanied by a version bump, or a package that is not re-merged, does not
   reach the image — and the build succeeds, so nothing tells you.
