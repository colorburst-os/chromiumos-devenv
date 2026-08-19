# Building colorburst's Chrome

colorburst does not ship stock Chromium. About twenty patches are applied on top
of a pinned base revision (`831a446cd4`), and they are all user-visible.

**Do not apply them by hand.** The series has ordering dependencies, two payload
drop-ins that must be committed before the next patch, and three patches that
need non-`git am` handling (see below). One script,
[`chromium-patches/apply-all.sh`](../chromium-patches/apply-all.sh), applies the
**entire** series in the maintainer's authoritative order and leaves a clean,
committed tree that is byte-for-byte identical to the shipped colorburst Chrome:

```bash
chromium-patches/apply-all.sh "$CHROME/src"
```

The full series, in the order `apply-all.sh` applies it:

| # | Patch / payload | What it does |
|---|---|---|
| 1–2 | `local-account-ui-0001.patch`, `-0002.patch` | the OOBE screen that creates an account with no Google account behind it (LOCAL-ACCOUNT-UI.md†) |
| 3 | `apply-rulebased.sh` (`rulebased-payload/` + `0001-restore-rulebased-ime-engine.patch`) | restores Chromium's rule-based IME engine, deleted upstream in M113, so Vietnamese Telex types without Google's closed decoder blob (VIETNAMESE-IME.md†) |
| 4 | `branding-0001.patch` | Chromium → colorburst, Chromebook → computer, Google mark off the OOBE screens (BRANDING.md §6†) |
| 5 | `telex-default-0001.patch` | a Vietnamese profile defaults to Telex, not TCVN (VIETNAMESE-IME.md §7†) |
| 6 | `telex-phase0-0001.patch` | Telex phase-0 code changes (no underline on Vietnamese composition). **Code hunks only** — see the phase-0 note below |
| 7 | `degoogle-0001-gemini.patch` | removes every Gemini surface a local-account user can reach |
| 8 | `degoogle-0002-mirror.patch` | disables Mirror account consistency; Google sites sign in as plain web |
| 9 | `startpage-0001.patch` | fresh profiles open `https://start.colorburst.net` on session start |
| 10 | `degoogle-0003-discover.patch` | removes the Discover (help) app and the Welcome Tour |
| 11 | `localaccount-vi-strings.patch` | Vietnamese translations for the local-account OOBE strings |
| 12 | `degoogle-0004-no-enroll.patch` | hides the "for work" card on the user-creation screen |
| 13 | `localaccount-official-defaults.patch` | bakes the Gaia-less local-account defaults into ash-chrome |
| 14 | `branding-0002-install-colorburst.patch` | OOBE shelf: Install colorburst, not ChromeOS Flex |
| 15 | `local-account-ui-0003-atomic-password-factor.patch` | creates the password factor with the user, openFyde-style. Applied with `patch --forward` — see below |
| 16 | `apps-0001-gallery-viewer-and-no-mall.patch` | a real Gallery viewer; Apps & games removed |
| 17 | `unikey-payload/` (vendored LGPL ukengine) | the UniKey Vietnamese engine core, host-proven (VIETNAMESE-IME.md†) |
| 18 | `ime-unikey-0001-mojo-adapter.patch` | wires ukengine behind `mojom::InputMethod` for Vietnamese Telex |
| 19 | `ime-routing-0000-poc-probe.patch` | PoC routing probe on the native-engine observer |
| 20 | `ime-routing-0001-m17n-native.patch` | routes the m17n IME extension to the native mojo engine (step 0) |
| 21 | `telex-settings-0001.patch` | delivers Telex settings live on the mojo rule-based path |
| 22 | `branding-0003-guest-tos.patch` | Guest ToS: the usage-data toggle names colorburst, not Google |
| 23 | `ime-orca-crash-0001.patch` | fixes a browser SIGSEGV when activating a `vkd_*` IME (Orca service removed) |
| 24 | `telex-w-toggle-0001.patch` | makes the standalone-`w` → `ư` shortcut a real toggle, default off |
| 25 | `ime-tcvn-0001-drop-option.patch` | drops TCVN as a Vietnamese input option |

† Names marked with a dagger (LOCAL-ACCOUNT-UI.md, VIETNAMESE-IME.md,
BRANDING.md) are **internal design notes that are not shipped in this release**.
They are referenced for provenance only; the patches themselves are the artefact
of record and are self-contained. Do not expect those files to exist.

Three patches need special handling; `apply-all.sh` does it for you, but if you
ever apply anything by hand, know that:

- **`local-account-ui-0003`** cannot be applied with `git am` ("could not build
  fake ancestor" — its pre-image blobs come from `-0001`). It applies cleanly and
  deterministically with `patch -p1 --forward`.
- **Telex phase 0 lives partly in the payload.** `rulebased-payload/` is
  snapshotted *after* the phase-0 work, so its `def/vi_telex.cc` and
  `def/vi_vni.cc` already carry the phase-0 rule tables. Re-applying those table
  edits corrupts the tree and crash-loops OOBE. The exported
  `telex-phase0-0001.patch` therefore keeps only its two *new* code hunks
  (`input_method_engine.cc`, `rule_based_engine.cc`); the old
  `telex-phase0-0002.patch` (bare `w` → `ư` table removal) was fully redundant
  with the payload and has been removed.
- After each payload drop-in (`apply-rulebased.sh`, `unikey-payload/`),
  `apply-all.sh` commits, so the tree is never dirty for the next `git am`.

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
chromium/fetch.sh                       # ~30 GB, ~10 min; verifies the tree builds

# Apply the WHOLE patch series, in order. apply-all.sh takes the Chrome src
# tree as an argument, so it works from anywhere -- no assumed sibling layout.
git -C "$CHROME/src" checkout -b colorburst 831a446cd4   # the pinned base revision
chromium-patches/apply-all.sh "$CHROME/src"

# Bootstrap the board sysroot ONCE per ChromiumOS checkout (setup_board + a
# COMPLETE build-packages). build-image.sh does NOT do this and dies at the
# image step without it. The first cros_sdk call here also creates the SDK
# chroot, so the first run is slow (hours).
chromium/bootstrap-board.sh

chromium/build-image.sh                 # Chrome, BSP, image. 2-3 h cold
```

(Run these from this repo's root; `$CHROME` defaults to `../chromium-src` — see
`common.sh`. Only `apply-all.sh` needs the Chrome tree path.)

`apply-all.sh` is the only supported way to apply the series. It replaces the old
hand-run recipe (`git am local-account-ui-000*.patch`, then `apply-rulebased.sh`,
then `apply-unikey.sh`, …), which silently omitted most of the patches, applied
them out of order, left the tree dirty between steps, and double-applied the
Telex rule tables — producing a Chrome that crash-loops at OOBE.

The image lands in
`chromiumos/src/build/images/colorburst/latest/chromiumos_test_image.bin`
(also hardlinked as `colorburst-<version>.bin`).

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
