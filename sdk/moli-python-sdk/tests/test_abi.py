"""Import-time ABI checks and enum mirrors."""

import tomllib
from pathlib import Path

import moli
from moli import _native


def test_version_agreement():
    # The version string lives in three files on purpose (pyproject
    # packaging, the Python surface, the library's moli_version); this
    # tripwire makes drift fail the suite instead of shipping.
    pyproject = Path(__file__).resolve().parents[1] / "pyproject.toml"
    version = tomllib.loads(pyproject.read_text())["project"]["version"]
    assert version == moli.__version__ == moli.native_version()


def test_abi_version_and_string():
    assert moli.abi_version() == 7
    assert isinstance(moli.native_version(), str)
    assert moli.native_version()


def test_import_ran_layout_check():
    # The import itself is the assertion: the extension compared all
    # moli_abi_check slots (layouts, member counts, and per-member
    # ordinals) against its compiled-in mirror and would have failed
    # to import on any mismatch.
    assert _native.MOLI_ABI_VERSION == 7


def test_enum_ordinals_match_the_abi():
    # The ABI contract is the library's declaration order.
    assert [e.value for e in moli.Language] == list(range(7))
    assert [e.value for e in moli.Locale] == list(range(6))
    assert [e.value for e in moli.Mode] == list(range(2))
    assert [e.value for e in moli.CharClass] == list(range(13))
    assert [e.value for e in moli.ConstraintReason] == list(range(9))
    assert moli.Language.Japanese == _native.MOLI_LANG_JAPANESE
    assert moli.Locale.GB == _native.MOLI_LOCALE_GB
    assert moli.Mode.LongestMatch == _native.MOLI_MODE_LONGESTMATCH
    assert moli.CharClass.Emoji == _native.MOLI_CLASS_EMOJI
    assert moli.ConstraintReason.BAD_POS_PATTERN == _native.MOLI_REASON_BAD_POS_PATTERN


def test_exceptions_hierarchy():
    for exc in (
        moli.LoadError,
        moli.SchemaMismatchError,
        moli.OutOfMemoryError,
        moli.UnavailableError,
        moli.MalformedInputError,
        moli.CancelledError,
        moli.SaveError,
    ):
        assert issubclass(exc, moli.MoliError)
        assert issubclass(exc, Exception)
