#!/bin/bash
# Vendor the bamboo-core oracle (Go, MIT) next to main.go so the regression
# harness is reproducible. Bamboo is a *correctness reference only*: it runs
# HOST-SIDE, never in-process (its Go runtime's clone() flags trip Chromium's
# seccomp allow-list -- see VIETNAMESE-ENGINE.md 2.5). We diff the on-device
# UnikeyEngine output against it.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/bamboo-core"
REV="${BAMBOO_REV:-master}"
if [ -d "$DEST/.git" ]; then
  echo "bamboo-core already vendored at $DEST"; exit 0
fi
git clone --depth 1 -b "$REV" https://github.com/BambooEngine/bamboo-core "$DEST"
rm -rf "$DEST/.git"
echo "vendored bamboo-core at $DEST"
