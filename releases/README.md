# Releases: versioning and branches

## The rule

**A version identifies source, not a moment.** Rebuilding a given commit must
produce the same version string — otherwise a shipped release cannot be
reproduced, and "which build is on that device?" has no answer.

The version lives in exactly one file:

```
chromiumos/src/overlays/overlay-colorburst/chromeos-base/chromeos-bsp-colorburst/files/RELEASE
```

It holds the whole string (`2026.32.9`). The BSP ebuild stamps it into
`/etc/os-release`, and `chromium/common.sh:release_version()` hands the same
string to every build script. Only `release/cut.sh` changes it.

> **How it used to work, and why it changed.** Through 2026.32.9 the version
> was computed at *build* time as `<year>.<ISO week ÷ 4 × 4>.<minor>` — from
> `date`, in five separate places. 2026.32.9 was cut in week 34 (34÷4×4 = 32).
> The same commits rebuilt in week 37 would have produced `2026.36.9`: a
> different version, baked into os-release, the image name, the OTA payload and
> releases.json, from byte-identical source. Reproducing a shipped release was
> impossible by construction. Fixed 2026-08-21; .9 is the last clock-derived
> version and its record below was reconstructed from the intact build tree.

## Shape: `<year>.<series>.<patch>`

| field | meaning |
|---|---|
| `year` | the year the series opened |
| `series` | the development cycle — the ISO week it opened. Chosen deliberately when you open a cycle, never recomputed |
| `patch` | +1 for every **shipped** build in the series. Never reused, never reset except by a new series |

```bash
release/cut.sh patch        # 2026.32.9 -> 2026.32.10
release/cut.sh series       # -> 2026.<this ISO week>.0
release/cut.sh 2026.40.0    # explicit
```

## What a release is

Each shipped version gets a directory here:

```
releases/<version>/
  manifest.xml    repo manifest -r — every project at an exact SHA
  RELEASE.json    chromium-os commit, Chromium base, fork SHAs,
                  artifact hashes, signing key
```

`manifest.xml` is the load-bearing piece. `local_manifests/colorburst.xml`
resolves board-overlays and crosvm by **branch tip**, so without this snapshot
the fork state of an old release is unrecoverable. The snapshot pins all ~287
projects, forks included.

To rebuild a past release: check out the recorded chromium-os commit,
`repo init -m` that `manifest.xml`, `repo sync`, then
`chromium/rebuild-release.sh`. The version comes from the tree, so it will
match.

## Branches

```
main ──●──●──●──●──●    canary (every cut), dev (smoke-tested)
        \
stable   ●─────────●    beta (release candidate), stable (promoted)
```

- **`main`** — development. Everything lands here first.
- **`stable`** — only ever fast-forwards to a commit that has shipped to the
  stable channel. It is what devices on stable are running.

Promotion is a fast-forward of `stable` to the commit you're promoting, then
`release/tag.sh`. A hotfix while `main` has moved on: branch from `stable`,
land the fix, ship it as the next patch, merge back into `main`.

Per-series branches (`release-2026.32`) only become necessary when two stable
series must be supported at once. Not yet.

## Cutting a release

```bash
release/cut.sh patch                       # bump + snapshot the manifest
git add -A && git commit -m "Cut <version>"
git -C chromiumos/src/overlays commit -am "Cut <version>"
release/cut.sh record                      # BUILD-ID = the cut commit
chromium/rebuild-release.sh                # builds exactly this version
release/sign-on-yubikey.sh chromiumos/ota-release/<version>
release/publish.sh chromiumos/ota-release/<version>
release/publish-dlc-images.sh
release/tag.sh <version>                   # records artifact hashes, tags repos
```

Tags (`v<version>`) go in chromium-os, board-overlays and crosvm. They are a
convenience — `manifest.xml` already pins everything — but they give you a name
to check out in the repos you actually edit.

## Released versions

| Version | Date | Channels | Notes |
|---|---|---|---|
| 2026.32.9 | 2026-08-20 | all | Crostini fixed (DLCs served from our CDN); "AI in Chrome" and "You and Google" removed; VNI + VIQR through UniKey. Last clock-derived version. |
