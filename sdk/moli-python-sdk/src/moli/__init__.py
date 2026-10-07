"""moli — morphological analysis for Python, over the libmoli C ABI.

The public surface mirrors the analysis library one-to-one: the load
family (MeCab CSV by path or bytes, ``.qdct`` snapshots by file, mmap,
or bytes), the tokenize family (morphemes, wakachi, the single-string
presentations ``wakati`` and ``parse``, spans, n-best, cancellation,
NFC normalisation, strict UTF-8, unknown-cost tuning,
``tokenize_constrained`` for partial-knowledge input), snapshots
(``save_qdct``, ``snapshot``, ``clone``), ``stats``,
``add_user_entries``, ``classify_locale``, and the chunking helper
``safe_chunks`` (the safe-cut rule over ``str``).

The tokenize family runs concurrently on one shared ``Analyzer``;
``add_user_entries`` mutates the analyzer and is serialized by the
wrapper (one merge at a time), and ``stats`` takes the same lane.
String-shaped results (``wakachi``, ``wakati``, ``parse``, ``spans``)
are plain Python values built eagerly. ``tokenize`` returns a
:class:`Morphemes` view: a lazy immutable ``Sequence`` of
:class:`Morpheme` that materializes values on access, keeps its
native result alive until the last morpheme is read (then releases
it), and carries no lifetime coupling to the analyzer or to later
calls — ``list(t)`` gives the eager list. Calls after ``close()``
raise :class:`UnavailableError`; close analysers with ``close()``
(idempotent, safe to race), a ``with`` block, or by dropping the last
reference.

The native module verifies its ABI layout mirror against the library
at import time — an extension/library mismatch fails the import, never
the first tokenize.
"""

from enum import IntEnum
from typing import List, NamedTuple

from . import _native
from ._native import (
    Analyzer,
    CancelToken,
    Morphemes,
    MoliError,
    LoadError,
    SchemaMismatchError,
    OutOfMemoryError,
    UnavailableError,
    MalformedInputError,
    CancelledError,
    ConstraintError,
    UnsatisfiableError,
    SaveError,
)

__version__ = "0.1.1"


class Language(IntEnum):
    """Dictionary language; ordinals are the ABI's stable contract."""

    Japanese = _native.MOLI_LANG_JAPANESE
    ChineseCN = _native.MOLI_LANG_CHINESE_CN
    ChineseTW = _native.MOLI_LANG_CHINESE_TW
    ChineseHK = _native.MOLI_LANG_CHINESE_HK
    EnglishGB = _native.MOLI_LANG_ENGLISH_GB
    EnglishUS = _native.MOLI_LANG_ENGLISH_US
    German = _native.MOLI_LANG_GERMAN


class Locale(IntEnum):
    """Variant locale (lemma rewriting at load, classification out).
    ``NONE`` is the ABI's zero member "None" — no locale."""

    NONE = _native.MOLI_LOCALE_NONE
    CN = _native.MOLI_LOCALE_CN
    TW = _native.MOLI_LOCALE_TW
    HK = _native.MOLI_LOCALE_HK
    GB = _native.MOLI_LOCALE_GB
    US = _native.MOLI_LOCALE_US


class Mode(IntEnum):
    """Analysis mode: ``Viterbi`` (the connected-cost lattice search)
    or ``LongestMatch`` (greedy longest-match, no lattice)."""

    Viterbi = _native.MOLI_MODE_VITERBI
    LongestMatch = _native.MOLI_MODE_LONGESTMATCH


class CharClass(IntEnum):
    """A rune's built-in classification (the char.def classes):
    :attr:`Morpheme.char_class`, and the grouping unknown runs are
    emitted under."""

    Unknown = _native.MOLI_CLASS_UNKNOWN
    Hiragana = _native.MOLI_CLASS_HIRAGANA
    Katakana = _native.MOLI_CLASS_KATAKANA
    Kanji = _native.MOLI_CLASS_KANJI
    Hanzi = _native.MOLI_CLASS_HANZI
    HalfwidthKatakana = _native.MOLI_CLASS_HALFWIDTH_KATAKANA
    Bopomofo = _native.MOLI_CLASS_BOPOMOFO
    ASCIILetter = _native.MOLI_CLASS_ASCII_LETTER
    Digit = _native.MOLI_CLASS_DIGIT
    Punct = _native.MOLI_CLASS_PUNCT
    Space = _native.MOLI_CLASS_SPACE
    Symbol = _native.MOLI_CLASS_SYMBOL
    Emoji = _native.MOLI_CLASS_EMOJI


