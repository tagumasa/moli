#!/usr/bin/env python3
"""Per-build SDK rate probe for A/B measurement (numbers only).

    python3 bench/sdk_ab_probe.py <sdk-src-root>

Loads the shared ipadic qdct snapshot once, then measures the tokenize
object path over ~16 KB sentence-accumulated chunks (the primary arm —
the per-morpheme conversion layer's cost sits on top of a warmed
retained scratch) plus the guard arms. Every rate arm prints its
morpheme count; cross-build comparison is only valid when those counts
agree. One line per arm, machine-parseable.
"""

import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, sys.argv[1])

import moli  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = "tmp/sdk_ab/ipadic.qdct"
FRESH_CSV = REPO_ROOT / "dict" / "ipadic-utf8" / "lex.csv"


def assert_snapshot_fresh():
    """A snapshot an older tree produced loads fine and rates wrong:
    compare its dictionary fingerprint against a fresh CSV load
    through this build before any arm runs."""
    a = moli.load_qdct_mmap(SNAPSHOT)
    snap_hash = a.stats().entries_hash
    a.close()
    b = moli.load(moli.Language.Japanese, str(FRESH_CSV))
    fresh_hash = b.stats().entries_hash
    b.close()
    if snap_hash != fresh_hash:
        raise SystemExit(
            f"stale snapshot {SNAPSHOT}: entries_hash {snap_hash:#x} != "
            f"fresh {fresh_hash:#x} (run: just bench-snapshots)")

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

# Sentence-accumulated chunks (rune-safe: never splits a sentence)
# repeated to just over 1 MiB total. The 16 KiB set is the request-size
# sweet band; the 64 KiB set sits just past the retain gate's
# full-margin bound (~63.9 KiB of input) — the fresh-map cliff shape.
def build_chunks(chunk_bytes, total_bytes):
    out = []
    cur = []
    cur_n = 0
    total = 0
    i = 0
    while total < total_bytes:
        s = jp_pool[i % len(jp_pool)]
        if cur_n >= chunk_bytes:
            out.append("".join(cur))
            cur = []
            cur_n = 0
        cur.append(s)
        n = len(s.encode())
        cur_n += n
        total += n
        i += 1
    if cur:
        out.append("".join(cur))
    return out


chunks = build_chunks(16 * 1024, 1 << 20)
BYTES = sum(len(c.encode()) for c in chunks)
chunks64 = build_chunks(64 * 1024, 1 << 20)
BYTES64 = sum(len(c.encode()) for c in chunks64)
TEXT_SMALL = "犬が歩く"


def psi_some():
    try:
        with open("/proc/pressure/cpu") as f:
            for line in f:
                if line.startswith("some "):
                    return float(line.split()[1].split("=")[1])
    except OSError:
        pass
    return 0.0


def med_passes(fn, passes):
    fn()  # warm-up pass
    xs = []
    for _ in range(passes):
        t0 = time.perf_counter()
        fn()
        xs.append(time.perf_counter() - t0)
    return statistics.median(xs)


def med_iters(fn, iters):
    fn()
    t0 = time.perf_counter()
    for _ in range(iters):
        fn()
    return (time.perf_counter() - t0) / iters


