#!/usr/bin/env python3
"""Standalone Python port of Chromium's deleted `rulebased` IME engine, used to
prove that the recovered Vietnamese Telex/VNI tables actually transliterate.

It reads the *recovered C++ table* verbatim
(rulebased-payload/chromeos/ash/services/ime/public/cpp/rulebased/def/vi_*.cc)
and re-implements engine.cc + rules_data.cc's Transform / PredictTransform /
history-prune state machine on top of Python's `re`.

Caveat: Chromium uses RE2. Python `re` backtracks, and the merged-alternation
"which rule matched" logic is emulated by trying rules in declaration order.
For these tables the two agree on every case tested below, but this file is a
*validation prototype*, not the shipping implementation. The shipping
implementation is the C++ in rulebased-payload/.

Correction (2026-08-14, after the C++ was built and run on a VM): the
`--upstream` mode below models upstream's PredictTransform off-by-one and
reports "ddaay -> daay" as a mismatch. The real C++ engine does NOT behave
that way -- an A/B build of both variants produced identical committed text
for 21 Telex sequences, "ddaay" included. The prototype's model of the
consequence is wrong (in C++ an early "false" only commits the composition
sooner; the next keys transform in a fresh context and land on the same
characters). See VIETNAMESE-IME.md 4.3.

Usage:  python3 telex-rules-prototype.py [vi_telex|vi_vni|vi_viqr] [word ...]
"""

import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
DEF = os.path.join(HERE, "rulebased-payload", "chromeos", "ash", "services",
                   "ime", "public", "cpp", "rulebased", "def")

TRANSAT = "\u001d"


def parse_c_string_array(path, name):
    """Extract a C `const char* name[] = { ... };` array of string literals."""
    src = open(path, encoding="utf-8").read()
    start = src.index("%s[] = {" % name)
    start = src.index("{", start)
    depth, i = 0, start
    while True:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    body = src[start + 1:i]
    # Strip // comments before scanning for literals: a comment that contains a
    # double quote (ours do) would otherwise be read as the start of a string.
    body = "\n".join(re.sub(r"//.*$", "", line) for line in body.split("\n"))
    out, buf, in_str, esc, pending = [], "", False, False, False
    for ch in body:
        if in_str:
            if esc:
                buf += "\\" + ch
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
                pending = True
            else:
                buf += ch
            continue
        if ch == '"':
            in_str = True
        elif ch == "," and pending:
            out.append(buf.encode().decode("unicode_escape"))
            buf, pending = "", False
    if pending:
        out.append(buf.encode().decode("unicode_escape"))
    return out


def prefixalize(pattern):
    """Faithful port of rules_data.cc Prefixalize()/WrapPrefixUnit(): each
    literal unit becomes "(?:unit|$)", so the result matches any prefix."""
    out, i, n = "", 0, len(pattern)
    while i < n:
        ch = pattern[i]
        if ch == "\\":
            out += "(?:\\" + pattern[i + 1] + "|$)"
            i += 2
        elif ch == "[":
            j = pattern.index("]", i)
            out += "(?:" + pattern[i:j + 1] + "|$)"
            i = j + 1
        elif ch == "{":
            j = pattern.index("}", i)
            out += pattern[i:j + 1]
            i = j + 1
        elif ch in "+*?.()|":
            out += ch
            i += 1
        else:
            out += "(?:" + re.escape(ch) + "|$)"
            i += 1
    return out


class Rules:
    def __init__(self, ime_id):
        path = os.path.join(DEF, ime_id + ".cc")
        raw = parse_c_string_array(path, "kTransforms")
        self.rules = [(re.compile(raw[i] + "$"), raw[i + 1])
                      for i in range(0, len(raw), 2)]
        self.prefix = re.compile("|".join(prefixalize(raw[i])
                                          for i in range(0, len(raw), 2)))

    def transform(self, context, transat, appended):
        s = (context[:transat] + TRANSAT + context[transat:] + appended
             if transat > 0 else context + appended)
        # RE2 matches the merged alternation leftmost-first: earliest start
        # position wins, ties broken by rule declaration order.
        best = None
        for idx, (rx, repl) in enumerate(self.rules):
            m = rx.search(s)
            if m and (best is None or m.start() < best[0].start()):
                best = (m, repl)
        if best is not None:
            m, repl = best
            if m.start() > len(s) - len(appended):
                return None
            out = s[:m.start()] + re.sub(r"\\(\d)",
                                         lambda g: m.group(int(g.group(1))) or "",
                                         repl) + s[m.end():]
            return out.replace(TRANSAT, "")
        return None

    # Set to True to reproduce upstream's off-by-one (see rules_data.cc
    # PredictTransform in rulebased-payload/, and VIETNAMESE-IME.md).
    upstream_off_by_one = False

    def predict(self, s, transat):
        t = s[:transat] + TRANSAT + s[transat:] if transat > 0 else s
        n = len(s) if self.upstream_off_by_one else len(t)
        for i in range(n):
            if self.prefix.fullmatch(t[n - i - 1:]):
                return True
        return False


class Engine:
    """Port of rulebased/engine.cc. Keys are fed as characters (the key map
    lookup that turns a DomCode into a character is skipped)."""

    def __init__(self, ime_id):
        self.d = Rules(ime_id)
        self.reset()

    def reset(self):
        self.ctx, self.transat = "", -1

    def process(self, key):
        commit, comp = "", ""
        out = self.d.transform(self.ctx, self.transat, key)
        if out is not None:
            self.ctx, self.transat = out, len(out)
        else:
            self.ctx += key
        if not self.d.predict(self.ctx, self.transat):
            commit = self.ctx
            self.reset()
            return commit, ""
        return "", self.ctx


def type_word(ime_id, word):
    e, out = Engine(ime_id), ""
    for ch in word:
        commit, comp = e.process(ch)
        out += commit
    out += e.ctx
    return unicodedata.normalize("NFC", out)


CASES = [
    ("vi_telex", "tieengs", "tiếng"),
    ("vi_telex", "Vieejt", "Việt"),
    ("vi_telex", "ddaay", "đây"),
    ("vi_telex", "chuwx", "chữ"),
    ("vi_telex", "nguwowfi", "người"),
    ("vi_telex", "hocj", "học"),
    ("vi_telex", "cheesch", "chếch"),
    ("vi_telex", "toans", "toán"),
    ("vi_telex", "ddoongf", "đồng"),
    ("vi_telex", "quaan", "quân"),
    ("vi_vni", "tie6ng1", "tiếng"),
    ("vi_vni", "Vie65t", "Việt"),
    ("vi_viqr", "tie^'ng", "tiếng"),
]

if __name__ == "__main__":
    if "--upstream" in sys.argv:
        Rules.upstream_off_by_one = True
        sys.argv.remove("--upstream")
    if len(sys.argv) > 2:
        for w in sys.argv[2:]:
            print("%-12s -> %s" % (w, type_word(sys.argv[1], w)))
        sys.exit(0)
    bad = 0
    for ime, inp, want in CASES:
        got = type_word(ime, inp)
        ok = got == unicodedata.normalize("NFC", want)
        bad += not ok
        print("%-4s %-9s -> %-8s want %-8s %s"
              % (ime.replace("vi_", ""), inp, got, want, "ok" if ok else "MISMATCH"))
    print("\n%d/%d" % (len(CASES) - bad, len(CASES)))
