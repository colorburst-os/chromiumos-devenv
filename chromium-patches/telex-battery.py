#!/usr/bin/env python3
"""Regression battery for the Vietnamese Telex rule table.

Runs the table in rulebased-payload/ through the prototype engine and checks
each keystroke sequence against the text a Telex typist expects. Fast, no build,
no VM:

    python3 chromium-patches/telex-battery.py          # all groups
    python3 chromium-patches/telex-battery.py -v       # print every case

What this is NOT: proof that the shipped C++ behaves the same. The prototype
re-implements engine.cc on Python `re`, and Chromium uses RE2 -- see the caveat
at the top of telex-rules-prototype.py. Every sequence in the FIXED and
UNCHANGED groups below has also been typed on a VM through a real keyboard
device (VIETNAMESE-IME.md 9), which is what actually settles it; this file
exists so that a table edit can be checked in seconds rather than in an hour.

Exit status is 0 only if every case matches.
"""
import subprocess
import sys
import os
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import importlib.util
_spec = importlib.util.spec_from_file_location(
    "telexproto", os.path.join(HERE, "telex-rules-prototype.py"))
_proto = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_proto)


def type_word(seq, ime="vi_telex"):
    return unicodedata.normalize("NFC", _proto.type_word(ime, seq))


# (sequence, expected, note). Expected is what a fluent Telex typist means.
FIXED = [
    # Tone correction: retyping a tone replaces it (was: two marks on one vowel).
    ("hoafs",    "hóa",   "was hòá"),
    ("hoasf",    "hòa",   "was hóà"),
    ("hoafr",    "hỏa",   "was hòả"),
    ("hoafx",    "hõa",   "was hòã"),
    ("hoafj",    "họa",   "was hòạ"),
    ("nhafs",    "nhá",   "was nhàs"),
    ("hoirs",    "hói",   "was hỏís"),
    ("tieengsf", "tiềng", "was tiếngf"),
    # The w family can be escaped by double-typing, like dd/aa/ee/oo already could.
    ("uww",      "uw",    "was ưư"),
    ("aww",      "aw",    "was ăư"),
    ("oww",      "ow",    "was ơư"),
    # A bare w is a w again. uw/aw/ow still give the horned vowels.
    ("w",        "w",     "was ư"),
    ("we",       "we",    "was ưe"),
    ("W",        "W",     "was Ư"),
    ("www",      "www",   "was ưưư"),
    # "uo" + one w horns both vowels.
    ("nguowfi",  "người", "was nguời"),
    ("thuowngr", "thưởng", "was thuởng"),
    ("huowu",    "hươu",  "was huơu"),
    ("ruowuj",   "rượu",  "was ruợu"),
]

# Everything here worked before the table edit and must still work.
UNCHANGED = [
    ("tieengs",   "tiếng"),
    ("Vieejt",    "Việt"),
    ("ddaay",     "đây"),
    ("nguwowfi",  "người"),
    ("chuwx",     "chữ"),
    ("hocj",      "học"),
    ("toans",     "toán"),
    ("toasn",     "toán"),
    ("ddoongf",   "đồng"),
    ("ddoofng",   "đồng"),
    ("quaan",     "quân"),
    ("cheesch",   "chếch"),
    ("hoaf",      "hòa"),
    ("hoas",      "hóa"),
    ("giaf",      "già"),
    # Classic tone placement, which is what the table hardcodes (defect D1 in
    # VIETNAMESE-ENGINE.md). A modern-style typist would want "của".
    ("cuaf",      "cùa"),
    ("thuyr",     "thủy"),
    ("khoer",     "khỏe"),
    ("vieetj",    "việt"),
    ("hoafng",    "hoàng"),
    ("ddieeuf",   "điều"),
    ("ngayf",     "ngày"),
    ("khoangr",   "khoảng"),
    ("ddawngj",   "đặng"),
    ("tuooir",    "tuổi"),
    # Escapes that already worked -- the tone-correction rules must not eat these.
    ("ddd",       "dd"),
    ("aaa",       "aa"),
    ("eee",       "ee"),
    ("ooo",       "oo"),
    ("ass",       "as"),
    ("uw",        "ư"),
    ("aw",        "ă"),
    ("ow",        "ơ"),
    ("chuwx",     "chữ"),
    ("aff",       "af"),
    ("ajj",       "aj"),
    ("arr",       "ar"),
    ("axx",       "ax"),
]

