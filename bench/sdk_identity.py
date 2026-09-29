#!/usr/bin/env python3
"""Identity digest for SDK build comparison (numbers only).

Tokenizes a fixed sentence pool — valid Japanese, mixed script,
unknown-heavy kanji, ASCII, malformed bytes, the empty string — through
every result shape, then folds repr() of each result into one sha256.
Two builds of the extension are output-identical exactly when their
digests match; the cross-field checks (wakati == ' '.join(wakachi),
parse vs tokenize TSV) would fail loudly inside a single build first.

    python3 bench/sdk_identity.py <sdk-src-root>
"""

import hashlib
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])

import moli  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = REPO_ROOT / "tmp" / "sdk_ab" / "ipadic.qdct"
FRESH_CSV = REPO_ROOT / "dict" / "ipadic-utf8" / "lex.csv"


def assert_snapshot_fresh():
    """The digest folds stats() (entries_hash included), so a snapshot
    an older tree produced would change it silently: compare the
    fingerprint against a fresh CSV load through this build first."""
    a = moli.load_qdct_mmap(str(SNAPSHOT))
    snap_hash = a.stats().entries_hash
    a.close()
    b = moli.load(moli.Language.Japanese, str(FRESH_CSV))
    fresh_hash = b.stats().entries_hash
    b.close()
    if snap_hash != fresh_hash:
        raise SystemExit(
            f"stale snapshot {SNAPSHOT}: entries_hash {snap_hash:#x} != "
            f"fresh {fresh_hash:#x} (run: just bench-snapshots)")

POOL = [
    "東京都は二十五日、新型コロナウイルスの感染者数が過去最多を更新したと発表した。",
    "政府は来年度予算案の編成に向け、歳出改革の議論を本格化させる方針だ。",
    "駅前の新しい図書館は来月一日に開館する。",
    "彼女はヴェルタース地方の雑木林を訪ねた。",
    "最新の観測データによれば、地震活動は沈静化しつつある。",
    "𠮷野家の看板が見える。",  # supplementary-plane kanji
    "東京都ABCです。半角ｶﾀｶﾅとemoji😀も混ぜる。",
    "the colour of defence — mixed ascii prose",
    "",
]
BAD_BYTES = b"\xff\xfe\x81z" + POOL[0].encode()


def main():
    assert_snapshot_fresh()
    a = moli.load_qdct_mmap(str(SNAPSHOT))
    h = hashlib.sha256()
    total = 0
    for txt in POOL:
        for m in a.tokenize(txt):
            h.update(repr(m).encode())
            total += 1
        h.update(repr(a.wakachi(txt)).encode())
        h.update(repr(a.wakati(txt)).encode())
        h.update(repr(a.parse(txt)).encode())
        h.update(repr(a.spans(txt)).encode())
        h.update(repr(a.classify_locale(txt)).encode())
        for p in a.nbest(txt, k=3):
            h.update(repr(p).encode())
        # cross-field identities (single-build sanity; raise on drift)
        assert " ".join(a.wakachi(txt)) == a.wakati(txt)
        lines = a.parse(txt).split("\n") if txt else []
        toks = a.tokenize(txt)
        assert len(lines) == len(toks)
        for line, m in zip(lines, toks):
            assert line == "\t".join(
                [m.surface, m.pos, m.lemma, m.reading, m.reading_jyutping])
        # keyword-call shape must agree with positional (list() because
        # tokenize returns the lazy Morphemes view)
        assert list(a.tokenize(text=txt, unk_cost_bias=0, normalize_nfc=False,
                               strict_utf8=False)) == list(toks)
    for m in a.tokenize(BAD_BYTES):
        h.update(repr(m).encode())
        total += 1
    # tuned-cost and bytes-input results are hashed as materialized
    # lists: the view's own repr is a summary, not the values
    h.update(repr(list(a.tokenize(BAD_BYTES, unk_cost_bias=100,
                                  unk_cost_per_rune=50))).encode())
    h.update(repr(list(a.tokenize(POOL[0].encode()))).encode())  # bytes input
    st = a.stats()
    h.update(repr(st).encode())
    a.close()
    print(f"digest {h.hexdigest()} morphemes={total}")


if __name__ == "__main__":
    main()
