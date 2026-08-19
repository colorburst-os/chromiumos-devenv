#!/bin/bash
# Adds the UniKey Vietnamese input engine (ukengine) and routes the Vietnamese
# Telex layout to it, replacing the stateless rule-based transliterator with a
# real linguistic state machine (word-level tone placement, non-Vietnamese-word
# restore). This is colorburst's headline IME feature.
#
# Depends on apply-rulebased.sh having run first: the UniKey engine plugs into
# the restored rule-based mojo path (it edits that engine's BUILD.gn and
# rule_based_engine_connection_factory.{cc,h}, which apply-rulebased.sh drops in).
#
# Usage: ./apply-unikey.sh /path/to/chromium/src   (run AFTER apply-rulebased.sh)
set -euo pipefail
SRC="${1:?usage: apply-unikey.sh <chromium-src> (after apply-rulebased.sh)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
test -f "$SRC/chromeos/ash/services/ime/rule_based_engine_connection_factory.cc" || {
  echo "rule-based engine not present -- run apply-rulebased.sh first" >&2
  exit 1
}

# 1. Drop in the source additions:
#      third_party/unikey/                      the vendored LGPL engine core +
#                                               clean-room charset shim + tables
#      chromeos/ash/services/ime/unikey_engine.* the mojom::InputMethod adapter
#    (README.chromium documents the LGPL/GPL severance; keep it intact.)
cp -r "$HERE/unikey-payload/." "$SRC/"

# 2. Wire it up and route Vietnamese to it.
cd "$SRC"
patch -p1 --forward < "$HERE/ime-unikey-0001-mojo-adapter.patch"
patch -p1 --forward < "$HERE/ime-routing-0001-m17n-native.patch"
patch -p1 --forward < "$HERE/ime-tcvn-0001-drop-option.patch"
echo "OK. Now rebuild chrome (ash-chrome)."
