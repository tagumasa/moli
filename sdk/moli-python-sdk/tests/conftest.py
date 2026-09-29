"""Shared fixtures: the repository's committed test dictionaries.

The fixture directory is the repository's tests/fixtures, reached
relatively from this SDK root; a repository split copies a fixture
subset in (see the SDK README).
"""

from pathlib import Path

import pytest

import moli

# tests/conftest.py -> tests -> moli-python-sdk -> sdk -> repo root
REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = REPO_ROOT / "tests" / "fixtures"

# The committed golden .qdct of the ipadic fixture: both this suite
# (Python-side snapshot()) and the Odin ABI suite (save_qdct's file)
# must produce exactly these bytes — determinism across the ABI pinned
# to one committed image, with no run-order coupling between suites.
QDCT_GOLDEN = FIXTURES / "qdct_ref_snapshot.qdct"

IPADIC = FIXTURES / "ipadic_sample.csv"
RESOURCES = FIXTURES / "resources" / "sample.csv"
EN = FIXTURES / "en_sample.csv"


def load_ipadic():
    """A private ipadic-fixture analyzer (close it, or drop it)."""
    return moli.load(moli.Language.Japanese, str(IPADIC))


@pytest.fixture(scope="session")
def analyzer():
    a = moli.load(moli.Language.Japanese, str(IPADIC))
    yield a
    a.close()


@pytest.fixture(scope="session")
def resources_analyzer():
    a = moli.load(moli.Language.Japanese, str(RESOURCES))
    yield a
    a.close()