class ConstraintReason(IntEnum):
    """Why :exc:`ConstraintError` rejected a constraint set — the
    ``reason`` attribute on the exception, crossed from the ABI as a
    code; ordinals are the ABI's stable contract."""

    OUT_OF_BOUNDS = _native.MOLI_REASON_OUT_OF_BOUNDS
    EMPTY_SPAN = _native.MOLI_REASON_EMPTY_SPAN
    NOT_RUNE_BOUNDARY = _native.MOLI_REASON_NOT_RUNE_BOUNDARY
    TOKEN_OVERLAP = _native.MOLI_REASON_TOKEN_OVERLAP
    BOUNDARY_INSIDE_TOKEN = _native.MOLI_REASON_BOUNDARY_INSIDE_TOKEN
    BOUNDARY_AT_TOKEN_EDGE = _native.MOLI_REASON_BOUNDARY_AT_TOKEN_EDGE
    CONFLICTING_BOUNDARIES = _native.MOLI_REASON_CONFLICTING_BOUNDARIES
    BAD_POS_PATTERN = _native.MOLI_REASON_BAD_POS_PATTERN
    NORMALIZATION_RESCALED = _native.MOLI_REASON_NORMALIZATION_RESCALED


class Morpheme(NamedTuple):
    """One analysed token. ``start``/``end`` are byte offsets into the
    input (the UTF-8 encoding, when the input was ``str``)."""

    surface: str
    pos: str
    lemma: str
    reading: str
    reading_jyutping: str
    cost: int
    start: int
    end: int
    locale: Locale
    char_class: CharClass
    is_unknown: bool
    entry_id: int


class Span(NamedTuple):
    """A surface with its byte offsets (``spans()`` output)."""

    surface: str
    start: int
    end: int


class NBestPath(NamedTuple):
    """One n-best segmentation: total cost plus its morphemes."""

    cost: int
    morphemes: List[Morpheme]


class AnalyzerStats(NamedTuple):
    """Analyzer inventory; ``skipped`` names optional resources that
    were absent at load. ``entries_hash`` fingerprints the resolved
    dictionary rows — a dictionary-version detector: any
    ``add_user_entries`` merge changes it, and a changed hash
    invalidates every ``entry_id`` taken earlier."""

    entries: int
    terminals: int
    cedar_nodes: int
    unk_rules: int
    unk_patterns: int
    matrix_left: int
    matrix_right: int
    matrix_cells: int
    matrix_explicit: int
    matrix_density: float
    entries_hash: int
    skipped: List[str]


class TokenConstraint(NamedTuple):
    """A span the constrained search must emit as exactly one
    morpheme: ``start``/``end`` are byte offsets into the text (the
    UTF-8 bytes of a str), and ``pos`` is a comma-separated POS-column
    prefix (``"名詞"`` matches ``"名詞,一般"``); the empty string accepts
    any POS the span's candidates carry. Use
    ``tokenize_constrained(text, tokens=[...])``."""

    start: int
    end: int
    pos: str = ""


class BoundaryConstraint(NamedTuple):
    """One byte offset where the winning segmentation must
    (``must_exist=True``) or must not (``must_exist=False``) place a
    morpheme boundary. Use ``tokenize_constrained(text,
    boundaries=[...])`."""

    at: int
    must_exist: bool


class UserEntry(NamedTuple):
    """A caller-supplied dictionary row merged by ``add_user_entries``.
    String fields default to the empty string; ids and cost to 0."""

    surface: str
    pos: str = ""
    lemma: str = ""
    reading: str = ""
    reading_jyutping: str = ""
    left_id: int = 0
    right_id: int = 0
    cost: int = 0


# Hand the value/enum types to the extension so its results are built
# as these types directly (no double wrapping).
_native._set_value_types(Morpheme, Span, NBestPath, AnalyzerStats, Locale, CharClass)


