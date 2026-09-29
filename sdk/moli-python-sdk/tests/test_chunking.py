"""safe_chunks: the SDK mirror of the library's safe-cut rule."""

import moli

RULE_CASES = [
    ("AA\n\nBB\n\nCC", 1, ["AA\n\n", "BB\n\n", "CC"]),
    ("AA\n\nBB\n\nCC", 5, ["AA\n\nBB\n\n", "CC"]),
    # a target past any gap defers to the single chunk
    ("AA\n\nBB\n\nCC", 64, ["AA\n\nBB\n\nCC"]),
    # targets below 1 clamp to 1
    ("AA\n\nBB\n\nCC", 0, ["AA\n\n", "BB\n\n", "CC"]),
    ("AA\n\nBB\n\nCC", -3, ["AA\n\n", "BB\n\n", "CC"]),
    # CRLF blank lines cut after each complete "\r\n\r\n" run
    ("\r\n\r\nX\r\n\r\nY", 1, ["\r\n\r\n", "X\r\n\r\n", "Y"]),
    # a space extending a newline run keeps it whole
    ("A\n\n B\n\nC", 1, ["A\n\n B\n\n", "C"]),
    ("A\n\tB", 1, ["A\n\tB"]),
    # no newline / all whitespace / empty: one chunk
    ("ABC", 1, ["ABC"]),
    ("\n\n\n", 1, ["\n\n\n"]),
    ("", 1, [""]),
]


def test_rule_table():
    for text, target, want in RULE_CASES:
        got = moli.safe_chunks(text, target)
        assert got == want, (text, target, got, want)
        assert "".join(got) == text


def test_target_is_measured_in_bytes():
    # four CJK chars are 12 UTF-8 bytes; the separator adds 2, so the
    # only cut sits 14 bytes in: target 14 cuts, target 15 defers
    text = "東京都は\n\n大阪府は"
    assert moli.safe_chunks(text, 14) == ["東京都は\n\n", "大阪府は"]
    assert moli.safe_chunks(text, 15) == [text]


def test_identity_against_engine(analyzer):
    text = (
        "古い時計塔の針が七時を指す。\n\n"
        "ヴェルダナートの森は雪に覆われていた。\n\n"
        "セレステは黙って頷いた。\n\n"
    ) * 3
    pieces = moli.safe_chunks(text, 1)
    assert "".join(pieces) == text
    full = [(m.surface, m.pos) for m in analyzer.tokenize(text)]
    folded = [
        (m.surface, m.pos)
        for p in pieces
        for m in analyzer.tokenize(p)
    ]
    assert folded == full


def test_run_set_matches_library():
    # char_class.odin's SPACE_* constants: [0x09, 0x0E) + 0x20 — SO
    # (0x0E) is not a run byte, and this pin keeps the mirror honest.
    assert moli._WHITESPACE_RUN_BYTES == frozenset(b"\t\n\v\f\r ")
    assert 0x0E not in moli._WHITESPACE_RUN_BYTES


def test_so_byte_ends_the_run():
    # 0x0E (SO) is not a run byte, so a newline-terminated run ends
    # before it and the cut the library's rule makes is made here too.
    text = "A" * 40 + "\n\x0e" + "B" * 40
    assert moli.safe_chunks(text, 30) == ["A" * 40 + "\n", "\x0e" + "B" * 40]
