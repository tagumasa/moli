"""The lazy Morphemes view tokenize() returns: sequence semantics,
materialization caching, and the standalone-lifetime contract (no
invalidation, no analyzer coupling)."""

import gc
import threading

import pytest

import moli

from conftest import IPADIC


TEXT = "犬が歩く。東京都は新しい。"
SENT = "東京都は二十五日、新型コロナウイルスの感染者数が過去最多を更新したと発表した。"


def test_sequence_protocol(analyzer):
    v = analyzer.tokenize(TEXT)
    assert isinstance(v, moli.Morphemes)
    assert len(v) > 3
    first = v[0]
    assert v[0] is first  # cached: identity is stable
    assert v[len(v) - 1] is v[-1]
    assert isinstance(first, moli.Morpheme)
    assert [m.surface for m in v[:3]] == [v[0].surface, v[1].surface, v[2].surface]
    assert list(v) == [v[i] for i in range(len(v))]
    assert [m.surface for m in v] == [m.surface for m in v]  # iterate twice
    with pytest.raises(IndexError):
        v[len(v)]
    with pytest.raises(IndexError):
        v[-len(v) - 1]
    with pytest.raises(TypeError):
        v["surface"]


def test_view_matches_eager_fields(analyzer):
    text = "犬が歩く"
    v = analyzer.tokenize(text)
    eager = list(v)
    assert [m.surface for m in eager] == ["犬", "が", "歩く"]
    # the parse presentation is exactly the tokenize fields
    lines = analyzer.parse(text).split("\n")
    assert len(lines) == len(v)
    for line, m in zip(lines, v):
        assert line == "\t".join(
            [m.surface, m.pos, m.lemma, m.reading, m.reading_jyutping])


def test_step_slices(analyzer):
    v = analyzer.tokenize(TEXT)
    full = [m.surface for m in v]
    assert [m.surface for m in v[::2]] == full[::2]
    assert [m.surface for m in v[::-1]] == full[::-1]
    assert [m.surface for m in v[1:-1]] == full[1:-1]
    assert list(v[len(v):]) == []


def test_full_materialization_releases_and_keeps_working(analyzer):
    v = analyzer.tokenize(SENT)
    eager = list(v)
    # every morpheme is now cached: indexing still works and is stable
    assert v[5] is v[5]
    assert v[5] in eager


def test_view_outlives_analyzer():
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    try:
        v = a.tokenize("犬が歩く")
        partial = v[0]
    finally:
        a.close()
    # the box is standalone memory: reads after close are fine
    assert len(v) == 3
    assert v[1].surface == "が"
    assert v[0] is partial
    assert [m.surface for m in v] == ["犬", "が", "歩く"]


def test_empty_view(analyzer):
    v = analyzer.tokenize("")
    assert len(v) == 0
    assert list(v) == []
    assert not v


def test_malformed_bytes_view(analyzer):
    v = analyzer.tokenize(b"\xff\xfe\x81z" + "犬が歩く".encode())
    assert v[0].surface == "\udcff\udcfe\udc81"
    assert v[0].is_unknown
    assert [m.surface for m in v[1:]] == ["z", "犬", "が", "歩く"]


def test_partial_reads_are_garbage_collectable(analyzer):
    for _ in range(4):
        v = analyzer.tokenize(SENT)
        assert v[0].surface  # touch one morpheme only
    del v
    gc.collect()
    # Untouched views die under GC and their dealloc frees the native
    # box: the census of the GC object set proves the death (the
    # extension type carries no weakref slot, so the weakref proof the
    # lifecycle tests use for Analyzer and CancelToken is not available
    # here).
    kept = [analyzer.tokenize(SENT) for _ in range(8)]
    del kept
    gc.collect()
    alive = [o for o in gc.get_objects() if type(o) is moli.Morphemes]
    assert not alive, f"{len(alive)} Morphemes views survived collection"


def test_shared_view_across_threads(analyzer):
    v = analyzer.tokenize(SENT * 20)
    n = len(v)
    step = 37
    results = {}
    errors = []

    def read(k):
        try:
            results[k] = [v[i].surface for i in range(k, min(k + step, n))]
        except Exception as e:  # pragma: no cover - failure reporting
            errors.append(e)

    threads = [threading.Thread(target=read, args=(k,))
               for k in range(0, n, step)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert not errors
    for k, got in results.items():
        assert got == [v[i].surface for i in range(k, min(k + step, n))]


def test_view_is_not_instantiable():
    with pytest.raises(TypeError):
        moli.Morphemes()
