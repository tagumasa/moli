"""The extension's argument surface: the load family's keyword
strings, duck-typed UserEntry objects, constraint sequences, and the
code-carrying ConstraintError payload. These pin the C-side reference
discipline (call-duration strong references, embedded-NUL rejection,
object-typed keyword parsing) from the Python side."""

import pytest

import moli
from moli import ConstraintReason

from conftest import FIXTURES, IPADIC


@pytest.fixture(scope="module")
def an():
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    yield a
    a.close()


# --- the load family's five path keywords ---------------------------

# The four sibling resources are optional: an explicit path that does
# not exist degrades exactly like an absent sibling (recorded in
# stats().skipped), so every value shape loads and tokenizes.
SIBLING_KWS = [
    "unk_def_path", "char_def_path", "matrix_def_path", "qpat_path",
]


@pytest.mark.parametrize("kw", SIBLING_KWS)
def test_load_path_kw_accepts_none_str_bytes(kw, tmp_path):
    missing = str(tmp_path / "no-such-resource")
    for value in (None, missing, missing.encode()):
        a = moli.load(moli.Language.Japanese, str(IPADIC), **{kw: value})
        try:
            assert [m.surface for m in a.tokenize("犬が歩く")] == ["犬", "が", "歩く"]
        finally:
            a.close()


def test_load_jyutping_donor_kw(tmp_path):
    # jyutping_csv_path is the explicit-only donor CSV of the ZH
    # two-file flow: no sibling discovery, so a missing donor fails
    # the load (str or bytes alike), and the real donor loads.
    merge_cn = FIXTURES / "jieba_merge_cn.csv"
    merge_hk = FIXTURES / "jieba_merge_hk.csv"
    missing = str(tmp_path / "no-such-donor.csv")
    for value in (missing, missing.encode()):
        with pytest.raises(moli.LoadError):
            moli.load(moli.Language.ChineseCN, str(merge_cn),
                      jyutping_csv_path=value)
    a = moli.load(moli.Language.ChineseCN, str(merge_cn),
                  jyutping_csv_path=str(merge_hk))
    try:
        assert a.stats().entries > 0
    finally:
        a.close()


def test_load_resource_kw_roundtrip():
    # Pointing char_def_path at a real file removes "char.def" from
    # the skipped list: the keyword actually reached the library (a
    # plain load of this fixture skips every sibling).
    char_def = IPADIC.parent / "resources" / "char.def"
    a = moli.load(moli.Language.Japanese, str(IPADIC), char_def_path=str(char_def))
    try:
        assert "char.def" not in a.stats().skipped
    finally:
        a.close()


def test_load_path_kw_rejects_wrong_type():
    with pytest.raises(TypeError):
        moli.load(moli.Language.Japanese, str(IPADIC), unk_def_path=123)


# --- duck-typed UserEntry objects ------------------------------------


class PropertyEntry:
    """Every string attribute is a fresh object per read (a @property
    building on the fly): the ABI call must keep them alive itself."""

    def __init__(self, surface, reading):
        self._surface, self._reading = surface, reading

    @property
    def surface(self):
        return self._surface + ""

    @property
    def pos(self):
        return "名詞,固有名詞"

    @property
    def lemma(self):
        return "*"

    @property
    def reading(self):
        return self._reading + ""

    @property
    def reading_jyutping(self):
        return None

    left_id = 0
    right_id = 0
    cost = -3000


def test_add_user_entries_property_objects(an):
    an.add_user_entries([PropertyEntry("犬助", "ケンスケ")])
    ms = list(an.tokenize("犬助"))
    assert [m.surface for m in ms] == ["犬助"]
    assert ms[0].reading == "ケンスケ"


def test_add_user_entries_rejects_non_str_field(an):
    class Bad:
        surface = 123
        pos = lemma = reading = reading_jyutping = ""

        left_id = right_id = cost = 0

    with pytest.raises(TypeError, match="UserEntry.surface"):
        an.add_user_entries([Bad()])


def test_add_user_entries_rejects_embedded_nul(an):
    with pytest.raises(ValueError, match="NUL"):
        an.add_user_entries([moli.UserEntry(surface="犬\x00助")])
    with pytest.raises(ValueError, match="NUL"):
        an.add_user_entries([moli.UserEntry(surface="犬助", pos="名詞\x00")])


# --- constraint sequences --------------------------------------------


class SeqEntry:
    """A non-list/tuple sequence: the extension materializes it into a
    fresh list that dies with the item — the pos string inside must be
    held independently for the whole call."""

    def __init__(self, items):
        self._items = items

    def __len__(self):
        return len(self._items)

    def __getitem__(self, i):
        return self._items[i]