def load(lang, path, **opts) -> Analyzer:
    """Load a MeCab-format CSV dictionary.

    ``lang`` is a :class:`Language` (or its ordinal). Optional keyword
    arguments: ``mode`` (:class:`Mode`), ``threads`` (parallel matrix
    parse; 0/1 = serial), ``lemma_locale`` (:class:`Locale` lemma
    rewriting), ``unk_def_path``/``char_def_path``/``matrix_def_path``/
    ``qpat_path``/``jyutping_csv_path`` (resource overrides; None =
    sibling discovery or omit), ``flat_char_class``.
    """
    return _native.load(lang, path, **opts)


def load_bytes(lang, data, **opts) -> Analyzer:
    """Load a MeCab-format CSV dictionary from bytes (borrowed; no
    copy is made at the boundary)."""
    return _native.load_bytes(lang, data, **opts)


def load_qdct(path) -> Analyzer:
    """Load a ``.qdct`` snapshot file (read-copy)."""
    return _native.load_qdct(path)


def load_qdct_mmap(path) -> Analyzer:
    """Load a ``.qdct`` snapshot through a read-only mapping (the
    zero-extra-copy deploy path; POSIX)."""
    return _native.load_qdct_mmap(path)


def load_qdct_bytes(data) -> Analyzer:
    """Load a ``.qdct`` snapshot from bytes. The image is copied once
    (the library takes ownership of its buffer); the caller's buffer
    is free to change or die afterwards."""
    return _native.load_qdct_bytes(data)


def abi_version() -> int:
    """The C ABI version the native library speaks."""
    return _native.abi_version()


def native_version() -> str:
    """The native library version string."""
    return _native.version()


# The library's safe-cut run set: char_class.odin's SPACE_* constants
# (the control run [0x09, 0x0E) plus 0x20 — SO, 0x0E, is not a
# member). Tests pin the set.
_WHITESPACE_RUN_BYTES = frozenset(b"\t\n\v\f\r ")


def safe_chunks(text, target_bytes):
    """Split ``text`` into chunks that tokenize independently.

    Implements the library's documented safe-cut rule: a cut is placed
    only immediately after a whitespace run that ends with a newline —
    never inside a CRLF pair, never between a newline run and the
    spaces extending it — so no morpheme is split for dictionaries
    whose surfaces contain no LF byte (every shipped dictionary).
    Concatenating the per-chunk morpheme sequences reproduces the
    single call's output exactly in practice; that identity is
    empirical, not a theorem (each chunk restarts BOS/EOS context).

    ``target_bytes`` is measured on the UTF-8 encoding, the basis of
    :attr:`Morpheme.start`/:attr:`Morpheme.end`. Every chunk but the
    last is at least ``target_bytes`` bytes; values below 1 are treated
    as 1; a document with no safe cut — including the empty document —
    is returned as one chunk. The input is encoded once and the chunks
    are new strings.
    """
    data = text.encode("utf-8")
    target = max(target_bytes, 1)
    cuts = []
    start = 0
    for i in range(1, len(data)):
        if data[i - 1] != 0x0A or data[i] in _WHITESPACE_RUN_BYTES:
            continue
        if i - start < target:
            continue
        cuts.append(i)
        start = i
    pieces = []
    prev = 0
    for c in cuts:
        pieces.append(data[prev:c].decode("utf-8"))
        prev = c
    if prev < len(data) or not cuts:
        pieces.append(data[prev:].decode("utf-8"))
    return pieces


# ASCII order — an addition has exactly one place, no grouping to
# keep current.
__all__ = [
    "Analyzer", "AnalyzerStats", "BoundaryConstraint", "CancelToken",
    "CancelledError", "CharClass", "ConstraintError", "ConstraintReason",
    "Language", "LoadError", "Locale", "MalformedInputError",
    "Mode", "MoliError", "Morpheme", "Morphemes",
    "NBestPath", "OutOfMemoryError", "SaveError", "SchemaMismatchError",
    "Span", "TokenConstraint", "UnavailableError", "UnsatisfiableError",
    "UserEntry", "abi_version", "load", "load_bytes",
    "load_qdct", "load_qdct_bytes", "load_qdct_mmap", "native_version",
    "safe_chunks",
]
