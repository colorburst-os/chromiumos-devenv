#!/usr/bin/env bash
# Fetch just enough source to build crosvm, without the 176 GB repo checkout:
# our crosvm fork plus its two out-of-repo dependencies (minigbm, minijail),
# cloned into the same paths a full checkout would put them, so the build
# recipe in RUNNING-VM.md works identically either way.
#
# minigbm/minijail are pinned to the SHAs from pinned-manifest.xml (the last
# known-good full checkout); crosvm tracks our fork's branch.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$DIR/chromiumos/src/platform"
mkdir -p "$P"

CROSVM_URL=https://github.com/colorburst-os/crosvm.git
CROSVM_REF=colorburst/gpu-display
MINIGBM_URL=https://chromium.googlesource.com/chromiumos/platform/minigbm
MINIGBM_SHA=197e0484b4ebc6e620925102915d2523de5175c1
MINIJAIL_URL=https://chromium.googlesource.com/chromiumos/platform/minijail
MINIJAIL_SHA=7ff2854bf077e4bba4cc1555794345e78ba0c460

if [ ! -e "$P/crosvm/.git" ]; then
    git clone --depth 1 -b "$CROSVM_REF" "$CROSVM_URL" "$P/crosvm"
else
    echo ">>> crosvm already present, leaving as is"
fi

fetch_pinned() { # url sha dest
    if [ -e "$3/.git" ]; then echo ">>> $3 already present, leaving as is"; return; fi
    git init -q "$3"
    git -C "$3" fetch -q --depth 1 "$1" "$2"
    git -C "$3" checkout -q FETCH_HEAD
}
fetch_pinned "$MINIGBM_URL"  "$MINIGBM_SHA"  "$P/minigbm"
fetch_pinned "$MINIJAIL_URL" "$MINIJAIL_SHA" "$P/minijail"

# The repo checkout ships third_party/minijail as an empty stub; point it at
# the real clone (relative, so it works from any mount point).
ln -sfn ../../minijail "$P/crosvm/third_party/minijail"

echo ">>> done: crosvm sources ready under chromiumos/src/platform/"
echo ">>> next: the one-time build in RUNNING-VM.md step 3"
