# moli

A morphological analysis library written in Odin — Japanese, Chinese, and English from MeCab-format dictionaries, built as a deterministic, low-dependency backend for concurrent services.

Named after 茉莉 (*mòlì*, jasmine), the blossom that scents jasmine tea. In much of China the flowers are drunk as well as smelt: a dried clump of them goes into the pot with the leaves, and the hot water is poured straight over. In the cup, the clump holds its shape until the water finds it — and then it opens, and what looked like one dense thing turns out to be many distinct ones, each with a form of its own. That is more or less the job description. moli opens runs of unsegmented text morpheme by morpheme, over a Viterbi lattice built from MeCab-compatible dictionaries; homographs come apart into separate candidates, and the shortest-cost reading wins.

The ancients got there first:

> 一卉能熏一室香，炎天犹觉玉肌凉。
> 野人不敢烦天女，自折琼枝置枕旁。
>
> *One blossom suffices to perfume the whole room; even in the blaze of summer it leaves the skin cool as jade. — Liu Kezhuang, of the Southern Song, on jasmine. (The closing lines have him plucking a sprig to keep by his pillow, which is his own affair.)*

This remains the working theory behind the library: one small pinch of dependency-free Odin — and an entire context window comes out smelling of structure. The poet 江奎 went further: 「他年我若修花史，列作人间第一香」 — were he ever to compile the history of flowers, he would inscribe jasmine as the foremost fragrance in the world of men. (The anthologies cannot even agree whether he wrote under the Song or under the Qing — which may be why the history of flowers was never written.) We make no such claim for the segmentation. We merely note that moli, being tea rather than a language model, is deterministic: same leaves, same water, same pot, every time.

## At a glance

- **Seven locales** — Japanese (ipadic, UniDic), Chinese CN/TW/HK (mecab-jieba; an optional HK-variant CSV merges jyutping onto the loaded lexicon by surface), English GB/US, German (DWDSmor Open Edition via `scripts/gen_german_dict.py`, generated locally and never distributed; the search-time `unk_cost_per_rune` prices long unknowns so out-of-vocabulary compounds split — Hausmuseum → Haus|museum)
- **MeCab-format dictionaries** — CSV lexicons with `unk.def`, `char.def`, and `matrix.def` connection costs, plus an optional `patterns.qpat` that refines unknown-word labels by surface shape (prefix/suffix/charset rows, ahead of the `unk.def` walk)
- **Two modes** — Viterbi (the default) or greedy longest-match; homographs of one surface are stored as a single contiguous, surface-sorted range per trie terminal and enumerated, never overwritten
- **The leaves** — a double-array trie over frequency-mapped characters, and a dense i16 connection matrix
- **The contract** — the analyser is immutable once loaded; morphemes are zero-copy; tokenisation allocates only your output array; teardown drains in-flight calls rather than racing them; a strict-input flag rejects non-UTF-8 text instead of degrading it into unknowns, and a one-way cancel token (polled once per rune position) unwinds a call when its deadline fires
- **Odin, core only** — no third-party dependencies

## Documentation

Beyond this front page: [docs/contract.md](docs/contract.md) — the
Analyzer contract (concurrency, zero-copy, teardown, validation
boundaries); [docs/options.md](docs/options.md) — every option with its
default and the grammar of every input file, on committed fixture rows;
[docs/abi.md](docs/abi.md) — embedding from C over the ABI, with a
compiled and verified example program. Measured numbers live in
[docs/benchmarks.md](docs/benchmarks.md).

## Quick start

The package is used as an Odin collection (`-collection:moli=src`):

```odin
import "core:fmt"
import "core:mem"
import "moli:moli"

// Load once. The zero options are the recommended load — Viterbi mode,
// with unk.def / char.def / matrix.def / patterns.qpat looked up beside
// the CSV. Tokenize-family calls run concurrently on the shared
// analyzer; add_user_entries mutates it (serialize mutating calls and
// free in the caller, like two frees).
a, err := moli.load(.Japanese, "lex.csv", {}, context.allocator)
if err != nil { /* closed Load_Fault vocabulary; see errors.odin */ }
defer moli.free(&a)

// Tokenise on a caller-supplied arena: tokenize allocates only the
// morpheme array, and only in that arena.
buf: [1 << 16]byte
arena: mem.Arena
mem.arena_init(&arena, buf[:])
ms, terr := moli.tokenize(&a, "犬が歩く", mem.arena_allocator(&arena))
if terr != nil { /* .Unavailable or .OutOfMemory */ }
for m in ms {
	fmt.println(m.surface, m.pos, m.lemma)
}
```

Morphemes are zero-copy — `surface` points into your input string, and every other string field is a view into analyzer-owned dictionary data. Pass `.mode = .LongestMatch` in `Load_Options` for the greedy fast path.

Search options and N-best paths:

```odin
// Penalise unknown candidates in the Viterbi search — per candidate
// (bias) and per rune (the per-rune price is what makes long unknowns
// lose to a dictionary split) — and compose decomposed (NFD) input
// first; surfaces then index the arena copy.
opts := moli.Tokenize_Options{unk_cost_bias = 8000, normalize_nfc = true}
ms2, _ := moli.tokenize_opt(&a, "か\u3099が行く", opts, mem.arena_allocator(&arena))

// Enumerate the k best paths (A* with an exact heuristic): re-rank
// downstream, or expose the candidates.
// The Constraints argument (also on this call) is the constrained
// set below; {} is the unconstrained search.
paths := make([dynamic]moli.NBest_Path, 0, 5, mem.arena_allocator(&arena))
moli.tokenize_nbest(&a, "東京都庁に行く", 5, {}, {}, &paths, mem.arena_allocator(&arena))

// Constrained analysis — feed the search what is already known: spans
// that must come out as exactly one morpheme (with a POS-column
// prefix, "" for any POS) and byte offsets where a boundary must or
// must not exist. The empty set reproduces the plain result exactly;
// an over-constrained set faults (Unsatisfiable_Error carrying the
// earliest blocked offset) instead of silently relaxing.
toks := []moli.Token_Constraint{{start = 0, end = 9, pos = "名詞,固有名詞"}}
bounds := []moli.Boundary_Constraint{{at = 18, must_exist = true}}
ms4, err4 := moli.tokenize_constrained(&a, "東京都庁に行く", {tokens = toks, boundaries = bounds}, {}, mem.arena_allocator(&arena))

// Deadline control: reject non-UTF-8 input outright (the default
// degrades it into unknown morphemes), and stop a running call from
// another thread — the walk polls the token once per rune position and
// unwinds with Cancelled_Error at the offset it reached.
tok := moli.Cancel_Token{}
ms3, err3 := moli.tokenize_opt(&a, "犬が歩く", {strict_utf8 = true, cancel_token = &tok}, mem.arena_allocator(&arena))
// err3 then carries Malformed_Input_Error / Cancelled_Error, each with
// its byte offset; moli.cancel(&tok) is safe from any thread.
```

Domain terms merge into a loaded analyzer with `add_user_entries` (the surface re-sort renumbers entry ids - ids taken before the merge are stale after it, `stats().entries_hash` detects the change; the swap drains in-flight calls like `free`), and `Load_Options.lemma_locale` rewrites entry lemmas toward `.US`/`.GB` or simplified Chinese at load.

For repeat startups, skip the CSV import entirely: load once, snapshot, and restore from the binary image afterwards — the restore comes in an order of magnitude under the import (measured numbers in docs/benchmarks.md).

```odin
a, err := moli.load(.Japanese, "lex.csv", {}, context.allocator)
if err := moli.save_qdct(&a, "lex.qdct", context.temp_allocator); err != nil { /* .IO_Write / .OutOfMemory */ }
// ... later processes:
a, err := moli.load_qdct("lex.qdct", context.allocator)
// or restore through a read-only mapping (POSIX): moli.load_qdct_mmap
```

