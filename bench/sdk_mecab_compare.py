#!/usr/bin/env python3
"""The MeCab-vs-moli comparison behind docs/benchmarks.md's "Against MeCab".

Drives libmecab (the Debian SWIG binding) and the moli Python SDK
through one jp_pool text built to just over 100K characters — about
300 KiB of UTF-8, the size the rates' byte counts are taken from —
and prints each arm's median rate plus its morpheme count — the
counts must agree across arms, which is the comparison's sanity gate.

Prerequisites: a Python MeCab binding and a UTF-8 ipadic dictionary
built with `mecab-dict-index` from the same source tree moli imports
(pass its path as the only argument; default tmp/mecab_utf8_dic). Run
from the repo root with a python that has MeCab — the SDK venv does
not:

    python3 bench/sdk_mecab_compare.py [mecab_utf8_dict_dir]

ChaSen arms run when the Debian `chasen` + `ipadic` packages are
installed: libchasen driven in-process via ctypes, through a run-time
copy of /usr/share/chasen/ipadic.rc with GRAMMAR pinned to the ipadic
package's own grammar directory (so the analysis cannot follow the
system's update-alternatives selection). The rc binds at the library's
first-call init, so each output format rides its own subprocess; the
timing loop and its warmup run inside that subprocess.

Chunked arms follow the unchunked table: both engines over the same
safe-cut pieces of a "\n\n"-joined pool (8 and 16 KB targets), plus
the mecab-unchunked control — the fair chunked-vs-chunked comparison
that chunked-vs-unchunked rounds cannot answer (mecab gains from
chunking too). The main text above carries no separators, and the
safe-cut rule only cuts after newline-ending whitespace runs, so it
has no safe cut at all — the chunked arms need the joined pool.
"""

import os
import pathlib
import statistics
import subprocess
import sys
import time

sys.path.insert(0, "sdk/moli-python-sdk/src")

import MeCab  # noqa: E402
import moli  # noqa: E402

DICT = sys.argv[1] if len(sys.argv) > 1 else "tmp/mecab_utf8_dic"

CHASEN_RC = "/usr/share/chasen/ipadic.rc"
CHASEN_GRAMMAR_PIN = ("/var/lib/chasen/dic/debian", "/var/lib/chasen/dic/ipadic")

jp_pool = [
"東京都は二十五日、新型コロナウイルスの感染者数が過去最多を更新したと発表した。",
"政府は来年度予算案の編成に向け、歳出改革の議論を本格化させる方針だ。",
"市場関係者は日経平均株価の急落を警戒している。",
"研究チームは気候変動が生態系に与える影響を分析した。",
"駅前の新しい図書館は来月一日に開館する。",
"彼女はヴェルタース地方の雑木林を訪ねた。",
"社長は記者会見で増益決算を説明した。",
"台風九号は日本海へ進み、北海道に接近している。",
"その提案には賛成できないと彼は述べた。",
"最新の観測データによれば、地震活動は沈静化しつつある。",
"私たちは東京駅から新幹線に乗って京都へ向かった。",
"この地域では米や野菜の生産が盛んだ。",
]

text = "".join(jp_pool)
while len(text) < (100 << 10):
    text += "".join(jp_pool)

mecab_full = MeCab.Tagger(f"-d {DICT}")
mecab_wakati = MeCab.Tagger(f"-d {DICT} -Owakati")
a = moli.load(moli.Language.Japanese, "dict/ipadic-utf8/lex.csv")

nbytes = len(text.encode("utf-8"))
print(f"text: {nbytes} bytes  ({nbytes/(1<<20):.2f} MiB)")


def med(f, n=15, warm=3):
    for _ in range(warm):
        f()
    xs = []
    r = None
    for _ in range(n):
        t0 = time.perf_counter()
        r = f()
        xs.append(time.perf_counter() - t0)
    return statistics.median(xs), r


