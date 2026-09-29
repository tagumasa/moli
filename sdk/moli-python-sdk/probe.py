"""FFI overhead probe: per-call Python-side timings through the SDK.

Memory-polite by design: one analyzer held for the whole run, strictly
sequential calls, warm-up before every measurement. Numbers are
recorded by hand in docs/benchmarks.md; nothing here asserts.
"""

import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

import moli  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
IPADIC = REPO_ROOT / "tests" / "fixtures" / "ipadic_sample.csv"

TEXT_SMALL = "犬が歩く"
TEXT_LARGE = TEXT_SMALL * 100  # ~300 morphemes

# The FFI table's two columns share one statistic: the median of five
# block means (bench/native_probe.odin reports the same shape). A
# scheduler blip lands whole in one block mean and the median discards
# it, instead of skewing a single whole-run mean.
BLOCKS = 5


def bench(label, fn, iters):
    fn()  # warm-up
    per_block = iters // BLOCKS
    means = []
    for _ in range(BLOCKS):
        start = time.perf_counter()
        for _ in range(per_block):
            fn()
        means.append((time.perf_counter() - start) / per_block)
    us = statistics.median(means) * 1e6
    print(f"{label:<28} {iters:>7} iters   {us:9.2f} us/call")
    return us


def main():
    t0 = time.perf_counter()
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    load_ms = (time.perf_counter() - t0) * 1e3
    print(f"load (fixture)               {'1':>7} iter   {load_ms:9.2f} ms")

    try:
        n_small = len(a.tokenize(TEXT_SMALL))
        n_large = len(a.tokenize(TEXT_LARGE))
        print(f"morphemes: small={n_small} large={n_large}")
        print()

        bench("tokenize small", lambda: a.tokenize(TEXT_SMALL), 20000)
        bench("tokenize small [0]", lambda: a.tokenize(TEXT_SMALL)[0], 20000)
        bench("wakachi small", lambda: a.wakachi(TEXT_SMALL), 20000)
        bench("spans small", lambda: a.spans(TEXT_SMALL), 20000)
        bench("nbest small k=3", lambda: a.nbest(TEXT_SMALL, k=3), 5000)
        bench("tokenize large", lambda: a.tokenize(TEXT_LARGE), 500)
        bench("tokenize large, list()", lambda: list(a.tokenize(TEXT_LARGE)), 500)
        bench("stats", a.stats, 20000)
        bench("classify_locale", lambda: a.classify_locale("the colour of defence"), 20000)

        snap = a.snapshot()
        bench("snapshot", a.snapshot, 2000)
        clones = moli.load_qdct_bytes(snap)
        clones.close()
    finally:
        a.close()


if __name__ == "__main__":
    main()
