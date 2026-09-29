"""Golden parity and the option sweep against the fixtures."""

import pytest

import moli
from conftest import EN, IPADIC, QDCT_GOLDEN

GOLDEN = [
    ("犬", "名詞,一般", "犬", "イヌ", False),
    ("が", "助詞,格助詞,一般", "が", "ガ", False),
    ("歩く", "動詞,自立", "歩く", "アルク", False),
]


def test_tokenize_golden(analyzer):
    ms = analyzer.tokenize("犬が歩く")
    assert len(ms) == 3
    for m, (surface, pos, lemma, reading, unknown) in zip(ms, GOLDEN):
        assert m.surface == surface
        assert m.pos.startswith(pos)
        assert m.lemma == lemma
        assert m.reading == reading
        assert m.is_unknown is unknown
        assert m.locale is moli.Locale.NONE
    # the fixture loads without char.def, so the default range
    # classification answers: CJK ideographs are Hanzi here
    assert ms[0].char_class is moli.CharClass.Hanzi
    assert ms[1].char_class is moli.CharClass.Hiragana
    assert ms[0].cost == 5000
    assert (ms[0].start, ms[0].end) == (0, 3)
    assert (ms[1].start, ms[1].end) == (3, 6)
    assert (ms[2].start, ms[2].end) == (6, 12)
    # every golden morpheme is a dictionary row: a real entry index
    for m in ms:
        assert m.entry_id >= 0


def test_tokenize_accepts_bytes(analyzer):
    assert [m.surface for m in analyzer.tokenize("犬が歩く".encode())] == ["犬", "が", "歩く"]


def test_wakachi_and_spans(analyzer):
    assert analyzer.wakachi("犬が歩く") == ["犬", "が", "歩く"]
    spans = analyzer.spans("犬が歩く")
    assert [(s.surface, s.start, s.end) for s in spans] == [
        ("犬", 0, 3),
        ("が", 3, 6),
        ("歩く", 6, 12),
    ]


def test_wakati_and_parse_are_joins_of_the_lists(analyzer):
    text = "犬が歩く。研究チームは影響を分析した。"
    # wakati is the MeCab -Owakati presentation of wakachi
    assert analyzer.wakati(text) == " ".join(analyzer.wakachi(text))
    # parse is the TSV of exactly the fields tokenize returns
    lines = [
        "\t".join((m.surface, m.pos, m.lemma, m.reading, m.reading_jyutping))
        for m in analyzer.tokenize(text)
    ]
    assert analyzer.parse(text) == "\n".join(lines)


def test_wakati_and_parse_empty(analyzer):
    assert analyzer.wakati("") == ""
    assert analyzer.parse("") == ""


def test_wakati_and_parse_malformed_utf8(analyzer):
    # surrogateescape decode keeps the byte run round-trippable; the
    # single-string builds must equal the piecewise joins on it too
    raw = "犬が歩く".encode() + b"\xff" + "、走る".encode()
    assert analyzer.wakati(raw) == " ".join(analyzer.wakachi(raw))
    lines = [
        "\t".join((m.surface, m.pos, m.lemma, m.reading, m.reading_jyutping))
        for m in analyzer.tokenize(raw)
    ]
    assert analyzer.parse(raw) == "\n".join(lines)


def test_nbest(analyzer):
    paths = analyzer.nbest("犬が歩いている", k=3)
    assert len(paths) == 3
    assert paths[0].cost <= paths[1].cost <= paths[2].cost
    first_surfaces = [m.surface for m in paths[0].morphemes]
    assert first_surfaces[0] == "犬"
    # every path tiles the input
    for p in paths:
        assert "".join(m.surface for m in p.morphemes) == "犬が歩いている"


