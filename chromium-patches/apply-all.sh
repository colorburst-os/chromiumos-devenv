#!/bin/bash
# Apply colorburst's ENTIRE Chromium patch series to a fresh Chromium checkout,
# in one step, in the maintainer's authoritative order, leaving a clean tree
# whose result is byte-for-byte identical to the shipped colorburst Chrome.
#
#   Usage: chromium-patches/apply-all.sh /path/to/chromium/src
#
# The <chromium-src> must be a clean git checkout at the pinned base revision
# (831a446cd4). Each step commits, so the tree is never dirty for the next
# `git am` / `patch`.
#
# Order is derived from the maintainer's commit history
# (`git log 831a446cd4..colorburst-local-account`). Three patches need special
# handling; see the inline notes at their call sites:
#   * local-account-ui-0003 : `git am` cannot build the fake ancestor (its
#     pre-image blobs come from -0001), so it is applied with `patch --forward`.
#   * telex-phase0           : the Vietnamese rule-table edits it once carried
#     are ALREADY baked into rulebased-payload/, so the exported -0001 keeps
#     only its two new code hunks and the redundant -0002 was dropped entirely.
set -euo pipefail

SRC="${1:?usage: apply-all.sh <chromium-src>}"
SRC="$(cd "$SRC" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
test -f "$SRC/chromeos/ash/services/ime/ime_service.cc"

export GIT_AUTHOR_NAME="Lưu Oa Oa"
export GIT_AUTHOR_EMAIL="212658678+luuoaoa@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

cd "$SRC"

# git-am a mailbox-format patch (preserves the maintainer's author/message).
am() { git am "$HERE/$1"; }
# patch -p1 --forward for the -urN / non-am patches, then snapshot as a commit.
pp() { patch -p1 --forward < "$HERE/$1"; git add -A && git commit -q -m "$2"; }
# snapshot the working tree as a commit (used after a payload drop-in).
snap() { git add -A && git commit -q -m "$1"; }

# 1. Local device account + OOBE entry point.
am local-account-ui-0001.patch
am local-account-ui-0002.patch

# 2. Restore Chromium's in-process rule-based IME engine (payload + wiring).
#    NOTE: rulebased-payload/ is snapshotted AFTER the Telex phase-0 work, so its
#    vi_telex.cc / vi_vni.cc already carry the phase-0 tables (see step 6).
"$HERE/apply-rulebased.sh" "$SRC"
snap "ChromeOS: restore the in-process rule-based IME engine"

# 3. Branding.
am branding-0001.patch

# 4. Recommend Telex, not TCVN.
am telex-default-0001.patch

# 5. Telex phase 0 (code hunks only; the rule-table edits are in the payload).
am telex-phase0-0001.patch
# telex-phase0-0002 (bare w -> u-horn removal) intentionally omitted: its whole
# effect is already present in rulebased-payload/def/vi_telex.cc.

# 6. De-Google + start page + local-account polish (maintainer commit order).
am degoogle-0001-gemini.patch
am degoogle-0002-mirror.patch
am startpage-0001.patch
am degoogle-0003-discover.patch
am localaccount-vi-strings.patch
am degoogle-0004-no-enroll.patch
am degoogle-0005-translate-no-autopop.patch
am localaccount-official-defaults.patch
# Vietnamese locale defaults (independent single-file edits; no other patch
# touches components_locale_settings_vi.xtb or spellcheck_factory.cc, so their
# position here is not load-bearing):
#   * drop French from the default Accept-Language list (vi,en-US,en).
#   * enable the en-US Hunspell dictionary alongside vi so English words are not
#     wrongly flagged as misspelled in a Vietnamese-primary session.
am localaccount-accept-languages-no-fr.patch
am spellcheck-enable-en-us.patch
am branding-0002-install-colorburst.patch

# 7. Atomic password factor. `git am` fails ("could not build fake ancestor" -
#    its pre-image blobs come from local-account-ui-0001); patch --forward is
#    clean and deterministic.
pp local-account-ui-0003-atomic-password-factor.patch \
   "Local accounts: create the password factor with the user, openFyde-style"

# 8. Gallery viewer; Apps & games removed.
am apps-0001-gallery-viewer-and-no-mall.patch

# 9. UniKey Vietnamese engine: vendor payload, then wire + route it, in the
#    maintainer's interleaved order (payload snapshotted at the mojo-adapter
#    state; the later Telex patches edit unikey_engine.cc on top).
cp -r "$HERE/unikey-payload/." "$SRC/"
snap "[PoC] Vendor LGPL ukengine and prove it host-side (Vietnamese IME)"
am ime-unikey-0001-mojo-adapter.patch
am ime-routing-0000-poc-probe.patch
am ime-routing-0001-m17n-native.patch
am telex-settings-0001.patch
am branding-0003-guest-tos.patch
am ime-orca-crash-0001.patch
am telex-w-toggle-0001.patch
# UI twin of telex-settings-0001: let os-settings render the Vietnamese options
# page for the unbranded m17n extension id (vkd_vi_* under kM17nExtensionId), so
# the Telex/VNI toggles are actually reachable in Settings. Touches only
# input_method_util.ts, which no other patch edits, so its position is not
# load-bearing.
am telex-settings-ui-0001-options-page.patch
# New "restore non-Vietnamese words" Telex/VNI toggle. The UnikeyEngine already
# restored the original keystrokes for invalid Vietnamese words unconditionally
# (spellCheckEnabled + autoNonVnRestore); this exposes it as an os-settings
# option plumbed through the mojom settings union, default on. Depends on the
# options page being reachable (telex-settings-ui-0001), so it follows it.
am telex-nonvn-restore-0001.patch
am ime-tcvn-0001-drop-option.patch

echo "OK. All colorburst patches applied. Now rebuild chrome (ash-chrome)."
