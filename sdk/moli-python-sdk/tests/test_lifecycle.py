"""Lifecycle safety: close discipline, finalisers, context managers."""

import gc
import weakref

import pytest

import moli
from conftest import load_ipadic


def test_close_is_idempotent():
    a = load_ipadic()
    a.close()
    a.close()
    a.close()
    # the repeats are no-ops, not damage: the closed wrapper answers
    # honestly and the runtime is still healthy
    assert "closed" in repr(a)
    with pytest.raises(moli.UnavailableError):
        a.tokenize("犬が歩く")
    b = load_ipadic()
    try:
        assert len(b.tokenize("犬が歩く")) == 3
    finally:
        b.close()


def test_post_close_raises_unavailable(tmp_path):
    a = load_ipadic()
    a.close()
    for call in (
        lambda: a.tokenize("犬が歩く"),
        lambda: a.wakachi("犬が歩く"),
        lambda: a.spans("犬が歩く"),
        lambda: a.nbest("犬が歩く"),
        lambda: a.snapshot(),
        lambda: a.stats(),
        lambda: a.clone(),
        lambda: a.classify_locale("x"),
        lambda: a.add_user_entries([moli.UserEntry(surface="x")]),
        lambda: a.save_qdct(str(tmp_path / "never.qdct")),
    ):
        with pytest.raises(moli.UnavailableError):
            call()


def test_context_manager_closes():
    with load_ipadic() as a:
        assert len(a.tokenize("犬が歩く")) == 3
    with pytest.raises(moli.UnavailableError):
        a.tokenize("犬が歩く")


def test_dropped_analyzer_is_finalised():
    a = load_ipadic()
    ref = weakref.ref(a)
    del a
    gc.collect()
    assert ref() is None, "Analyzer should die on refcount drop"
    # the finaliser freed the native handle without crashing; a fresh
    # analyser proves the runtime is still healthy
    b = load_ipadic()
    try:
        assert len(b.tokenize("犬が歩く")) == 3
    finally:
        b.close()


def test_dropped_cancel_token():
    tok = moli.CancelToken()
    ref = weakref.ref(tok)
    del tok
    gc.collect()
    assert ref() is None
    tok2 = moli.CancelToken()
    tok2.cancel()
    a = load_ipadic()
    try:
        with pytest.raises(moli.CancelledError):
            a.tokenize("犬が歩く", cancel=tok2)
    finally:
        a.close()


def test_repr():
    a = load_ipadic()
    assert "open" in repr(a)
    a.close()
    assert "closed" in repr(a)


def test_cancel_token_is_one_way():
    tok = moli.CancelToken()
    tok.cancel()
    tok.cancel()  # spent tokens keep working
    # and a spent token keeps bouncing every later call that shares it
    a = load_ipadic()
    try:
        with pytest.raises(moli.CancelledError) as ei:
            a.tokenize("犬が歩く", cancel=tok)
        assert ei.value.byte_offset == 0
    finally:
        a.close()
