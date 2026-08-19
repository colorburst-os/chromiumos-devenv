#!/bin/bash
# Make the Chromium checkout the rest of these scripts build.
#
#   ./fetch.sh            # ~30 GB, ~10 min on a fast link
#
# Pinned to the revision our patches apply to. A blobless clone (--filter=blob:none)
# looks cheaper and is a trap here -- it cost ~38 h in a previous attempt because
# every hook fetches blobs one at a time. --depth=1 at the SHA is the fast path.
set -eu
. "$(dirname "$0")/common.sh"

REV="${REV:-831a446cd4ccd3f2738e0f622093d7f7eed7b4f7}"   # r153, 153.0.7981.0

mkdir -p "$CHROME"
[ -d "$CHROME/.gclient" ] || cat > "$CHROME/.gclient" <<GCLIENT
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {"checkout_android": False},
  },
]
target_os = ["chromeos"]
GCLIENT

in_container chromium-fetch "
set -x
cd /chromium || exit 1
if [ ! -d src/.git ]; then
  mkdir -p src && cd src && git init -q .
  git remote add origin https://chromium.googlesource.com/chromium/src.git
  git fetch --depth=1 --progress origin '$REV' ||
    git fetch --depth=1 --progress origin refs/tags/153.0.7981.0
  git checkout --detach FETCH_HEAD
fi
cd /chromium
gclient sync --nohooks --no-history --delete_unversioned_trees -j8
gclient runhooks
"
