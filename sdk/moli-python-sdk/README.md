# moli — Python SDK

Morphological analysis for Python: Japanese, Chinese (CN/TW/HK) and
English from MeCab-format dictionaries, over the moli analysis library
through its C ABI.

This package is deliberately thin: every public capability is the C
ABI spelled Python — nothing invents Python-only semantics. The ABI is
the durable asset; other language bindings consume it directly rather
than this package.

## Quick start

From the repository root (the SDK is developed in-tree; wheels come at
distribution time):

```sh
just sdk-venv    # once: .venv carrying pytest (SDK runtime is stdlib-only)
just sdk-build   # build libmoli.so (Odin), then the extension (gcc, links it)
just sdk-test    # Odin ABI tests under the leak gate, then pytest
```

```python
import sys; sys.path.insert(0, "sdk/moli-python-sdk/src")  # in-repo use
import moli

a = moli.load(moli.Language.Japanese, "lex.csv",
              mode=moli.Mode.Viterbi, threads=8)
ms = a.tokenize("犬が歩く")
# Morphemes: lazy Sequence[Morpheme] — ms[0] and len(ms) are O(1),
# list(ms) gives [Morpheme(surface='犬', pos='名詞,一般', ...), ...]

a.wakachi("犬が歩く")                 # ['犬', 'が', '歩く']
a.spans("犬が歩く")                   # [Span('犬', 0, 3), Span('が', 3, 6), ...]
a.nbest("犬が歩いている", k=3)        # cheapest-first NBestPath(cost, morphemes)
a.classify_locale("the colour of defence")   # Locale.GB
a.stats()                              # entries, terminals, matrix density, ...
a.snapshot()                           # bytes: a .qdct image, byte-identical
                                       # to save_qdct's file
b = a.clone()                          # independent copy through the snapshot
a.add_user_entries([moli.UserEntry(surface="犬助", pos="名詞,固有名詞",
                                   reading="ケンスケ", cost=-3000)])
tok = moli.CancelToken()               # one-way; pass cancel=tok to tokenize
a.close()                              # idempotent; also with-block and __del__
```

Load paths mirror the library: `load` (CSV path), `load_bytes`
(CSV bytes, borrowed), `load_qdct` / `load_qdct_mmap` (snapshot file;
mmap is the zero-extra-copy POSIX deploy path), `load_qdct_bytes`
(snapshot bytes; copied once — the library adopts its buffer).

## Threading and lifetime

An `Analyzer` is safe to share across threads: tokenize concurrently —
the extension releases the GIL around every call that can take real
time, so Python threads run the analysis with true parallelism and
outputs are byte-identical to the serial run. `add_user_entries`
mutates the analyzer and `stats` rewrites per-handle scratch, so both
take the wrapper's mutation lane (one at a time; concurrent callers
queue). `close()` from one thread is safe with in-flight tokenizers
elsewhere (a wrapper-side drain waits them out; new calls raise
`UnavailableError`), and a close racing another close is a clean
no-op.

String-shaped results (`wakachi`, `wakati`, `parse`, `spans`, n-best)
are eager immutable values (namedtuples / str / list of str) with no
native memory behind them. `tokenize` returns a `Morphemes` view: a
lazy immutable `Sequence[Morpheme]` that materializes each morpheme
on first access (cached, so identity is stable) and holds its native
result — standalone memory with no lifetime coupling to the analyzer
or to later calls — until the last morpheme is read or the view is
dropped; partial reads never build the untouched morphemes. Result
strings may contain `surrogateescape` sequences when the
default-degrading tokenize met invalid bytes (pass `strict_utf8=True`
to reject such input up front with the first invalid byte offset
instead).

## Errors

Every failure is a typed exception (codes cross the ABI as codes;
nothing string-matches): `LoadError` (with `SchemaMismatchError`
carrying `line`/`expected`/`got`), `OutOfMemoryError`,
`UnavailableError`, `MalformedInputError` and `CancelledError` (both
carrying `byte_offset`), `SaveError` — all subclasses of `MoliError`.

## Layout and build

```
native/     Odin shim package -> lib/libmoli.so (the C ABI)
c/          C sources: moli_abi.h (the mirror), moli_native.c (extension)
src/moli/   the Python package (imports moli._native, the built extension)
tests/      pytest suite
probe.py    FFI overhead probe (just sdk-probe)
```

The extension links `libmoli` at build time (rpath `$ORIGIN/lib`,
`@loader_path/lib` on macOS), and at import it verifies its ABI layout
mirror against the library's `moli_abi_check` — a mismatch fails the
import with a plain message, never the first tokenize. Rebuild both
together after a compiler or layout change (`just sdk-build` does
exactly that, Odin first).

Requires CPython ≥ 3.12 (the tested line; the extension uses its
managed weakref support).

## In-repo fixture dependency

The test suite reads the repository's committed dictionaries under
`tests/fixtures` (reached relatively from this folder). When this SDK
splits into its own repository, copy a fixture subset in and keep
`conftest.py`'s path wiring.

## License

MIT, same as the library.