def test_constrained_non_fast_sequences(an):
    # tokens as a generator (materialized by the extension) whose
    # items are themselves non-fast sequences carrying a runtime-built
    # pos string: both materializations die mid-loop, so the pos bytes
    # must survive until the ABI call returns — and the pin still
    # flips the さくら homograph, proving the string arrived intact.
    p = "名詞"

    def gen():
        yield SeqEntry((0, 9, p + ",固有名詞"))

    ms = list(an.tokenize_constrained("さくらの花見", tokens=gen()))
    assert ms[0].pos == "名詞,固有名詞,一般"


def test_constrained_rejects_non_str_pos(an):
    with pytest.raises(TypeError, match="token constraint pos"):
        an.tokenize_constrained("さくらの花見", tokens=[(0, 9, 123)])


def test_constrained_rejects_embedded_nul_pos(an):
    with pytest.raises(ValueError, match="NUL"):
        an.tokenize_constrained("さくらの花見", tokens=[(0, 9, "名詞\x00")])


def test_constrained_rejects_non_sequence_tokens(an):
    with pytest.raises(TypeError, match="sequence"):
        an.tokenize_constrained("さくらの花見", tokens=123)


# --- ConstraintError carries its reason as code ----------------------


@pytest.mark.parametrize(
    ("tokens", "boundaries", "reason"),
    [
        ([(0, 9999)], [], ConstraintReason.OUT_OF_BOUNDS),
        ([(0, 0)], [], ConstraintReason.EMPTY_SPAN),
        ([(1, 9)], [], ConstraintReason.NOT_RUNE_BOUNDARY),
        ([(0, 9), (6, 12)], [], ConstraintReason.TOKEN_OVERLAP),
        ([(0, 9, ",名詞")], [], ConstraintReason.BAD_POS_PATTERN),
        # The boundary-interaction legs: a boundary required inside a
        # pinned token, one forbidden at its edge, and two boundaries
        # contradicting each other (the Odin suite covers the full
        # table; these pin the enum mirror's remaining members).
        ([(0, 9)], [(3, True)], ConstraintReason.BOUNDARY_INSIDE_TOKEN),
        ([(0, 9)], [(9, False)], ConstraintReason.BOUNDARY_AT_TOKEN_EDGE),
        ([], [(3, True), (3, False)], ConstraintReason.CONFLICTING_BOUNDARIES),
    ],
)
def test_constraint_error_reason(an, tokens, boundaries, reason):
    with pytest.raises(moli.ConstraintError) as ei:
        an.tokenize_constrained("さくらの花見", tokens=tokens, boundaries=boundaries)
    # A plain int on the C side; the IntEnum members compare equal to
    # it, and the ordinal block of the ABI check pins the mapping.
    assert ei.value.reason == reason
    assert type(ei.value.reason) is int


# --- save_qdct's path is required -------------------------------------


def test_save_qdct_requires_path(an):
    with pytest.raises(TypeError, match="path is required"):
        an.save_qdct(None)


# --- the docstrings' keyword-only markers are enforced ----------------


def test_options_are_keyword_only(an):
    # tokenize/nbest/constrained docstrings pin everything past the
    # leading parameters with a '*'; the parser rejects positionals
    # in the option slots.
    with pytest.raises(TypeError, match="keyword-only"):
        an.tokenize("犬が歩く", 500)
    with pytest.raises(TypeError, match="keyword-only"):
        an.nbest("犬が歩く", 3, 7)
    with pytest.raises(TypeError, match="keyword-only"):
        an.tokenize_constrained("さくらの花見", [], [], 5)
    with pytest.raises(TypeError, match="keyword-only"):
        an.wakachi("犬が歩く", 1)
    # the leading parameters themselves stay positional (this text has
    # one Viterbi path, so nbest returns fewer than k paths)
    assert 1 <= len(an.nbest("犬が歩く", 3)) <= 3
    assert len(an.tokenize_constrained("さくらの花見", (), ())) >= 1


def test_options_still_bind_by_keyword(an):
    ms = an.tokenize("犬が歩く", unk_cost_bias=500)
    assert [m.surface for m in ms] == ["犬", "が", "歩く"]
    assert 1 <= len(an.nbest("犬が歩く", k=3)) <= 3


# --- error messages survive non-UTF-8 bytes ---------------------------


def test_bytes_path_failure_raises_the_mapped_class(tmp_path):
    # A bytes path may carry non-UTF-8 bytes; the failure that echoes
    # it must still surface as the mapped moli exception, not as a
    # UnicodeDecodeError from decoding the message.
    raw = b"\xff\xfe/nonexistent-\xff.csv"
    with pytest.raises(moli.LoadError):
        moli.load(moli.Language.Japanese, raw)
