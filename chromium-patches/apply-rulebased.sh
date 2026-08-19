#!/bin/bash
# Restores Chromium's deleted in-process rule-based IME engine (Vietnamese
# Telex/VNI/VIQR/TCVN, Arabic, Thai, Devanagari, ...) so that the "vkd_*" input
# methods work without Google's closed /usr/lib64/libimedecoder.so.
#
# Usage: ./apply-rulebased.sh /path/to/chromium/src
set -euo pipefail
SRC="${1:?usage: apply-rulebased.sh <chromium-src>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
test -f "$SRC/chromeos/ash/services/ime/ime_service.cc"

# 1. Drop in the recovered source files (from tag 113.0.5672.63, verbatim except
#    rules_data.cc - BSD-licensed Chromium code, see VIETNAMESE-IME.md 6.1).
cp -r "$HERE/rulebased-payload/." "$SRC/"

# 2. Wire them up (BUILD.gn, ime_service, engine-id normalisation).
cd "$SRC"
patch -p1 --forward < "$HERE/0001-restore-rulebased-ime-engine.patch"
echo "OK. Now rebuild chrome (ash-chrome)."
