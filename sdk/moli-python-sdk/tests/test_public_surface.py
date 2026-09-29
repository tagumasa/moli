"""Binding coverage for the documented public surface: loaders and
load options the rest of the suite never exercises (``load_qdct``,
``threads``, ``lemma_locale``, ``flat_char_class``, the TW/HK/US/German
languages), the ``BoundaryConstraint`` form, jyutping reading values,
and the concurrent-mutation contracts at the Python boundary.
Search-semantics ownership stays with the core suite (tests/); this
module pins that every documented keyword crosses the ABI and produces
its observable effect.
"""

import threading

import pytest

import moli
from conftest import FIXTURES, IPADIC, load_ipadic

EN = FIXTURES / "en_sample.csv"
GERMAN = FIXTURES / "german_sample.csv"
TW = FIXTURES / "jieba_tw_sample.csv"
HK = FIXTURES / "jieba_hk_sample.csv"
MERGE_CN = FIXTURES / "jieba_merge_cn.csv"
MERGE_HK = FIXTURES / "jieba_merge_hk.csv"


def test_load_qdct_roundtrip_and_missing_file(analyzer, tmp_path):
    # The path-based read-copy loader, including its error path. The
    # saved image is the golden bytes the cross-language test pins.
    path = tmp_path / "model.qdct"
    analyzer.save_qdct(str(path))
    a = moli.load_qdct(str(path))
    try:
        assert [m.surface for m in a.tokenize("犬が歩く")] == ["犬", "が", "歩く"]
        assert a.stats().entries == analyzer.stats().entries
    finally:
        a.close()
    with pytest.raises(moli.LoadError):
        moli.load_qdct(str(tmp_path / "no-such.qdct"))


def test_threads_option_binds():
    # threads parallelises the matrix parse; output is identical at
    # any worker count (determinism is the core suite's
    # parallel_load_test — here the keyword must bind and load).
    serial = moli.load(moli.Language.Japanese, str(IPADIC))
    parallel = moli.load(moli.Language.Japanese, str(IPADIC), threads=8)
    try:
        text = "犬が歩いている東京都"
        key = [(m.surface, m.cost, m.entry_id) for m in serial.tokenize(text)]
        assert [(m.surface, m.cost, m.entry_id) for m in parallel.tokenize(text)] == key
        assert parallel.stats().entries == serial.stats().entries
    finally:
        parallel.close()
        serial.close()


def test_lemma_locale_load_option():
    # lemma_locale rewrites whole entry lemmas at load: colour carries
    # a real lemma, defence the "*" that must stay untouched. The
    # table itself is pinned at the core (tests/lemma_norm_test.odin).
    plain = moli.load(moli.Language.EnglishGB, str(EN))
    us = moli.load(moli.Language.EnglishGB, str(EN), lemma_locale=moli.Locale.US)
    try:
        assert [(m.surface, m.lemma) for m in plain.tokenize("colour defence")] == [
            ("colour", "colour"), (" ", " "), ("defence", "defence"),
        ]
        assert [(m.surface, m.lemma) for m in us.tokenize("colour defence")] == [
            ("colour", "color"), (" ", " "), ("defence", "defence"),
        ]
    finally:
        us.close()
        plain.close()


def test_flat_char_class_load_option():
    # flat_char_class swaps the binary-search range table for
    # direct-index classification: a lookup-structure trade-off with
    # no tokenization change.
    plain = moli.load(moli.Language.Japanese, str(IPADIC))
    flat = moli.load(moli.Language.Japanese, str(IPADIC), flat_char_class=True)
    try:
        text = "犬が歩く。東京都は"
        assert [(m.surface, m.char_class) for m in flat.tokenize(text)] == [
            (m.surface, m.char_class) for m in plain.tokenize(text)
        ]
    finally:
        flat.close()
        plain.close()


def test_tw_hk_us_german_load():
    # The languages no other SDK test loads (the core suite smokes the
    # same fixtures through the Odin boundary).
    tw = moli.load(moli.Language.ChineseTW, str(TW))
    try:
        assert [m.surface for m in tw.tokenize("台北市")] == ["台北", "市"]
    finally:
        tw.close()
    hk = moli.load(moli.Language.ChineseHK, str(HK))
    try:
        assert [m.surface for m in hk.tokenize("香港島")] == ["香港", "島"]
    finally:
        hk.close()
    us = moli.load(moli.Language.EnglishUS, str(EN))
    try:
        assert [m.surface for m in us.tokenize("center quickly")] == ["center", " ", "quickly"]
    finally:
        us.close()
    de = moli.load(moli.Language.German, str(GERMAN))
    try:
        assert [m.surface for m in de.tokenize("der Arbeitsplatz ist schnell")] == [
            "der", " ", "Arbeitsplatz", " ", "ist", " ", "schnell",
        ]
        assert not de.tokenize("Arbeitsplatz")[0].is_unknown
    finally:
        de.close()