arms = [
    ("mecab default (full)", lambda: mecab_full.parse(text)),
    ("mecab -Owakati",       lambda: mecab_wakati.parse(text)),
    # On the lazy-view build the plain tokenize arm reads only len()
    # (engine + box, no conversion); the full-list arm materializes
    # every Morpheme. Keep both so a run answers both questions.
    ("moli tokenize (view len)",   lambda: a.tokenize(text)),
    ("moli tokenize (full list)",  lambda: list(a.tokenize(text))),
    ("moli wakachi",         lambda: a.wakachi(text)),
    ("moli parse (TSV str)", lambda: a.parse(text)),
    ("moli wakati (str)",    lambda: a.wakati(text)),
]
for name, f in arms:
    dt, r = med(f)
    if name == "mecab default (full)":
        cnt = r.count("\n") - 1  # minus EOS
    elif name == "mecab -Owakati":
        cnt = len(r.split())
    elif name == "moli parse (TSV str)":
        cnt = r.count("\n") + 1
    elif name == "moli wakati (str)":
        cnt = r.count(" ") + 1
    else:
        cnt = len(r)
    mibs = nbytes / dt / (1 << 20)
    print(f"{name:22} {dt*1000:9.1f} ms  {mibs:6.2f} MiB/s  morphemes={cnt}")


# Chunked fair comparison: both engines over the same safe-cut pieces.
# The one-piece identity check (single call vs concatenated pieces) is
# the tripwire for the cut rule; it is the SDK suite's job to assert,
# this only reports.
para = "\n\n".join(jp_pool)
while len(para) < (100 << 10):
    para += "\n\n" + "\n\n".join(jp_pool)
pbytes = len(para.encode("utf-8"))
print(f"\nchunked (paragraph pool {pbytes} bytes):")
for kb in (8, 16):
    pieces = moli.safe_chunks(para, kb << 10)
    one = len(a.tokenize(para))
    joined = sum(len(a.tokenize(p)) for p in pieces)
    chunked_arms = [
        (f"mecab -Owakati {kb}KB", lambda ps=pieces: [mecab_wakati.parse(p) for p in ps]),
        (f"moli wakati {kb}KB", lambda ps=pieces: [a.wakati(p) for p in ps]),
        (f"moli tokenize view {kb}KB", lambda ps=pieces: [len(a.tokenize(p)) for p in ps]),
    ]
    print(f" {kb:>3} KB -> {len(pieces)} pieces  identity one={one} joined={joined}")
    for name, f in chunked_arms:
        dt, _ = med(f)
        mibs = pbytes / dt / (1 << 20)
        print(f"{name:28} {dt*1000:9.1f} ms  {mibs:6.2f} MiB/s")


# ChaSen: measured in a subprocess per output format (the rc binds at
# the library's first-call init). The driver reports both a line count
# (default format: one morpheme per line, one EOS) and a word count
# (wakati format: space-joined surfaces).
CHASEN_DRIVER = r"""
import ctypes, statistics, sys, time
ch = ctypes.CDLL("libchasen.so.2")
ch.chasen_sparse_tostr.restype = ctypes.c_char_p
ch.chasen_sparse_tostr.argtypes = [ctypes.c_char_p]
text = sys.stdin.buffer.read()
def run():
    return ch.chasen_sparse_tostr(text)
for _ in range(3):
    run()
xs = []
out = b""
for _ in range(15):
    t0 = time.perf_counter()
    out = run()
    xs.append(time.perf_counter() - t0)
print(statistics.median(xs), out.count(b"\n") - 1, len(out.split()))
"""


def chasen_rc(mode):
    src = pathlib.Path(CHASEN_RC).read_text(encoding="utf-8")
    src = src.replace(*CHASEN_GRAMMAR_PIN)
    if mode == "wakati":
        src += '\n(OUTPUT_FORMAT "%M ")\n(EOS_STRING "")\n'
    p = pathlib.Path(f"tmp/chasen_{mode}.rc")
    p.write_text(src, encoding="utf-8")
    return str(p)


def run_chasen(mode):
    env = dict(os.environ, CHASENRC=chasen_rc(mode))
    cp = subprocess.run(
        [sys.executable, "-c", CHASEN_DRIVER],
        input=text.encode(), capture_output=True, env=env, check=True,
    )
    dt, lines, words = cp.stdout.split()
    cnt = int(words) if mode == "wakati" else int(lines)
    return float(dt), cnt


if pathlib.Path(CHASEN_RC).exists():
    for name, mode in [("chasen default (full)", "default"), ("chasen wakati", "wakati")]:
        dt, cnt = run_chasen(mode)
        mibs = nbytes / dt / (1 << 20)
        print(f"{name:22} {dt*1000:9.1f} ms  {mibs:6.2f} MiB/s  morphemes={cnt}")
else:
    print("chasen: /usr/share/chasen/ipadic.rc not found - arms skipped")