def test_modes_agree_on_single_path():
    # 犬が歩く has exactly one lattice path on this fixture, so greedy
    # and Viterbi must answer identically. Where the modes genuinely
    # diverge is pinned at the core, on analyzers built so paths
    # compete (tests/tokenizer_test.odin, tests/tokenize_options_test.odin).
    viterbi = moli.load(moli.Language.Japanese, str(IPADIC))
    greedy = moli.load(moli.Language.Japanese, str(IPADIC), mode=moli.Mode.LongestMatch)
    try:
        want = [m.surface for m in viterbi.tokenize("犬が歩く")]
        assert want == ["犬", "が", "歩く"]
        assert [m.surface for m in greedy.tokenize("犬が歩く")] == want
    finally:
        greedy.close()
        viterbi.close()


def test_normalize_nfc_offsets():
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    try:
        # U+304C precomposed vs U+304B + U+3099 decomposed
        precomposed = "が"
        decomposed = "か\u3099"
        plain = a.tokenize(decomposed)
        normalized = a.tokenize(decomposed, normalize_nfc=True)
        assert [m.surface for m in plain] != [m.surface for m in normalized]
        assert [m.surface for m in normalized] == [m.surface for m in a.tokenize(precomposed)]
    finally:
        a.close()


def test_strict_utf8_byte_offset(analyzer):
    bad = b"\xe7\x8a\xac\xff\xe3\x81\x8c"  # 犬, invalid byte, が
    with pytest.raises(moli.MalformedInputError) as ei:
        analyzer.tokenize(bad, strict_utf8=True)
    assert ei.value.byte_offset == 3
    # default degrades instead of rejecting
    ms = analyzer.tokenize(bad)
    assert len(ms) >= 2


def test_malformed_bytes_surface_roundtrip(analyzer):
    # Unknown morphemes over invalid bytes decode with surrogateescape
    # so the bytes round-trip.
    bad = b"\xff\xfe"
    ms = analyzer.tokenize(bad)
    joined = b"".join(m.surface.encode("utf-8", "surrogateescape") for m in ms)
    assert joined == bad


def test_pre_spent_cancel(analyzer):
    tok = moli.CancelToken()
    tok.cancel()
    with pytest.raises(moli.CancelledError) as ei:
        analyzer.tokenize("犬が歩く", cancel=tok)
    assert ei.value.byte_offset == 0


def test_unk_cost_options_bind(analyzer):
    # Binding smoke: both unknown-cost options cross the boundary and,
    # being search-only, leave the emitted costs the rules' own. A
    # dropped keyword would pass this vacuously on par with a bound
    # one — the search semantics are pinned at the core
    # (tests/tokenize_options_test.odin, on analyzers whose paths
    # genuinely compete under the knobs).
    base = analyzer.tokenize(" canine ")
    for opts in ({"unk_cost_bias": 100000}, {"unk_cost_per_rune": 3000}):
        biased = analyzer.tokenize(" canine ", **opts)
        assert [m.cost for m in biased] == [m.cost for m in base]
        assert [m.surface for m in biased] == [m.surface for m in base]


def test_classify_locale():
    en = moli.load(moli.Language.EnglishGB, str(EN))
    try:
        assert en.classify_locale("the colour of defence") is moli.Locale.GB
        assert en.classify_locale("the color of defense at the center") is moli.Locale.US
        assert en.classify_locale("the cat sat on the mat") is moli.Locale.NONE
    finally:
        en.close()


def test_user_entries_before_after():
    # A dedicated analyzer: the merge mutates its target, and the
    # session-scoped `analyzer` fixture stays read-only for the rest of
    # the suite.
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    try:
        before = a.tokenize("犬助が歩く")
        # before the merge, 犬助 is not a dictionary surface: the known
        # 犬 splits the run and 助 arrives as an unknown
        assert [m.surface for m in before] == ["犬", "助", "が", "歩く"]
        assert before[1].is_unknown
        a.add_user_entries(
            [moli.UserEntry(surface="犬助", pos="名詞,固有名詞", lemma="*", reading="ケンスケ", cost=-3000)]
        )
        after = a.tokenize("犬助が歩く")
        assert after[0].surface == "犬助"
        assert after[0].reading == "ケンスケ"
        assert not after[0].is_unknown
        # pre-existing entries keep answering
        plain = a.tokenize("犬が歩く")
        assert [m.surface for m in plain] == ["犬", "が", "歩く"]
        # empty surface rejects the batch
        with pytest.raises(moli.LoadError):
            a.add_user_entries([moli.UserEntry(surface="")])
    finally:
        a.close()


