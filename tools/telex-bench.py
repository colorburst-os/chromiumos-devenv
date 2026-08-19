#!/usr/bin/env python3
"""
Two host-side microbenchmarks that bound the numbers Half 2 turns on:

  (A) TRANSLITERATOR COMPUTE  -- how long the per-keystroke rule work takes.
      A conservative Python `re` proxy for ash's rulebased engine
      (chromeos/ash/services/ime/public/cpp/rulebased/{engine,rules_data}.cc):
      per key it builds the transat-annotated context, runs the merged
      alternation regex (RulesData::Transform), applies the matched rewrite,
      then runs the prefix-predict suffix scan (PredictTransform). The shipping
      engine uses RE2 compiled C++, which is *faster* than Python `re`, so this
      is an UPPER BOUND on engine compute. UniKey's ukengine is a hand-written
      state machine over a keystroke buffer with no regex at all, so its
      per-key cost is in the same "tens of microseconds or less" class.

  (B) LOCAL-SOCKET IPC ROUND TRIP -- the cost of putting a transliterator
      behind a separate process. A parent/child AF_UNIX SOCK_STREAM ping-pong
      with a tiny payload, measured many times. This is the per-keystroke tax a
      "separate GPL/LGPL daemon over a local socket" would add on top of the
      compute, and it is what we compare against the measured E2E pipeline.

Run: python3 telex-bench.py [--iters N]
Stdlib only.
"""
import os, re, socket, statistics, sys, time

# ---- vi_telex rule table, transcribed from the shipping def/vi_telex.cc -----
# (the colorburst fork table: 41 pairs). \x1d is the "transat" delimiter.
D = ""
TELEX_RULES = [
 (r"[uU]\x1d?[oO]\x1d?[wW]", "ươ"),
 (r"[uU]\x1d?[oO]\x1d?[nN]\x1d?[gG]\x1d?[wW]", "ương"),
 (r"ư\x1d[wW]", "uw"),
 (r"ă\x1d[wW]", "aw"),
 (r"ơ\x1d[wW]", "ow"),
 (r"d\x1d?d", "đ"),
 (r"a\x1d?a", "â"),
 (r"e\x1d?e", "ê"),
 (r"o\x1d?o", "ô"),
 (r"a\x1d?w", "ă"),
 (r"o\x1d?w", "ơ"),
 (r"u\x1d?w", "ư"),
 (r"D\x1d?[Dd]", "Đ"),
 (r"A\x1d?[aA]", "Â"),
 (r"E\x1d?[eE]", "Ê"),
 (r"O\x1d?[oO]", "Ô"),
 (r"A\x1d?[wW]", "Ă"),
 (r"O\x1d?[wW]", "Ơ"),
 (r"U\x1d?[wW]", "Ư"),
 (r"(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY])([aeiouyAEIOUY]?|[bcdghklmnpqtvBCDGHKLMNPQTV]+)\x1d?[fF]", r"\1̀\3"),
 (r"(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY])([aeiouyAEIOUY]?|[bcdghklmnpqtvBCDGHKLMNPQTV]+)\x1d?[sS]", r"\1́\3"),
 (r"(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY])([aeiouyAEIOUY]?|[bcdghklmnpqtvBCDGHKLMNPQTV]+)\x1d?[rR]", r"\1̉\3"),
 (r"(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY])([aeiouyAEIOUY]?|[bcdghklmnpqtvBCDGHKLMNPQTV]+)\x1d?[xX]", r"\1̃\3"),
 (r"(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY])([aeiouyAEIOUY]?|[bcdghklmnpqtvBCDGHKLMNPQTV]+)\x1d?[jJ]", r"\1̣\3"),
 (r"([ăâêôơưĂÂÊÔƠƯ])\x1d?([a-zA-Z]*)[fF]", r"\1̀\2"),
 (r"([ăâêôơưĂÂÊÔƠƯ])\x1d?([a-zA-Z]*)[sS]", r"\1́\2"),
 (r"([ăâêôơưĂÂÊÔƠƯ])\x1d?([a-zA-Z]*)[rR]", r"\1̉\2"),
 (r"([ăâêôơưĂÂÊÔƠƯ])\x1d?([a-zA-Z]*)[xX]", r"\1̃\2"),
 (r"([ăâêôơưĂÂÊÔƠƯ])\x1d?([a-zA-Z]*)[jJ]", r"\1̣\2"),
]