def test_jyutping_readings_carry_values():
    # The two-file jyutping flow must carry real values on both
    # readings: the pinyin stays, the donor's Cantonese arrives —
    # the homograph 島 and the prefix pair 今日新聞 both join.
    a = moli.load(moli.Language.ChineseCN, str(MERGE_CN),
                  jyutping_csv_path=str(MERGE_HK))
    try:
        island = a.tokenize("島")
        assert (island[0].reading, island[0].reading_jyutping) == ("dao3", "dou2")
        news = a.tokenize("今日新聞")
        assert (news[0].reading, news[0].reading_jyutping) == (
            "jin1 ri4 xin1 wen2", "gam1 jat6 san1 man4",
        )
    finally:
        a.close()


def test_boundary_constraint_namedtuple(analyzer):
    # The NamedTuple public form drives the same wire as the plain
    # tuples the constrained tests use.
    forced = list(
        analyzer.tokenize_constrained(
            "どず", boundaries=[moli.BoundaryConstraint(3, True)]
        )
    )
    assert [m.surface for m in forced] == ["ど", "ず"]


def test_midflight_cancel_is_race_tolerant(analyzer):
    # Cancel from the main thread while a long tokenize runs in a
    # worker: the call either completes before the cancel is observed
    # or unwinds with an in-bounds CancelledError — the race-tolerant
    # shape of the core suite's cancel_mid_walk_leg (the token offers
    # no walk-side hook to force the interleaving). The analyzer must
    # stay healthy either way.
    text = "犬が歩く。" * 100_000
    tok = moli.CancelToken()
    outcome = {}

    def work():
        try:
            analyzer.tokenize(text, cancel=tok)
            outcome["r"] = "ok"
        except moli.CancelledError as exc:
            outcome["r"] = ("cancelled", exc.byte_offset)
        except Exception as exc:  # pragma: no cover - failure detail
            outcome["r"] = ("other", repr(exc))

    th = threading.Thread(target=work)
    th.start()
    tok.cancel()
    th.join()
    assert outcome["r"] == "ok" or (
        isinstance(outcome["r"], tuple)
        and outcome["r"][0] == "cancelled"
        and 0 <= outcome["r"][1] <= len(text.encode())
    ), outcome
    assert [m.surface for m in analyzer.tokenize("犬が歩く")] == ["犬", "が", "歩く"]


def test_add_user_entries_with_concurrent_readers():
    # The merge swap drains in-flight readers: every tokenize during
    # the merge sees the pre-merge segmentation, the post-merge one,
    # or the documented mutating bounce (UnavailableError) — never a
    # torn state. Afterwards the merged entry wins and the analyzer
    # is healthy.
    a = load_ipadic()
    try:
        pre = ("犬", "助", "が", "歩く")
        post = ("犬助", "が", "歩く")
        bad = []

        def reader():
            for _ in range(60):
                try:
                    got = tuple(m.surface for m in a.tokenize("犬助が歩く"))
                    if got not in (pre, post):
                        bad.append(got)
                except moli.UnavailableError:
                    pass  # the documented mutating bounce

        threads = [threading.Thread(target=reader) for _ in range(4)]
        for t in threads:
            t.start()
        a.add_user_entries(
            [moli.UserEntry(surface="犬助", pos="名詞,固有名詞", reading="ケンスケ", cost=-3000)]
        )
        for t in threads:
            t.join()
        assert not bad
        assert tuple(m.surface for m in a.tokenize("犬助が歩く")) == post
    finally:
        a.close()


def test_close_drains_readout_calls():
    # close() must drain in-flight stats/snapshot readers the way it
    # drains tokenizers (the same in-flight bracket): the readers
    # finish or bounce honestly, and the join never hangs.
    a = load_ipadic()
    errors = []
    barrier = threading.Barrier(4)

    def stats_worker():
        try:
            barrier.wait()
            for _ in range(20):
                a.stats()
        except moli.UnavailableError:
            pass  # the close won the race; the guard answered honestly
        except Exception as exc:  # pragma: no cover - failure detail
            errors.append(exc)

    def snapshot_worker():
        try:
            barrier.wait()
            for _ in range(20):
                a.snapshot()
        except moli.UnavailableError:
            pass
        except Exception as exc:  # pragma: no cover - failure detail
            errors.append(exc)

    threads = [threading.Thread(target=stats_worker) for _ in range(3)]
    threads.append(threading.Thread(target=snapshot_worker))
    for t in threads:
        t.start()
    a.close()
    for t in threads:
        t.join()
    assert not errors
