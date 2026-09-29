"""Regression tests at the extension boundary: refcount and lifetime
bugs (the stats value-types fallback, close races against mutating
calls), input validation, and the mutation lane's serialization."""

import json
import os
import subprocess
import sys
import textwrap
import threading

import pytest

import moli
from conftest import IPADIC, load_ipadic


def test_stats_without_value_types():
    """stats() must stay correct when the value types were never handed
    to the extension: the dict fallback path's s:N build consumes the
    skipped list's only reference, so the build must keep that list
    alive under the returned dict. Importing moli._native normally
    still runs moli/__init__.py (which registers the types), so the
    child loads the extension straight from its file path — a bare
    module instance with no value types."""
    code = textwrap.dedent(
        """
        import gc, importlib.util, json, sys
        # The module name must match the extension's PyInit__native
        # export; loading by file path keeps it outside the moli
        # package, so the parent __init__ (which registers the value
        # types) never runs.
        spec = importlib.util.spec_from_file_location("_native", sys.argv[2])
        native = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(native)
        a = native.load(0, sys.argv[1])
        try:
            d = a.stats()
            gc.collect()
            skipped = list(d["skipped"])
            assert d["entries"] > 0
            assert d["matrix_density"] > 0.0
            print(json.dumps({"entries": d["entries"], "skipped": skipped}))
        finally:
            a.close()
        """
    )
    # The suite runs with PYTHONPATH pointing at the package source;
    # give the child the same view (moli.__file__ is inside it).
    pkg_src = os.path.dirname(os.path.dirname(os.path.abspath(moli.__file__)))
    env = dict(os.environ)
    env["PYTHONPATH"] = pkg_src + os.pathsep + env.get("PYTHONPATH", "")
    out = subprocess.run(
        [sys.executable, "-c", code, str(IPADIC), moli._native.__file__],
        capture_output=True,
        text=True,
        check=True,
        env=env,
    )
    payload = json.loads(out.stdout)
    assert payload["entries"] > 0
    assert isinstance(payload["skipped"], list)


def test_close_idempotent_under_concurrency():
    """Two threads closing one analyzer must not double-free: close
    claims the handle under the GIL, so the loser is a clean no-op."""
    for _ in range(200):
        a = load_ipadic()
        barrier = threading.Barrier(2)
        errors = []

        def closer():
            barrier.wait()
            try:
                a.close()
            except Exception as exc:  # pragma: no cover - failure detail
                errors.append(exc)

        threads = [threading.Thread(target=closer) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        assert not errors


def test_add_user_entries_close_race():
    """The attribute reads in add_user_entries can run arbitrary Python
    (properties, __getattr__); a close landing in that window must
    bounce the call with UnavailableError instead of handing the freed
    handle to the ABI."""
    entered = threading.Event()
    release = threading.Event()

    class BlockingEntry:
        def __getattr__(self, name):
            if name == "surface":
                entered.set()
                release.wait(timeout=10)
                return "犬"
            if name == "pos":
                return "名詞"
            if name in ("lemma", "reading", "reading_jyutping"):
                return "*"
            if name in ("left_id", "right_id", "cost"):
                return 0
            raise AttributeError(name)

    a = load_ipadic()
    try:
        outcome = {}

        def adder():
            try:
                a.add_user_entries([BlockingEntry()])
                outcome["rc"] = "ok"
            except moli.UnavailableError:
                outcome["rc"] = "unavailable"
            except Exception as exc:  # pragma: no cover - failure detail
                outcome["rc"] = exc

        th = threading.Thread(target=adder)
        th.start()
        assert entered.wait(timeout=10)
        a.close()
        release.set()
        th.join()
        assert outcome["rc"] == "unavailable", outcome
    finally:
        release.set()
        a.close()


def test_user_entry_i16_range():
    a = load_ipadic()
    try:
        with pytest.raises(ValueError, match="left_id"):
            a.add_user_entries([moli.UserEntry(surface="犬", left_id=70000)])
        with pytest.raises(ValueError, match="cost"):
            a.add_user_entries([moli.UserEntry(surface="犬", cost=-40000)])
    finally:
        a.close()


def test_path_with_embedded_nul():
    with pytest.raises(ValueError, match="NUL"):
        moli.load(moli.Language.Japanese, "foo\0bar.csv")


def test_stats_entries_hash_is_a_dictionary_version():
    a = load_ipadic()
    try:
        before = a.stats().entries_hash
        assert isinstance(before, int) and before >= 0
        a.add_user_entries(
            [moli.UserEntry(surface="ぞの犬", pos="名詞,固有名詞", cost=-5000)]
        )
        assert a.stats().entries_hash != before
        assert [m.surface for m in a.tokenize("ぞの犬")] == ["ぞの犬"]
    finally:
        a.close()


def test_concurrent_add_user_entries_serialized():
    """add_user_entries mutates the analyzer and rewrites the stats
    scratch; both take the wrapper's mutation lane, so concurrent
    mergers and stat readers race nothing."""
    a = load_ipadic()
    try:
        errors = []
        n_before = a.stats().entries

        def adder(i):
            try:
                for k in range(20):
                    a.add_user_entries(
                        [moli.UserEntry(surface=f"用語{i}_{k}", pos="名詞")]
                    )
            except Exception as exc:  # pragma: no cover - failure detail
                errors.append(exc)

        def statser():
            try:
                for _ in range(100):
                    st = a.stats()
                    assert st.entries >= n_before
            except Exception as exc:  # pragma: no cover - failure detail
                errors.append(exc)

        threads = [threading.Thread(target=adder, args=(i,)) for i in range(2)]
        threads.append(threading.Thread(target=statser))
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        assert not errors
        assert a.stats().entries == n_before + 40
    finally:
        a.close()