# One merged alternation, like RulesData::transform_re_merged_.
MERGED = re.compile("|".join("(?:%s)" % f for f, _ in TELEX_RULES) + "$")
COMPILED = [(re.compile(f + "$"), t) for f, t in TELEX_RULES]
# Prefix regex proxy for PredictTransform (does a suffix ever extend to a rule).
PREFIX = re.compile("|".join(f for f, _ in TELEX_RULES))

def process_key(context, key):
    """One keystroke: Transform + PredictTransform, mimicking engine.cc."""
    s = context + key
    # Transform: merged match then specific rewrite (rules_data.cc:370-418)
    if MERGED.search(s):
        for rx, repl in COMPILED:
            m = rx.search(s)
            if m:
                s = s[:m.start()] + m.expand(repl) + s[m.end():]
                s = s.replace(D, "")
                break
    # PredictTransform suffix scan (rules_data.cc:424-449)
    keep = False
    for i in range(len(s)):
        if PREFIX.fullmatch(s[len(s)-i-1:]):
            keep = True
            break
    return (s, keep)

SEQS = ["tieengs", "vieejt", "nghieengs", "nguwowfi", "ddaay", "hoojc",
        "luyeenj", "mootj", "nieemf", "hoafs", "thuys", "congas"]

def bench_engine(iters):
    samples = []  # per-keystroke seconds
    for _ in range(iters):
        for seq in SEQS:
            ctx = ""
            for ch in seq:
                t0 = time.perf_counter()
                ctx, keep = process_key(ctx, ch)
                if not keep:
                    ctx = ""  # engine commits & resets
                samples.append(time.perf_counter() - t0)
    return samples

def bench_ipc(iters):
    parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    pid = os.fork()
    if pid == 0:
        parent.close()
        while True:
            b = child.recv(64)
            if not b:
                os._exit(0)
            child.sendall(b)  # echo (stand-in for "engine processed this key")
    child.close()
    # warm up
    for _ in range(1000):
        parent.sendall(b"tieengs"); parent.recv(64)
    samples = []
    msg = b"k:DomCode::KeyT,mods:0"  # ~ a ProcessKeyEvent-sized token
    for _ in range(iters):
        t0 = time.perf_counter()
        parent.sendall(msg)
        parent.recv(64)
        samples.append(time.perf_counter() - t0)
    parent.close()
    os.waitpid(pid, 0)
    return samples

def stats_us(samples):
    us = sorted(x*1e6 for x in samples)
    def pct(p): return us[min(len(us)-1, int(round(p/100*(len(us)-1))))]
    return dict(n=len(us), mean=statistics.mean(us), p50=pct(50),
                p95=pct(95), p99=pct(99), max=us[-1])

def main():
    iters = 2000
    if "--iters" in sys.argv:
        iters = int(sys.argv[sys.argv.index("--iters")+1])
    print("host:", os.uname().sysname, os.uname().machine, "python", sys.version.split()[0])
    e = stats_us(bench_engine(max(1, iters//1000)))
    print("\n(A) rulebased transliterator compute  (Python `re` upper bound; RE2/C++ is faster)")
    print("    per keystroke:  n=%d  mean=%.1f  p50=%.1f  p95=%.1f  p99=%.1f  max=%.1f  (microseconds)"
          % (e['n'], e['mean'], e['p50'], e['p95'], e['p99'], e['max']))
    i = stats_us(bench_ipc(iters*10))
    print("\n(B) local AF_UNIX round trip  (separate-process per-keystroke IPC tax)")
    print("    per round trip: n=%d  mean=%.1f  p50=%.1f  p95=%.1f  p99=%.1f  max=%.1f  (microseconds)"
          % (i['n'], i['mean'], i['p50'], i['p95'], i['p99'], i['max']))

if __name__ == "__main__":
    main()