Both load entries also take in-memory bytes — `load_bytes` for the CSV image, `load_qdct_bytes` for the snapshot (the latter adopts the caller's buffer) — so an embedder can ship dictionaries as resources without touching the filesystem.

Two read-out companions share the snapshot builder: `snapshot` returns the same image in memory (byte-identical to the file), and `clone` restores an independent copy through it — the variant-dictionary move (clone a shared base, merge domain terms into the private copy with `add_user_entries`, the base stays untouched; freeing either analyzer leaves the other fully usable). `stats` inventories one analyzer (entries, distinct-surface terminals, matrix dimensions and how much of it `matrix.def` actually enumerated, skipped resources), and `tokenize_surfaces_with_offsets` emits surfaces with contiguous byte offsets — the highlighting/indexing projection — through the same options family as `tokenize_opt`.

## Dictionaries

moli ships no dictionary data: the lexicons are fetched into `dict/`
(gitignored — never committed, never distributed), and the test suite
does not need them at all — it runs on the small committed fixtures
under `tests/fixtures/` (provenance and licences in
`tests/fixtures/README.md`).

`just dict-fetch` (~165 MB download, ~700 MB extracted, each archive
verified against a pinned SHA-256) populates the three MeCab-format
lexicons the bench harnesses load:

| Lexicon | Source | Licence |
|---|---|---|
| unidic-mecab 2.1.2 | [clrd.ninjal.ac.jp](https://clrd.ninjal.ac.jp/unidic_archive/cwj/2.1.2/unidic-mecab-2.1.2_src.zip) | GPL / LGPL / BSD, UniDic Consortium |
| mecab-jieba 0.1.1 | [lindera/mecab-jieba](https://github.com/lindera/mecab-jieba) | MIT, the Lindera project |
| ipadic 2.7.0-20070801 | [SourceForge mecab](https://sourceforge.net/projects/mecab/) | NAIST/ICOT terms (`COPYING` inside the archive) |

ipadic ships EUC-JP per-POS CSVs; the fetch converts and concatenates
them into `dict/ipadic-utf8/` (`lex.csv`, `char.def`, `unk.def`
through iconv, `matrix.def` copied as-is — `scripts/fetch_dicts.sh`
is the recipe).

The measurement-only inputs beyond those three are acquired by hand
(research or copyleft terms — local use under `dict/`, nothing
committed; `bench/README.md` records which harness needs what):

- **KWDLC** — the F1 harnesses' gold standard, distributed for
  research use by the NLP Laboratory, Kyoto University
  ([ku-nlp/KWDLC](https://github.com/ku-nlp/KWDLC)). Clone it to
  `dict/kwdlc`, then `find dict/kwdlc/knp -name '*.knp' | sort >
  tmp/knp_files.txt`.
- **DWDSmor Open Edition** — the German trial's wordbook (GPL-2.0,
  [zentrum-lexikographie/dwdsmor](https://github.com/zentrum-lexikographie/dwdsmor)):
  `python3 -m venv dict/venv`, `dict/venv/bin/pip install dwdsmor`,
  then `scripts/gen_german_dict.py` builds `dict/german/german.csv`.
- **UCD 17.0.0 and OpenCC** — regeneration inputs for the two
  committed generated tables:
  [UnicodeData.txt](https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt)
  and
  [DerivedNormalizationProps.txt](https://www.unicode.org/Public/17.0.0/ucd/DerivedNormalizationProps.txt)
  into `dict/ucd/` for `scripts/gen_nfc_tables.py`, OpenCC's
  `TSCharacters.txt` for `scripts/gen_lemma_tables.py`.

## Status

The analysis core and the Python SDK are implemented. Every test runs on the committed fixtures alone — `just test` and `just sdk-test` execute them under a tracking allocator and fail on any leak block in the log — and the three real dictionaries (`just dict-fetch`) are verified load → tokenize → free, leak-free. The measurements live in docs/benchmarks.md with the harnesses that produced them (`bench/README.md`): load and snapshot-restore timings, tokenisation throughput per mode, concurrent scaling, boundary F1 against KWDLC, and the SDK's FFI overhead.

## Python SDK

The library ships behind a C ABI and, on top of it, a Python SDK — `sdk/moli-python-sdk`, the first consumer of the ABI:

```
just sdk-venv    # once: venv with pytest (the SDK itself is stdlib-only)
just sdk-build   # Odin first (libmoli.so), C second (extension links it)
just sdk-test    # shim ABI tests under the leak gate + pytest
```

```python
import moli

a = moli.load(moli.Language.Japanese, "lex.csv")
ms = a.tokenize("犬が歩く")          # Morphemes view — surfaces, POS,
                                   # lemma, readings, byte offsets, costs;
                                   # list(t) gives the eager list
a.wakachi("犬が歩く")                # list[str]
a.spans("犬が歩く")                  # list[Span(surface, start, end)]
a.nbest("犬が歩いている", k=3)       # list[NBestPath(cost, morphemes)]
a.classify_locale("the colour of defence")   # Locale.GB
```

The analyser is immutable once loaded and shared across threads (the extension releases the GIL around every real call, so Python threads tokenize one `Analyzer` with true parallelism; outputs are byte-identical to the serial run, and `close()` drains in-flight calls safely). String-shaped results are eager immutable values; `tokenize` returns a lazy `Morphemes` view — list-like, materializing each `Morpheme` on access and releasing its native result once fully read (`list(t)` for the eager list). The extension checks its hand-mirrored ABI layout against the library at import, so a mismatch fails the import with a plain message, never the first tokenize. Load paths, snapshots (`save_qdct` / `snapshot` / `clone` / `load_qdct_mmap`), the full tokenize option family (cancellation, NFC, strict UTF-8, unknown-cost tuning), user dictionaries and `stats` are all mirrored; FFI overhead numbers sit in docs/benchmarks.md. See the SDK's own README for the embedding notes and the future split.

## Contributing

Bug fixes and documentation improvements are welcome as direct pull
requests; features and specification changes start with an issue
first — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).

`src/moli/nfc_tables.odin` is generated from the Unicode Character
Database (Unicode 17.0.0) by `scripts/gen_nfc_tables.py`; the UCD is
distributed under the Unicode License (unicode.org/license.txt).
`src/moli/lemma_zh_ts.odin` is generated from the OpenCC
TSCharacters mapping by `scripts/gen_lemma_tables.py`; OpenCC is
Apache-2.0 (github.com/BYVoid/OpenCC).
