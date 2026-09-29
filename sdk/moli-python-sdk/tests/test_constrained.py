"""tokenize_constrained: the SDK face of the constraint mask."""

import pytest

import moli


def test_empty_set_matches_plain(analyzer):
    text = "さくらの花見と未登録語"
    plain = [(m.surface, m.pos, m.start, m.end) for m in analyzer.tokenize(text)]
    cons = [
        (m.surface, m.pos, m.start, m.end)
        for m in analyzer.tokenize_constrained(text)
    ]
    assert cons == plain


def test_pos_pin_flips_homograph(analyzer):
    # The fixture's さくら is a homograph pair (名詞,一般 beats
    # 名詞,固有名詞,一般 on cost); pinning the span under the
    # 固有名詞 prefix flips the winner without touching the rest.
    text = "さくらの花見"
    plain = [m.pos for m in analyzer.tokenize(text)]
    assert plain[0] == "名詞,一般"

    pinned = list(
        analyzer.tokenize_constrained(
            text, tokens=[moli.TokenConstraint(0, 9, "名詞,固有名詞")]
        )
    )
    assert [m.surface for m in pinned] == [m.surface for m in analyzer.tokenize(text)]
    assert pinned[0].pos == "名詞,固有名詞,一般"
    assert pinned[0].start == 0 and pinned[0].end == 9

    # the plain tuple shape works too: (start, end, pos)
    tupled = list(analyzer.tokenize_constrained(text, tokens=[(0, 9, "名詞,固有名詞")]))
    assert [m.pos for m in tupled] == [m.pos for m in pinned]

    # "" and None both mean any POS: the cheaper homograph wins again
    any_pin = list(analyzer.tokenize_constrained(text, tokens=[(0, 9)]))
    assert any_pin[0].pos == "名詞,一般"


def test_boundary_constraints(analyzer):
    # どず is an unknown Hiragana run whose grouped candidate is the
    # plain winner (one node beats two plus an edge); requiring a
    # boundary inside it drops the grouping and the two singles win.
    plain = [m.surface for m in analyzer.tokenize("どず")]
    assert plain == ["どず"]

    forced = [
        m.surface
        for m in analyzer.tokenize_constrained("どず", boundaries=[(3, True)])
    ]
    assert forced == ["ど", "ず"]

    # a boundary that already exists is affirmed, not fought: the
    # plain result comes back unchanged.
    same = [
        m.surface
        for m in analyzer.tokenize_constrained("さくらの花見", boundaries=[(9, True)])
    ]
    assert same == [m.surface for m in analyzer.tokenize("さくらの花見")]


def test_bad_constraint_payload(analyzer):
    with pytest.raises(moli.ConstraintError) as ei:
        analyzer.tokenize_constrained("さくらの花見", tokens=[(0, 5)])
    e = ei.value
    assert e.index == 0 and e.start == 0 and e.end == 5

    with pytest.raises(moli.ConstraintError) as ei2:
        analyzer.tokenize_constrained(
            "さくらの花見",
            tokens=[(0, 9), (3, 12)],
        )
    assert ei2.value.index == 1  # the later token carries the overlap


def test_unsatisfiable_offset(analyzer):
    # 東京 is a single entry and nothing else ends mid-span; forcing a
    # boundary at byte 3 empties that position.
    with pytest.raises(moli.UnsatisfiableError) as ei:
        analyzer.tokenize_constrained("東京", boundaries=[(3, True)])
    assert ei.value.byte_offset == 3


def test_nfc_rescale_rejected(analyzer):
    # が decomposed is か + U+3099: normalization removes bytes the
    # constraint offsets index, so the call faults instead of
    # re-reading offsets against a different string.
    nfd = "さくらか\u3099"
    with pytest.raises(moli.ConstraintError):
        analyzer.tokenize_constrained(
            nfd, tokens=[(9, 15)], normalize_nfc=True
        )
    # already-composed text keeps its offsets under the same flag
    ok = list(
        analyzer.tokenize_constrained(
            "さくらが", boundaries=[(9, True)], normalize_nfc=True
        )
    )
    assert [m.surface for m in ok] == ["さくら", "が"]


def test_options_still_apply(analyzer):
    # The shared option surface rides along: strict UTF-8 rejection
    # happens before any constraint work. A str would re-encode its
    # lone control codepoint into valid UTF-8, so the test feeds raw
    # bytes.
    bad = "さくら".encode() + b"\x81" + "咲く".encode()
    with pytest.raises(moli.MalformedInputError) as ei:
        analyzer.tokenize_constrained(bad, tokens=[(0, 9)], strict_utf8=True)
    assert ei.value.byte_offset == 9
