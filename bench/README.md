# bench — measurement harnesses

The single-file harnesses behind the numbers in `docs/benchmarks.md`. Each
`.odin` file is a self-contained package run in `-file` mode from the
repo root; each writes its scratch (snapshots, listings, logs) under
gitignored `tmp/`, which `just test` / `just sdk-test` also recreate —
`mkdir -p tmp` before a direct run on a fresh checkout.

Prerequisites: the real dictionaries under gitignored `dict/` —
`just dict-fetch` (~165 MB download, ~700 MB extracted; sources,
licences, and the hand-acquired inputs in README.md's "Dictionaries"
section). The F1 harnesses additionally need a local KWDLC clone
under `dict/kwdlc` plus its `tmp/knp_files.txt` listing (see
"Dictionaries") and a reference `mecab` binary with an EUC-JP ipadic
system dictionary for the control arm.

| Harness | Measures |
|---|---|
| `bench.odin` | The main round: load timing (median of 3, plain allocator) + tracked peak/leak pass per dictionary; tokenize throughput at 1K/10K/100K for both modes and binary vs flat `char_class`; median/p95/p99 |
| `par_bench.odin` | Whole-load wall time across `Load_Options.threads` values, with snapshot byte-identity and stats checks against the serial image |
| `par_probe.odin` | The `matrix.def` import arm alone at several thread counts (isolates the parallelizable part of the load) |
| `qdct_mmap_bench.odin` | `save_qdct` once, then read-copy vs mapped restore per dictionary (median of 3) + VmRSS after load and after a smoke tokenize |
| `load_probe.odin` | Lexicon-arm phase clocks at unidic scale (read+parse+clone, sort, trie build, resources, matrix) via the exported internals |
| `cedar_probe.odin` | The surface sort alone vs the rest of `cedar_build` at unidic scale |
| `ceiling.odin` | Machine ceiling: raw-read throughput, memory-scan bandwidth, load decomposition with lex slices, per-row parse proxy |
| `nbest_trial.odin` | N-best timing at real scale (ipadic 5-best, 50 rounds) |
| `flags_speed.odin` | Viterbi throughput with the char.def unknown flags driving the lattice |
| `german_trial.odin` | The converted DWDSmor dictionary: load + tokenize with and without `unk_cost_per_rune` (needs `scripts/gen_german_dict.py` output under `dict/german/`) |
| `quality.odin` | The hand-verified segmentation quality gate (asserted sentences per dictionary + eyeball rows + tokenize/wakachi self-consistency) |
| `f1_kwdlc.odin` | Boundary F1 against KWDLC (numbers-only output); its first pass also writes `tmp/kwdlc_sentences.txt` — the scored corpus the reference control consumes |
| `f1_kwdlc_qpat.odin` | The same protocol with `ipadic_patterns.qpat` loaded (the surface-pattern trial arm) |
| `f1_grid.odin` | The unknown-cost grid sweep behind the "flat parameter space" finding (F1 across `unk_cost_bias` × `unk_cost_per_rune` points) |
| `f1_oracle_nbest.odin` | N-best oracle over the same KWDLC protocol: oracle@k re-ranker ceiling, exact-gold rank histogram, cost-gap margins (10-best) |
| `tokenize_par.odin` | Concurrent tokenize scaling: G workers on one shared, read-only analyzer at 1/2/4/8 threads (aggregate MiB/s + a separate-analyzer control) |
| `sink_probe.odin` | Result-sink throughput per mode: tokenize (`[]Morpheme`) vs wakachi (`[]string`) vs spans (`[]Surface_Span`) over the same analyzer and text (ipadic 100K, median of 20); asserts its snapshots' fingerprints first (`just bench-snapshots`) |
| `native_probe.odin` | The native reference column of the SDK FFI-overhead table (same fixture and texts as `sdk/moli-python-sdk/probe.py`, same median-of-block-means statistic) |
| `sdk_ab_probe.py` | Per-build SDK rate probe for A/B measurement: the tokenize-object arms behind the polarity-cancelled wall figures plus the fresh-process memory shapes (`mem` mode); asserts the shared snapshot's fingerprint first |
| `sdk_identity.py` | A/B output-identity digest: one sha256 over every result shape for a fixed sentence pool (two builds are output-identical exactly when the digests match); asserts the shared snapshot's fingerprint first |
| `sdk_mecab_compare.py` | The MeCab-vs-moli Python comparison behind "Against MeCab" (needs a Python MeCab binding + a UTF-8 ipadic dictionary built with `mecab-dict-index`) |
| `f1_mecab_control.py` | Reference control: MeCab+ipadic over the corpus file `f1_kwdlc.odin` wrote (identical sentence set by construction; refuses to score when a sentence is EUC-JP-unmappable) |
| `snapshots.odin` | The producer behind `just bench-snapshots`: the sink probe's mode pair and the SDK battery's snapshot, with their `entries_hash` fingerprints |

`ipadic_patterns.qpat` — the `f1_kwdlc_qpat` input — is hand-written:
its connection ids are picked from ipadic's matrix id space so the rows
connect, but the surfaces, costs, and POS labels are this project's
own; no ipadic rows are copied.

Coverage tooling (method recorded in `docs/benchmarks.md`; inputs are
produced by the commands in its coverage section). The measured file
list is derived from `src/moli` at run time — platform-suffixed files
compiled out of the current build are excluded — so a new source file
cannot silently escape measurement:

| Tool | Role |
|---|---|
| `cov_instr.py` | Per-instruction line, function, and branch coverage from a raw callgrind dump (`--dump-instr=yes`) via DWARF/addr2line; branch sites are scoped to moli-attributed addresses |
| `cov_parse.py` | Per-line coverage from `callgrind_annotate` output |

Run shape, common to every harness (both collections — the harnesses
share `bench/support` through the `bench` collection):

    mkdir -p tmp
    odin run bench/bench.odin -file \
      -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed

The numbers these harnesses print are window measurements: the dev
box's background load moves whole-load figures by up to ~10%, so
within-window comparisons are the only clean ones. Re-measure before
treating a regression — or an "improvement" — as real.
