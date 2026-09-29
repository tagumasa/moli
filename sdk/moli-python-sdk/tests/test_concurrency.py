"""Concurrency: the SDK's headline claims.

An Analyzer is immutable once loaded, so many Python threads may
tokenize through one shared handle with true parallelism (the GIL is
released around the ABI call); outputs must be byte-identical to the
serial run. Closing from one thread is safe with in-flight tokenizers
in others — free's drain does the waiting.
"""

import threading

import moli
from conftest import IPADIC

TEXT = "犬が歩く"
N_THREADS = 8
N_ROUNDS = 50


def serial_reference():
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    try:
        return a.tokenize(TEXT)
    finally:
        a.close()


def morph_key(ms):
    return [(m.surface, m.pos, m.lemma, m.reading, m.cost, m.start, m.end) for m in ms]


def test_eight_threads_identical_output():
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    try:
        want = morph_key(a.tokenize(TEXT))
        results = [None] * N_THREADS
        errors = []

        def work(i):
            try:
                for _ in range(N_ROUNDS):
                    results[i] = morph_key(a.tokenize(TEXT))
            except Exception as exc:  # pragma: no cover - failure detail
                errors.append(exc)

        threads = [threading.Thread(target=work, args=(i,)) for i in range(N_THREADS)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors
        assert all(r == want for r in results)
    finally:
        a.close()


def test_concurrent_close_drains_cleanly():
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    errors = []
    barrier = threading.Barrier(N_THREADS)

    def work():
        try:
            barrier.wait()
            for _ in range(20):
                a.tokenize(TEXT)
        except moli.UnavailableError:
            pass  # the close won the race; the guard answered honestly
        except Exception as exc:  # pragma: no cover - failure detail
            errors.append(exc)

    threads = [threading.Thread(target=work) for _ in range(N_THREADS)]
    for t in threads:
        t.start()
    a.close()
    for t in threads:
        t.join()
    assert not errors


def test_threads_never_see_partial_results():
    """A stress variant: each thread tokenizes distinct sentences and
    checks self-consistency (offsets tile the input)."""
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    try:
        sentences = ["犬が歩く", "犬が歩いている", "猫が寝る", "歩く犬", "犬"]

        def work(sent):
            for _ in range(20):
                ms = a.tokenize(sent)
                assert ms, "empty result"
                assert ms[0].start == 0
                assert ms[-1].end == len(sent.encode())
                for prev, cur in zip(ms, ms[1:]):
                    assert prev.end == cur.start

        threads = [threading.Thread(target=work, args=(s,)) for s in sentences]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
    finally:
        a.close()