def test_stats(resources_analyzer):
    st = resources_analyzer.stats()
    assert st.entries > 0
    assert st.terminals > 0
    assert st.cedar_nodes >= st.terminals
    assert st.unk_rules > 0
    assert st.matrix_left > 0 and st.matrix_right > 0
    assert st.matrix_cells == st.matrix_left * st.matrix_right
    assert 0.0 < st.matrix_density <= 1.0
    assert isinstance(st.entries_hash, int) and st.entries_hash >= 0
    assert isinstance(st.skipped, list)


def test_snapshot_and_qdct_roundtrip(analyzer):
    snap = analyzer.snapshot()
    assert snap[:4] == b"QDCT"

    # buffer reuse after load_qdct_bytes is safe (the one-copy rule)
    buf = bytearray(snap)
    reloaded = moli.load_qdct_bytes(buf)
    try:
        buf[0:4] = b"XXXX"  # caller buffer is no longer referenced
        assert [m.surface for m in reloaded.tokenize("犬が歩く")] == ["犬", "が", "歩く"]
    finally:
        reloaded.close()


def test_mmap_load(analyzer, tmp_path):
    path = tmp_path / "model.qdct"
    analyzer.save_qdct(str(path))
    a = moli.load_qdct_mmap(str(path))
    try:
        assert [m.surface for m in a.tokenize("犬が歩く")] == ["犬", "が", "歩く"]
    finally:
        a.close()


def test_save_qdct_write_error(analyzer, tmp_path):
    # A directory path cannot be written: the failure crosses the ABI
    # as the IO_Write code and surfaces here as SaveError, with nothing
    # half-written left behind (the Odin suite's save-write-error leg
    # is the twin of this one).
    with pytest.raises(moli.SaveError):
        analyzer.save_qdct(str(tmp_path))


def test_cross_language_qdct_byte_identity():
    """The Python snapshot of the fixture must be byte-identical to the
    committed golden (tests/fixtures/qdct_ref_snapshot.qdct) — the same
    bytes the Odin ABI suite's save_qdct must write, so both
    implementations of the snapshot path are pinned to one image with
    no run-order coupling between the suites."""
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    try:
        assert a.snapshot() == QDCT_GOLDEN.read_bytes()
    finally:
        a.close()


def test_clone_independence(analyzer):
    clone = analyzer.clone()
    try:
        assert [m.surface for m in clone.tokenize("犬が歩く")] == ["犬", "が", "歩く"]
    finally:
        clone.close()
    # the original outlives the clone's close
    assert [m.surface for m in analyzer.tokenize("犬が歩く")] == ["犬", "が", "歩く"]


def test_load_errors():
    with pytest.raises(moli.LoadError) as ei:
        moli.load(moli.Language.Japanese, "/no/such/file.csv")
    assert not isinstance(ei.value, moli.SchemaMismatchError)

    with pytest.raises(ValueError):
        moli.load(99, str(IPADIC))

    with pytest.raises(moli.LoadError):
        moli.load_qdct_bytes(b"garbage")


def test_load_read_error(tmp_path):
    # A directory opens but cannot be read: the read failure surfaces
    # as a plain LoadError (the IO_Read code), not a crash.
    with pytest.raises(moli.LoadError):
        moli.load(moli.Language.Japanese, str(tmp_path))


def test_load_bytes_path(analyzer):
    data = IPADIC.read_bytes()
    a = moli.load_bytes(moli.Language.Japanese, data)
    try:
        assert [m.surface for m in a.tokenize("犬が歩く")] == ["犬", "が", "歩く"]
    finally:
        a.close()