def main():
    if len(sys.argv) > 3 and sys.argv[2] == "mem":
        return mem_mode(sys.argv[3])
    print(f"psi_some={psi_some():.6f} bytes={BYTES} chunks={len(chunks)}")
    assert_snapshot_fresh()
    a = moli.load_qdct_mmap(SNAPSHOT)
    try:
        morphs = sum(len(a.tokenize(c)) for c in chunks)  # warm + sanity
        t = med_passes(lambda: [a.tokenize(c) for c in chunks], 5)
        print(f"ARM tokenize16k median_s={t:.6f} "
              f"mibs={BYTES / t / (1 << 20):.3f} morphs={morphs}")

        t = med_passes(lambda: [list(a.tokenize(c)) for c in chunks], 5)
        print(f"ARM tokenize16k_fulliter median_s={t:.6f} "
              f"mibs={BYTES / t / (1 << 20):.3f} morphs={morphs}")

        t = med_passes(lambda: [a.tokenize(c)[:10] for c in chunks], 5)
        print(f"ARM tokenize16k_first10 median_s={t:.6f} "
              f"mibs={BYTES / t / (1 << 20):.3f} morphs={10 * len(chunks)}")

        t = med_passes(lambda: [len(a.tokenize(c)) for c in chunks], 5)
        print(f"ARM tokenize16k_lenonly median_s={t:.6f} "
              f"mibs={BYTES / t / (1 << 20):.3f} morphs={morphs}")

        m64 = sum(len(a.tokenize(c)) for c in chunks64)  # warm + sanity
        t = med_passes(lambda: [a.tokenize(c) for c in chunks64], 5)
        print(f"ARM tokenize64k median_s={t:.6f} "
              f"mibs={BYTES64 / t / (1 << 20):.3f} morphs={m64}")

        t = med_passes(lambda: [list(a.tokenize(c)) for c in chunks64], 3)
        print(f"ARM tokenize64k_fulliter median_s={t:.6f} "
              f"mibs={BYTES64 / t / (1 << 20):.3f} morphs={m64}")

        n = sum(len(a.wakachi(c)) for c in chunks)
        t = med_passes(lambda: [a.wakachi(c) for c in chunks], 3)
        print(f"ARM wakachi16k median_s={t:.6f} "
              f"mibs={BYTES / t / (1 << 20):.3f} morphs={n}")

        t = med_passes(lambda: [a.wakati(c) for c in chunks], 3)
        print(f"ARM wakati16k median_s={t:.6f} "
              f"mibs={BYTES / t / (1 << 20):.3f}")

        t = med_passes(lambda: [a.parse(c) for c in chunks], 3)
        print(f"ARM parse16k median_s={t:.6f} "
              f"mibs={BYTES / t / (1 << 20):.3f}")

        us = med_iters(lambda: a.tokenize(TEXT_SMALL), 20000) * 1e6
        print(f"ARM small_tokenize us={us:.3f} "
              f"morphs={len(a.tokenize(TEXT_SMALL))}")

        us = med_iters(lambda: a.tokenize(TEXT_SMALL)[0], 20000) * 1e6
        print(f"ARM small_first us={us:.3f}")

        us = med_iters(lambda: a.nbest(TEXT_SMALL, k=3), 3000) * 1e6
        print(f"ARM small_nbest us={us:.3f}")

        us = med_iters(a.stats, 2000) * 1e6
        print(f"ARM stats us={us:.3f}")
    finally:
        a.close()


def rss_kib():
    with open("/proc/self/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    return 0


def mem_mode(shape):
    """Fresh-process memory shapes over the same 64 chunks: what a
    caller holds after the loop, in KiB (VmRSS after a gc, plus
    tracemalloc's Python-side current). Deterministic enough that a
    single run per shape is the comparison."""
    import gc
    import tracemalloc

    print(f"psi_some={psi_some():.6f} shape={shape}")
    assert_snapshot_fresh()
    a = moli.load_qdct_mmap(SNAPSHOT)
    base = rss_kib()
    tracemalloc.start()
    keep = []
    if shape == "eager_lists":
        for c in chunks:
            keep.append(list(a.tokenize(c)))
    elif shape == "views_unread":
        for c in chunks:
            keep.append(a.tokenize(c))
    elif shape == "views_first10":
        for c in chunks:
            v = a.tokenize(c)
            keep.append(v[:10])  # the slice's list; the view itself dies
            del v
    elif shape == "views_full":
        for c in chunks:
            v = a.tokenize(c)
            for _ in v:
                pass
            keep.append(v)
    else:
        raise SystemExit(f"unknown shape {shape}")
    cur, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    gc.collect()
    print(f"MEM {shape} rss_delta_kib={rss_kib() - base} "
          f"traced_cur_kib={cur >> 10} traced_peak_kib={peak >> 10} "
          f"items={len(keep)}")
    a.close()


if __name__ == "__main__":
    main()
