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

# Plain \`gclient runhooks\` is a state-cached no-op here: it tracks which hooks
# already ran and silently skips them, producing NO output and leaving the
# generated files below absent. Only --force actually re-runs every hook and
# regenerates tast_control.gni, LASTCHANGE, etc. Without it fetch.sh exits 0
# on a tree that cannot build Chrome, and the failure only surfaces hours
# later inside a package build. So force the hooks, then VERIFY.
gclient runhooks --force

# Assert the build inputs a bare gclient sync/runhooks is supposed to create
# actually exist. Each of these was, in a real run, silently missing after a
# clean exit-0 fetch and blocked the Chrome build:
#   * buildtools/linux64/gn         -- CIPD-fetched; chrome-icu configure needs it
#   * chromeos/tast_control.gni     -- runhook tast_control.py; chromeos/BUILD.gn
#   * build/util/LASTCHANGE         -- runhook lastchange.py; build/timestamp.gni
missing=
for f in src/buildtools/linux64/gn src/chromeos/tast_control.gni src/build/util/LASTCHANGE; do
  [ -e \"/chromium/\$f\" ] || missing=\"\$missing \$f\"
done
if [ -n \"\$missing\" ]; then
  echo \"FATAL: fetch produced a tree missing build inputs:\$missing\" >&2
  echo \"       (gclient runhooks --force did not create them; the tree is NOT buildable)\" >&2
  exit 1
fi
echo 'fetch.sh: Chrome tree verified buildable (gn + tast_control.gni + LASTCHANGE present)'
"