# VNI got the same two fixes. It is not our default, so this is a smaller set.
VNI_FIXED = [
    ("hoa21",    "hóa",   "was hòá"),
    ("hoa12",    "hòa",   "was hóà"),
    ("hoa23",    "hỏa",   "was hòả"),
    ("nguo7i2",  "người", "was nguời"),
    ("thuo7ng3", "thưởng", "was thuởng"),
    ("huo7u",    "hươu",  "was huơu"),
    ("ruo7u5",   "rượu",  "was ruợu"),
]

VNI_UNCHANGED = [
    ("tie6ng1",  "tiếng"),
    ("vie65t",   "việt"),
    ("d9a6y",    "đây"),
    ("ho5c",     "học"),
    ("toa1n",    "toán"),
    ("d9o6ng2",  "đồng"),
    ("qua6n",    "quân"),
    ("o7",       "ơ"),
    ("u7",       "ư"),
]

# Known-bad. Recorded so that the day one of them starts passing, we notice --
# these are the defects that need a real engine, not a bigger table.
KNOWN_BAD = [
    ("congas",  "congas", "no non-Vietnamese restore"),
    ("windows", "windows", "no non-Vietnamese restore"),
    ("OS",      "OS",     "acronym destroyed"),
]


def main():
    verbose = "-v" in sys.argv
    failures = []

    for seq, want, note in FIXED:
        got = type_word(seq)
        ok = got == want
        if not ok:
            failures.append(("FIXED", seq, want, got, note))
        if verbose or not ok:
            print(f"  {'ok ' if ok else 'FAIL'} {seq:12s} -> {got:10s} want {want:10s}  ({note})")

    for seq, want in UNCHANGED:
        got = type_word(seq)
        ok = got == want
        if not ok:
            failures.append(("UNCHANGED", seq, want, got, "regression"))
        if verbose or not ok:
            print(f"  {'ok ' if ok else 'FAIL'} {seq:12s} -> {got:10s} want {want:10s}")

    for seq, want, note in VNI_FIXED:
        got = type_word(seq, "vi_vni")
        ok = got == want
        if not ok:
            failures.append(("VNI_FIXED", seq, want, got, note))
        if verbose or not ok:
            print(f"  {'ok ' if ok else 'FAIL'} vni {seq:12s} -> {got:10s} want {want:10s}  ({note})")

    for seq, want in VNI_UNCHANGED:
        got = type_word(seq, "vi_vni")
        ok = got == want
        if not ok:
            failures.append(("VNI_UNCHANGED", seq, want, got, "regression"))
        if verbose or not ok:
            print(f"  {'ok ' if ok else 'FAIL'} vni {seq:12s} -> {got:10s} want {want:10s}")

    still_bad = []
    for seq, want, note in KNOWN_BAD:
        got = type_word(seq)
        if got == want:
            still_bad.append((seq, note))
        if verbose:
            print(f"  known-bad {seq:10s} -> {got:10s} (want {want}, {note})")

    total = len(FIXED) + len(UNCHANGED) + len(VNI_FIXED) + len(VNI_UNCHANGED)
    print(f"\n{total} cases checked "
          f"({len(FIXED)}+{len(VNI_FIXED)} fixed, "
          f"{len(UNCHANGED)}+{len(VNI_UNCHANGED)} unchanged), "
          f"{len(failures)} failure(s)")
    for kind, seq, want, got, note in failures:
        print(f"  {kind}: {seq} -> {got!r}, wanted {want!r}  ({note})")
    for seq, note in still_bad:
        print(f"  NOTE: known-bad case {seq!r} now passes -- {note} may be fixed; "
              f"move it out of KNOWN_BAD")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
