# Benchmarks

The measured cross-section and the methodology that produced it. Every
number names the harness that produced it — `bench/README.md` maps
them. This is the single home for measured numbers: the other documents
point here, they never copy its figures.

## The two environments

| Host | CPU | Memory | System | Compiler | Date |
|---|---|---|---|---|---|
| x86 dev box | Ryzen 7 5700U, 8 cores / 16 SMT threads | 15 GiB DDR4-3200 dual-channel, NVMe | Linux (native), background-quiet window (CPU PSI 0 at the stamps) | dev-2026-09-nightly `a2fb372`, `-o:speed` | 2026-09-26 |
| ARM host | Qualcomm Oryon (implementer 0x51, part 0x001), 12 logical CPUs — 1 thread per core; L1d 1.1 MiB × 12, L2 144 MiB × 12 | 7.7 GiB available (WSL2 cgroup) | WSL2 6.6.87.2-microsoft-standard-WSL2 | dev-2026-09-nightly `a2fb372`, `-o:speed` | 2026-09-26 |

How to read every table:

- **Wall figures are window measurements.** Run-to-run spread on
  whole-load figures reaches ~10% with background load. Compare within
  a window; re-measure before treating a regression — or an
  "improvement" — as real.
- **The (x86) and (ARM) columns are convenience, not a
  cross-architecture comparison.** The hosts differ in core count,
  memory subsystem, and (on ARM) a WSL2 layer; each host's numbers
  answer questions asked within that host.
- **Deterministic figures do not wobble**: morpheme counts,
  bytes-per-token, F1, and coverage are identical across windows. Wall
  times are not.
- **This file is a cross-section, not a diary.** A rewritten table
  replaces the old values in place — no measurement histories, no
  before/after progressions, no re-measurement chronicles, no
  commit-hash citations. Re-measure the tables when dictionary scale
  changes.
- The ARM benches clock with `CLOCK_MONOTONIC_RAW`, which the Windows
  clock-sync under WSL2 cannot step.

## Machine ceiling (ARM)

*What it measures: the host's raw file-read and memory-scan speeds, and
one load broken into arms. A load arm sitting near a ceiling row is
done optimising — the input channel or the memory bus is the cost.*
`ceiling.odin`:

Raw read (`os.read_entire_file`, warm):

| File | Size | Throughput |
|---|---|---|
| lex.csv | 39.6 MiB | 2,199 MiB/s |
| matrix.def | 21.9 MiB | 11,738 MiB/s |
| unk.def | ~0 MiB | 437 MiB/s |
| char.def | ~0 MiB | 800 MiB/s |
| load set total | 61.6 MiB | **3,095 MiB/s** |

Memory-scan bandwidth: 16,268 MiB/s on one thread; 56,530 MiB/s
aggregate on 8.

Load decomposition (ipadic, median of 3): full load 0.774 s; lex-only
`load_bytes` 0.618 s; lex 25% (98K lines) 0.121 s; lex 50% (196K
lines) 0.258 s. Per-entry slope: 1.834 µs/row (50–100%), 1.405 µs/row
(25–50%). Parse proxy — split + clone into an arena over 392,126 rows
/ 5,097,638 fields: 0.083 s, 0.213 µs/row, 475 MiB/s.

## Load (CSV import)

*What it measures: the whole import — file read, parse, per-field
clone, surface sort, trie build, resource import — as one wall figure.
Peak is the load arena's high-water, Free the teardown walk, and Leaks
the tracked-allocator verdict (the zero-leak discipline the Leaks
column asserts).*

Median of 3 timed runs on the plain allocator (x86 additionally with
Free from one tracked pass):

| Dictionary | Entries | Matrix | Load (x86) | Load (ARM) | Peak | Free (x86) | Leaks |
|---|---|---|---|---|---|---|---|
| ipadic 2.7.0 (UTF-8 converted) | 392,126 | 1316² | 0.92s | 0.77s | 316 MiB | 0.14s | 0 |
| unidic-mecab 2.1.2 | 756,463 | 5981² | 4.77s | 4.90s | 1162 MiB | 0.28s | 0 |
| mecab-jieba 0.1.1 | 584,429 | 1×1 stub | 0.89s | 0.66s | 475 MiB | 0.08s | 0 |

Peak includes the load arena's whole-file images (unidic: lex.csv
125 MB + matrix.def 491 MB) plus the sort scratch (~25 B/entry —
skipped entirely when the CSV is already surface-sorted, as
mecab-jieba's is). `free` releases string clones far from where they
were allocated, a locality effect that also moves with the window
(unidic frees in ~0.26–0.32 s in a quiet one).

### Load-arm decomposition

*What it measures: where the load time goes, phase by phase — the arms
the whole-load table sums over.*

x86, unidic scale, phase-timed through the exported internals (warm
runs):

| Arm | Time |
|---|---|
| CSV read+parse+clone (per-field cloning is the ownership design) | ~0.69–0.86 s |
| surface sort (u64 prefix key; order-preserving, ids unchanged) | ~0.27–0.32 s |
| sort + cedar_build (char map, shadow trie, placement) | ~0.84–0.92 s |
| matrix import, 8 threads (bandwidth-bound) | ~1.07–1.12 s |

ARM, `load_probe.odin`, unidic, two sequential runs (run 2 is
warm-cache):

| Phase | Run 1 (cold) | Run 2 (warm) |
|---|---|---|
| read+parse+clone | 1205 ms | 500 ms |
| sort+trie build | 868 ms | 702 ms |
| hand-over | 0 ms | 0 ms |
| matrix (8 threads) | 1465 ms | 552 ms |
| scratch destroy | 61 ms | 52 ms |

Cold total ≈ 3.6 s, warm ≈ 1.8 s: the matrix arm is the cold-cache
bottleneck, the trie build the warm-cache one. ARM `cedar_probe.odin`
(unidic, two runs): surface sort 240 / 259 ms; cedar_build (sort re-run
+ trie) 587 / 649 ms. These serial arms are the next levers only if
unidic-scale first-load latency ever matters — the qdct path below is
the repeat-startup answer.

### Parallel matrix parse (`Load_Options.threads`)

*What it measures: the reach of the `threads` option. It parallelises
only the matrix.def arm — the lexicon arm stays serial by design — so
the whole-load gain is bounded by the matrix arm's share of the load.*

x86 (unidic; matrix-alone row best-of-3 from one invocation):

| Arm | serial | 2 threads | 4 threads | 8 threads | 16 threads |
|---|---|---|---|---|---|
| matrix.def import alone | 3.16s | 1.86s | 1.25s | **0.94s** | — |
| whole `load` | 4.65s | 3.42s | 2.79s | **2.60s** | 2.48s |

ARM, `par_bench.odin` whole-load sweep (unidic, median of 3, range in
parentheses; correctness verified — image and `explicit`
byte-identical at every thread count):

| threads | median |
|---|---|
| 0 (auto) | 4.121 s (3.954–4.289) |
| 1 | 4.104 s (4.074–4.117) |
| 2 | 2.822 s (2.614–2.841) |
| 4 | 2.245 s (2.051–2.275) |
| 8 | 1.974 s (1.972–2.059) |
| 16 | **1.915 s** (1.739–1.964) |

ARM ipadic whole-load sweep: 0.695 / 0.677 / 0.620 / 0.598 / 0.594 /
**0.586 s** (auto/1/2/4/8/16). ARM matrix-arm isolation
(`par_probe.odin`, `import_matrix_def` alone, 3 runs each): unidic
serial 2.524–2.562 s → 8 threads 0.477–0.510 s; ipadic serial
0.107–0.137 s → 8 threads 0.017–0.018 s.

- The matrix arm scales **3.4×** at 8 threads on x86, **~5.3×** on ARM
  (near-linear to 8 on the no-SMT host). The serial prologue — unidic's
  491 MB read and 71.5 MB dense fill — is Amdahl's floor.
- The whole load gains only 1.8× (x86) because the lexicon arm stays
  serial.
- At 16 threads on x86 (one worker per SMT sibling) a memory-bound
  parse gains nothing and pays contention. Pass the **physical** core
  count.
- Snapshot bytes, morphemes, and `stats.matrix_explicit` are identical
  to the serial load at every thread count, on both hosts.
- ipadic's matrix arm is small — 0.14–0.15 s of a 0.79 s load (x86) —
  so the option is neutral there.

## qdct binary snapshots

*What it measures: the repeat-startup path — `save_qdct` once after a
CSV import, restore at every startup, as a read copy or (POSIX) a
read-only mapping. The comparison that matters is each host's restore
against its own load table above.*

`qdct_mmap_bench.odin` (medians, n=3; `save` from a one-off probe —
the harness builds its snapshot untimed):

| Dictionary | save (x86) | copy restore (x86) | copy restore (ARM) | mapped restore (x86) | mapped restore (ARM) | File size |
|---|---|---|---|---|---|---|
| ipadic 2.7.0 | 0.14s | ~0.099s | 0.087s | ~0.064s | 0.061s | 64 MiB |
| unidic 2.1.2 | 0.46s | ~0.317s | 0.188s | ~0.198s | 0.095s | 212 MiB |
| mecab-jieba 0.1.1 | 0.16s | ~0.167s | 0.118s | ~0.115s | 0.055s | 95 MiB |

- **What the mapping saves.** `load_qdct_mmap` (POSIX; Windows falls
  back to the read copy) drops the whole-file read copy: the restore
  falls to ~62–69% of the copy on x86, and to 0.70× / 0.51× / 0.47×
  (ipadic/unidic/jieba) on ARM. Only the rebuild's allocations remain.
- **Resident set.** x86: a mapped restore ends at the copy's VmRSS
  (+115/+379/+171 MiB), and a smoke tokenize faults in only 8 kB more
  — the restore stamps the entries fingerprint with one walk over
  every entry string (src/moli/qdct.odin's restore tail), and that walk
  faults the mapped payload. ARM: +115/+212 MiB (ipadic/unidic),
  +76 MiB copy / +95 MiB mmap (jieba).
- **Identity.** Restores are morpheme-identical to the CSV import.
  `load_qdct_bytes` adopts the caller's buffer for the same restore
  without touching the filesystem. Snapshot bytes and fingerprint
  values are contract-internal: content equality implies them within a
  build, and they never compare across layouts.

## Tokenize throughput

*What it measures: engine rate. News-style sentence pools repeated to
size, one shared analyser, per-iteration arena reset. The 1K column is
per-call latency, the 100K column steady-state rate.*

1000/300/50 measured iterations (1K/10K/100K) after 200/50/10 warmup:

| Dictionary | Text | Mode | 1K x86 | 1K ARM | 10K x86 | 10K ARM | 100K x86 | 100K ARM | MiB/s x86 | MiB/s ARM |
|---|---|---|---|---|---|---|---|---|---|---|
| ipadic 2.7.0 | JP | Viterbi | 58.7µs | 53.1µs | 769.6µs | 491.6µs | 9.593ms | 6.235ms | 10.18 | 15.67 |
| ipadic 2.7.0 | JP | LongestMatch | 9.1µs | 7.4µs | 98.5µs | 71.3µs | 1.422ms | 0.678ms | 68.70 | 144.01 |
| ipadic 2.7.0 | EN | Viterbi | — | 38.0µs | — | — | — | — | — | — |
| ipadic 2.7.0 | EN | LongestMatch | — | 20.5µs | — | — | — | — | — | — |
| unidic 2.1.2 | JP | Viterbi | 94.3µs | 76.9µs | 1310.9µs | 695.5µs | 12.940ms | 8.673ms | 7.55 | 11.26 |
| unidic 2.1.2 | JP | LongestMatch | 9.4µs | 7.7µs | 101.0µs | 74.3µs | 1.472ms | 0.691ms | 66.37 | 141.28 |
| unidic 2.1.2 | EN | Viterbi | — | 53.5µs | — | — | — | — | — | — |
| unidic 2.1.2 | EN | LongestMatch | 36.3µs | 26.0µs | — | — | — | — | — | — |
| jieba 0.1.1 | ZH | Viterbi | 20.6µs | 19.0µs | 211.6µs | 184.6µs | 3.821ms | 1.766ms | 25.56 | 55.31 |
| jieba 0.1.1 | ZH | LongestMatch | 7.7µs | 6.1µs | 76.4µs | 50.0µs | 1.424ms | 0.532ms | 68.59 | 183.73 |
| jieba 0.1.1 | EN | Viterbi | — | 38.4µs | — | — | — | — | — | — |
| jieba 0.1.1 | EN | LongestMatch | 26.0µs | 20.6µs | — | — | — | — | — | — |

Hypothesis targets, scored against the x86 columns: greedy JP < 150µs
(9.1–9.4µs, met), Viterbi JP < 500µs (58.7–94.3µs, met), greedy EN <
75µs (26.0–36.3µs, met), CSV load < 2500 ms at ipadic scale (0.92 s,
met).

Scaling is near-linear: the 10K→100K step multiplies the Viterbi JP
arms by ~10–12× on a 10× input (x86), and 240 KiB single calls hold
the same per-byte rate (pool table below) — the engine has no
large-call cliff. Use LongestMatch for cheap large scans. If
unidic-scale large-input Viterbi ever matters, the connection-cost DP
behind `build_lattice` is the arm to profile.

Notes:

- `flat_char_class` is not a hotspot. x86 1K Viterbi deltas: −4% to
  −10% across the 2026-09-11 runs, both signs (−3% to +16%) across
  2026-09-26. ARM agrees within its window (binary 53.1 µs vs flat
  49.4 µs). Binary search over ~100 ranges is already cheap.
- English on Japanese dictionaries degenerates per-character: unidic's
  lexicon carries single ASCII letters and the space as entries, so
  every byte is a dictionary hit. Not a defect — the EnglishExt schema
  is the intended EN path.
- N-best at real scale: ipadic 5-best on a 48-byte (16-rune) sentence
  is 9.9–10.1µs per call on x86 (two runs), 10.5µs on ARM
  (`bench/nbest_trial.odin`; the micro-scale arm moves ±10% across
  windows).
- char.def unknown flags (ARM, `flags_speed.odin`, ipadic with
  invoke=1 / KANJI-split flags): 1K Viterbi 48.7µs, 10K 547.8µs — the
  flag-driven lattice is no slower than the default table's.

### Text-pool and result-sink throughput

*What it measures: the input-shape axis real consumers bring (news,
novel, techdoc, code styles) and the output-sink axis (morpheme list
vs surface strings vs spans, arena vs heap). Within one table the rows
differ only in shape or sink, so the ratios are the content; absolute
rates wobble ±10–15% between windows, and the relative story is
stable.*

x86 (`bench/sink_probe.odin`, ipadic, variant pools — news sentences
concatenated with no separator; novel-style and techdoc-style
paragraphs and code-shaped blocks joined with "\n\n"):

| Pool | Viterbi tokenize 100K | Viterbi 240K single call | bytes/token |
|---|---|---|---|
| news (no separators) | 10.34 MiB/s | 10.48 MiB/s | 4.67 |
| novel ("\n\n" paragraphs) | 10.96 MiB/s | 11.39 MiB/s | 4.65 |
| techdoc ("\n\n" paragraphs) | 11.85 MiB/s | 12.39 MiB/s | 4.79 |
| code ("\n\n" code blocks) | 12.16 MiB/s | 12.14 MiB/s | 2.70 |

ARM (`bench/sink_probe.odin`, ipadic, four ~100 KB pools, median of
20; MiB/s in parentheses):

| Pool | Viterbi tokenize | Viterbi wakachi | Viterbi spans | Greedy tokenize | Greedy wakachi | Greedy spans | Viterbi 240K arena | Viterbi 240K heap |
|---|---|---|---|---|---|---|---|---|
| news (21,943 / 20,886 items) | 5,910µs (16.53) | 5,619µs (17.38) | 5,485µs (17.81) | 703µs (139.01) | 421µs (231.89) | 432µs (226.02) | 13,788µs (17.00) | 72,613µs (3.23) |
| novel (22,033 / 21,083) | 5,240µs (18.65) | 4,976µs (19.64) | 5,093µs (19.19) | 790µs (123.67) | 450µs (217.11) | 528µs (185.20) | 12,926µs (18.13) | 66,602µs (3.52) |
| techdoc (21,370 / 22,156) | 4,624µs (21.12) | 4,683µs (20.86) | 4,546µs (21.49) | 951µs (102.68) | 576µs (169.64) | 607µs (160.81) | 12,009µs (19.52) | 63,323µs (3.70) |
| code (37,916 / 38,048) | 4,488µs (21.80) | 4,454µs (21.96) | 4,303µs (22.73) | 2,336µs (41.88) | 1,556µs (62.87) | 1,651µs (59.25) | 12,203µs (19.21) | 68,674µs (3.41) |

- **Viterbi is style-flat.** Unknown-heavy styles do not regress it —
  whitespace runs are near-free lattice bytes and a grouped unknown is
  one node per run — and 240 KiB single calls hold rate on every pool
  (both hosts).
- **The style effect sits in the greedy arms** (x86 window): techdoc
  runs below news per byte (57.1 vs 63.9 MiB/s tokenize; 137.5 vs
  205.6 wakachi), code ~2.3× under news (28.2 tokenize, 55.9 wakachi)
  — inter-token spaces, punctuation runs, and short identifiers raise
  the token count 1.7× per byte (bytes/token 2.70 vs 4.67). Band
  shifts, not cliffs. The ARM code pool tells the same story through
  its density: ~38K items vs ~21K for the other pools.
- **Heap sinks, not the engine, set the rate at this shape.** The
  identical 240 KiB Viterbi call through the default heap — one exact
  multi-megabyte result allocation per call, freed per call — runs
  2.1–2.2× below the arena arms on x86 (4.70–5.71 MiB/s) and ~5× below
  on ARM (3.23–3.70 MiB/s). The downstream user measured 1.8×
  independently on the x86 machine and binary. Repeated callers keep
  the arena rate with a per-request arena or `tokenize_into`'s reused
  caller buffer. A non-arena result allocator is Viterbi-only — the
  greedy emission's growth abandons each grown-out block to the arena
  by design.
- **Pool repetition flatters every arm.** The pools repeat ~2.5 KiB
  paragraphs, holding the working set cache-resident: a real novel
  measured by the downstream user on the same binary, flags, and
  machine ran ~1.6× under the pool arm at near-identical bytes/token
  and unknown share. That factor and the heap factor multiply to the
  2.9× between these tables' shapes and the downstream user's original
  direct-Odin 3.6–3.9 MiB/s — not an engine difference.

### Transient memory per tokenize call (x86)

*What it measures: the request-scratch high-water a service pays per
in-flight call — the number to size worker memory pools against.
Deterministic, so it does not wobble like the wall figures.*

One request on a dynamically grown arena under a tracking allocator
(`bench.odin`'s peak lines):

| Dictionary | Mode | 1K | 10K | 100K |
|---|---|---|---|---|
| ipadic 2.7.0 | Viterbi | 377 KiB | 4.9 MiB | 40.6 MiB |
| ipadic 2.7.0 | LongestMatch | 120 KiB | 1.1 MiB | 8.6 MiB |
| unidic 2.1.2 | Viterbi | 643 KiB | 5.1 MiB | 41.9 MiB |
| unidic 2.1.2 | LongestMatch | 120 KiB | 1.1 MiB | 8.6 MiB |
| jieba 0.1.1 | Viterbi | 216 KiB | 1.6 MiB | 13.4 MiB |
| jieba 0.1.1 | LongestMatch | 120 KiB | 0.6 MiB | 8.6 MiB |

Viterbi runs ~415 bytes per input byte at ipadic scale (lattice nodes
+ DP arrays + walk table + output) — the number behind the SDK's
retained-scratch sizing (~350 B/byte documented at the shim, the rest
block rounding and growth). LongestMatch's floor is the morpheme
output itself (~21K morphemes ≈ 8.3 MiB at 100K), which is why its
100K figure is dictionary-independent.

### Concurrent tokenize scaling

*What it measures: aggregate throughput of G workers on one shared
read-only analyser (each with its own arena, the documented contract)
against a one-analyser-per-worker control — the pair isolates whether
sharing itself costs anything.*

`bench/tokenize_par.odin`, median of 3:

| workers | shared, x86 | control, x86 | shared, ARM | control, ARM |
|---|---|---|---|---|
| 1 | 10.36 MiB/s (1.00×) | 10.57 MiB/s (1.00×) | 15.35 MiB/s (1.00×) | 15.25 MiB/s (1.00×) |
| 2 | 1.51× | 1.59× | 1.92× | 1.89× |
| 4 | 1.97× | 1.88× | 3.27× | 3.38× |
| 8 | 2.10× | 2.03× | 4.28× | 4.19× |

- **Sharing costs nothing**: on both hosts the shared and control
  sweeps agree within their spread.
- **Each host's ceiling is its own memory story.** x86 (8 cores /
  16 SMT, 8 MB L3): 8 workers' scratch streams plus the shared ~40 MB
  of tables overflow L3, and the trie walk's random access pays RAM
  latency — size a pool around ~2× single-thread throughput on that
  class of part, or partition dictionaries per worker. ARM (12 full
  cores, no SMT, large per-core L2) scales near-linearly: 4.28× at 8
  workers.
- The x86 8-worker multiplier moves with the window like every wall
  figure (2.0–2.2× in this window, single-thread ~10.4 MiB/s).

## Against MeCab and ChaSen

*What it measures: the SDK layer, not the engines. The same text goes
through libmecab and moli's Python SDK against dictionaries built from
the same source tree, so the row gaps are binding + result-model +
wrapper cost. The engines sit at parity: moli's native Viterbi is the
tokenize table's MiB/s column, MeCab full-features its own row here.*

Single-process Python rates over one 307 KB jp_pool text (65,824
morphemes counted identically by every mecab and moli arm). libmecab
0.996 via the Debian/Ubuntu SWIG binding; UTF-8 ipadic 2.7.0 rebuilt
with `mecab-dict-index` from the same source tree moli imports;
`bench/sdk_mecab_compare.py`.

Same-shape windows put mecab -Owakati between 2.1 and 8.3 MiB/s on x86
with CPU PSI 0 throughout — ratios inside one window are the read;
cross-window absolutes are not.

| API | rate (x86) | rate (ARM) |
|---|---|---|
| mecab default (full features) | 6.99 MiB/s | 11.14 MiB/s |
| mecab -Owakati | 8.22 MiB/s | 13.73 MiB/s |
| chasen default (full features) | 0.44 MiB/s | — |
| chasen wakati | 0.44 MiB/s | — |
| moli tokenize (view, len only) | 4.00 MiB/s | 5.64 MiB/s |
| moli tokenize (full list) | 2.23 MiB/s | 2.75 MiB/s |
| moli wakachi (surface strings) | 4.13 MiB/s | 5.56 MiB/s |
| moli parse (one TSV string) | 3.73 MiB/s | 5.19 MiB/s |
| moli wakati (one space-joined string) | 4.35 MiB/s | 5.96 MiB/s |

ChaSen 2.4.5 (the Debian package; x86 arm) joins through libchasen
driven in-process via ctypes, configured by a run-time copy of the
distribution's UTF-8 ipadic rc with GRAMMAR pinned to the ipadic
package's own grammar directory — the same ipadic 2.7.0 every other
arm reads. Its count is 65,925 morphemes, 0.15% above the shared
65,824 — an engine-level segmentation difference, not a dictionary
one.

At 0.44 MiB/s on both its arms it is an order of magnitude under this
SDK's string arms and ~15× under the MeCab binding: the older lineage
is not a competitive bar on this hardware.

The 307 KB input is one unchunked call, far above the retained-scratch
cap (cause 2 below) — the moli rows are the fresh-map-per-call shape,
not what a request-sized or chunked caller sees.

### The two causes of the SDK-side gap

1. **The shared library ships optimized.** `sdk-lib` builds
   libmoli.so at `-o:speed`; Odin's default `-o:minimal` (no inlining,
   runtime checks everywhere) costs ~7–8× on every SDK arm — chunked
   wakati 1.68 vs 13.64 MiB/s on 8 KB pieces (x86). This, not the
   result model and not allocator behaviour, is the dominant factor.
2. **The per-call request arena above the retained cap.** The tokenize
   entry keeps a per-calling-thread scratch arena retained to a 64 MiB
   high-water mark (thread-private, reset per call — MeCab's per-tagger
   lattice strategy; the core's no-global-state rule and the
   shared-analyser contract are untouched). Request-sized calls stop
   re-paying a fresh map's first-touch page faults. Crossing the cap
   shows it sharply: 8 KB chunks (retained) ran 13.64 MiB/s while
   16 KB chunks (fresh map per call) ran 4.84 MiB (x86). Two tiers
   keep inputs on the retained path:

   | Tier | Sizing | Retained up to |
   |---|---|---|
   | full margin | 1024 B per input byte + 64 KiB base (~3× the measured ~350 B/byte) | just under 64 KiB of input |
   | tight | 512 B per input byte (~1.24× the measured ~415-byte transient peak) | just under 128 KiB of input |

   A refusal at the tight tier retries once at the full margin — never
   an OutOfMemory the full margin alone would not also return. Past
   both tiers the call pays ~3× over retained (the fresh map plus the
   Python-side assembly of a tens-of-thousands-morpheme result) — an
   SDK-layer cost; the engine holds per-byte rate at 240 KiB single
   calls. The cap remains the per-thread worst-case resident cost. On
   the 64 KiB-chunk shape the retained path saves ~58% wall on discard
   and ~28% on full materialisation against the fresh-map path
   (interleaved, polarity-cancelled).

### The chunk rule

Chunk to stay under the tiers, but cut on the rule — chunking changes
the morpheme stream:

- A run of whitespace is one grouped unknown (a "\n\n" blank line is a
  single 記号，空白 morpheme). A cut landing inside the run — "after a
  newline" is inside it — splits that morpheme: one extra morpheme per
  such cut.
- Cut only immediately after a complete run of newlines. No shipped
  dictionary surface contains a newline, so no morpheme can span such
  a cut; on the measured pools the concatenation reproduced the single
  call's surface+POS sequence exactly (1,254 cuts).
- That identity is empirical, not a theorem: each chunk restarts
  BOS/EOS context, so the transition into the first morpheme after a
  cut differs from the whitespace unknown's right-id row in principle.
- The rule ships executable: `safe_chunk_offsets` in the library (byte
  offsets, one allocation) and `safe_chunks` in the SDK (str pieces,
  byte-measured targets); both pin the same fixture identities in
  their test suites. Callers on the engine directly have no reason to
  chunk at these sizes at all.

### Chunked against chunked

At the request-sized shape the fair comparison runs both engines
chunked, and it is host-dependent.

x86, one window (`sdk_mecab_compare`'s chunked arms, 8/16 KB safe-cut
pieces of the "\n\n"-joined pool, medians of 15): mecab -Owakati
12.65/10.76 MiB/s against moli wakati 15.09/12.10 — a real but thin
1.1–1.2× edge (the lazy view 13.04/10.59). The 307 KB single call sits
at ~0.5× (8.22 vs 4.35, the fresh-map shape).

ARM, median of 15:

| arm | 2 KB | 8 KB | 16 KB | 64 KB |
|---|---|---|---|---|
| mecab -Owakati | 24.2 MiB/s | 24.5 MiB/s | 24.3 MiB/s | 18.4 MiB/s |
| moli wakati | 11.6 MiB/s | 18.5 MiB/s | 17.3 MiB/s | 15.8 MiB/s |
| moli wakachi | 15.5 MiB/s | 15.4 MiB/s | 15.3 MiB/s | 13.3 MiB/s |

- moli wakati peaks at 8 KB (18.5 MiB/s, 0.76× mecab); the 2 KB arm
  sits lower — a per-call fixed cost that amortises from 8 KB onward.
  "Above the MeCab binding" is an x86-window statement, not a platform
  claim.
- The native engine (Viterbi 15.7 MiB/s at 100K ipadic, the ARM
  tokenize column) is ahead of mecab full-features (11.1 MiB/s at 307
  KB) — the gap is entirely in the SDK layer.
- The chunked path needs newline structure: the safe-cut rule places
  cuts only after newline-ending whitespace runs, so a no-separator
  document — the 307 KB comparison text itself — has no safe cut
  (`safe_chunks` returns it as one piece) and stays on the fresh-map
  path by construction.
- Chunks beyond ~128 KB degrade toward the unchunked shape: the
  per-call Python-side assembly dominates (64–128 KB chunks ride the
  retained tight tier).
- The `Morphemes` view pays its conversion cost (cached enum
  singletons, per-result interning of repeated dictionary fields,
  direct `tuple.__new__`, FASTCALL entry) exactly per morpheme read,
  on full-ipadic 16 KB chunks: only-`len()` callers run at the
  engine+box rate (~9.2 MiB/s), first-10-per-chunk partial reads at
  ~10.5 MiB/s, full `list()` materialisation at ~3.1 MiB/s.

## Accuracy

*What it measures: segmentation agreement with gold boundaries —
precision (of the boundaries moli emits, the share that are gold),
recall (of the gold boundaries, the share moli finds), F1 their
harmonic mean. Deterministic, x86-host.*

### Boundary F1 vs KWDLC (ipadic 2.7.0)

5,127 .knp files; 16,049 scored sentences before the reference
pairing; sentences reconstructed from gold morpheme surfaces; interior
boundary offsets compared with a two-pointer over ascending lists,
micro-aggregated.

- **Precision 0.9009, recall 0.9618, F1 0.9303** (2026-09-26,
  same-set protocol below): 16,037 sentences, gold boundaries 236,704,
  predicted 252,707, matched 227,657; unknown morphemes 1.09%;
  run-grouped control 0.9271.
- **Reference control — MeCab+ipadic on the identical sentence set:
  P 0.9008 / R 0.9617 / F1 0.9303** (gold_b 236,704 on both arms — the
  same-corpus proof). Parity to the fourth decimal: 0.9303 is the
  cross-convention ceiling on this corpus, and moli's Viterbi matches
  reference MeCab.
- **Same-set protocol** (`euc_unmappable=12`): `f1_kwdlc.odin` writes
  the corpus it scored (one line per sentence, surfaces joined by
  spaces) and `f1_mecab_control.py` consumes that file — the knp parse
  and filter rules exist once, on the Odin side. The control's EUC-JP
  dictionary cannot encode 12 of the 16,049 sentences, so it writes
  them to `tmp/kwdlc_euc_drops.txt` and refuses until the f1 harnesses
  drop the same sentences (content-matched, idempotent); both arms
  then score exactly the 16,037 the corpus file lists.
- **The over-split pattern is cross-convention, not error.** Recall >
  precision, and over-splits concentrate after hiragana (15,924 of
  25,050) — consistent with the gold following JUMAN/Kyoto guidelines
  while the analyser is ipadic. No ipadic-convention gold corpus is
  redistributable.
- **char.def-faithful unknown flags beat whole-run grouping**: F1
  0.9303 vs 0.9271 on the same corpus.
- **`patterns.qpat` is a label-quality tool, not a segmentation
  lever** at ipadic scale: a principled six-row trial (第/的/性/化/様
  affixes + a KATAKANA charset row) moves F1 0.9303 → 0.9304 — noise,
  with exactly one pattern-labelled morpheme across all sentences.
  ipadic's lexicon already carries those affixes; unknown rate 1.09%.
  The resource stays shipped for labelling and for dictionaries whose
  affixes are OOV.
- **The unknown-cost parameter space is flat** (`f1_grid.odin`,
  2026-09-11: bias −4000…+4000 × per_rune 0…5000, 54 points, same
  corpus): the best point (bias −4000, per_rune 1000) reaches 0.9314
  against the default 0/0's 0.9303 — +0.0011, a tenth of the 0.9406
  oracle ceiling. The surface is ridge-shaped in per_rune alone (1000
  the mild ridge, 5000 a valley at 0.9272) and insensitive to bias.
  The defaults stay 0/0 — dictionary-faithful costs, no hidden tuning;
  the calibration axis, if ever wanted, is the re-ranker, not the cost
  knobs.

### N-best oracle — re-ranker ceiling (ipadic 2.7.0)

*What it measures: what a perfect re-ranker over moli's own N-best
enumeration could add — the ceiling for any post-hoc ranking work.*

`f1_oracle_nbest.odin`, same corpus and protocol (16,037 sentences,
re-run 2026-09-26; oracle@1 reproduces the faithful arm exactly):
every sentence enumerated with `tokenize_nbest` 10-best, each path
scored against the gold interior boundaries. Deterministic — the
enumeration is the shipped engine.

- **oracle@k** — boundary F1 of the best path within the k cheapest:
  @1 0.9303, @3 0.9353, @5 0.9376, @10 0.9406. A perfect re-ranker
  could add at most +0.50 / +0.73 / +1.03 pt.
- **Exactly-gold path in the enumeration**: rank 1 for 16.61% of
  sentences (2,664); within 3 for 19.16%, within 5 for 20.21%, within
  10 for 21.69% (3,478); absent from the 10-best for 78.31%.
- **Cost margin to overturn** (the 3,478 gold-in-10): 2,664 gaps zero
  (gold already cheapest); the 814 real gaps split 4 within 100, 102
  within 1,000, 681 within 10,000, 27 over (mean 901 over all 3,478,
  max 23,447).

Reading: the exact-gold route is small — 814 contested sentences at
k = 10 — and most of the oracle headroom is near-miss paths, not
recoverable gold segmentations. The ~78% of sentences whose gold never
appears in the 10-best need a wider enumeration or different cost
parameters, not better ranking of the current candidates.

### Hand-verified quality gate

Reference corpora are research-use restricted, so the standing quality
gate is a hand-verified set (`bench/quality.odin`):

- 12 asserted sentences across ipadic/unidic/jieba where the correct
  split is unambiguous — 12/12 on both hosts.
- Eyeball rows for dialect-sensitive and unknown-run cases: katakana
  runs group, QR|コード splits, English degenerates per-character on
  Japanese dictionaries.
- A tokenize-vs-wakachi self-consistency check.

### Licence rules for corpus measurement

Corpus text and corpus-derived fixtures are never committed; aggregate
numbers only. The KWDLC clone lives under gitignored `dict/`, used
locally under its CC-BY terms. The Kyoto University Text Corpus
carries Mainichi newspaper copyright — no article text, not even
illustrative sentences. Application-gated resources (BCCWJ/NINJAL,
KCBS) stay excluded.

## Test coverage

*What it measures: which functions, lines, and branches the suite
actually executes — reported as lower bounds: a failure-path branch
only a failing allocator fires is dark by construction. Improvements
come from fault-injection breadth, not chasing percentages.*

Measured 2026-09-26 on the x86 host; the measured file list derives
from `src/moli` at run time (platform-suffixed files compiled out of
the current build are excluded, so a new source file cannot silently
escape measurement).

- **Function: 233/235 = 99.1%.** The two dark symbols are real, not
  inlining artifacts: `greedy_walk`'s `[dynamic]Morpheme`
  specialisation (the `tokenize_into` sink, unexercised in
  LongestMatch mode by the measured build) and `lemma_rewrite_en_gb`
  (the suite loads `.EnglishGB` with `lemma_locale` US or None, never
  GB). Both gained tests after the measurement pass.
- **Lines: 2597/2944 = 88.2% strict; 2597/2723 = 95.4%** on lines that
  carry machine code — 221 dark lines are structural (field
  continuations, else-braces, jump-table labels) and can never be
  marked.
- **Branches: 355/778 = 45.6%** of encountered **moli** conditional
  sites executed in both directions, no landing-side exclusion (an arm
  whose job is to fail counts as a branch). Each `if err != nil` is a
  branch whose failure side exists to fire under a failing allocator,
  and the suite fires those at the public boundaries only.

Method — `odin test -cover` does not exist on this nightly, so
coverage runs under valgrind's callgrind on a `-debug` (`-o:none`)
test build:

    odin build tests -build-mode:test -debug -collection:moli=src \
        -define:ODIN_TEST_THREADS=1 -out:tmp/test_debug
    valgrind --tool=callgrind --dump-instr=yes \
        --callgrind-out-file=tmp/callgrind_instr.out tmp/test_debug
    python3 bench/cov_instr.py

`bench/cov_instr.py` resolves every executed instruction's address
through the binary's DWARF (addr2line): a line is covered iff some
instruction attributed to it executed, so instructions folded into
inline/memcpy sequences still land on their own source lines.
`bench/cov_parse.py` is the alternative callgrind_annotate pass.

A conditional counts exactly when both its fall-through and target
addresses appear in the dump; a site belongs to the moli denominator
exactly when its own address attributes to a `src/moli` file — the
same scoping the line and function passes apply.

Two recorded properties of the method:

- valgrind serialises threads, so `acquire_recheck_storm_test`'s
  bounced polarity never fires under it (the test fails there and its
  remaining checks count dark; it is green under `just test`).
- `qdct_map_posix.odin` is measured while its `#+build windows` twin
  is excluded on a Linux build by the derived list — it carries no
  machine code here and would count as permanently dark.

## Python SDK FFI overhead

*What it measures: the price of crossing the SDK boundary — the same
call through the extension against a native reference on the same
fixture and texts, so the difference is wrapper + boxing cost alone.*

`just sdk-probe` (one analyser held, sequential calls, warm-up first)
against the ipadic fixture; native reference from
`bench/native_probe.odin`. Measured 2026-09-26 on the ABI-v7 tree
(x86), unified statistic: the median of five block means on both
columns.

The Python column includes the wrapper's per-call in-flight bracket
(a drain-mutex lock pair) and, on the `[0]`/`list()` rows, the view's
per-slot build lock on first materialisation.

| call | native (x86) | Python SDK (x86) | native (ARM) |
|---|---|---|---|
| tokenize 犬が歩く (view, unread) | 0.39 µs | 1.46 µs | 0.70 µs |
| tokenize 犬が歩く [0] (3rd of 3) | — | 2.72 µs | — |
| tokenize 犬が歩く ×100 (view, unread) | 7.96 µs | 27.08 µs | — |
| tokenize 犬が歩く ×100, list() (300 morphemes) | — | 209.7 µs | — |
| tokenize 1,200 bytes (300 morphemes) | — | — | 14.70 µs |
| wakachi small | — | 1.63 µs | — |
| spans small | — | 2.45 µs | — |
| nbest small k=3 | — | 4.95 µs | — |
| stats | — | 0.79 µs | — |
| classify_locale | — | 0.14 µs | — |
| snapshot (fixture, ~5 KB image) | — | 1.40 µs | — |

- **An unread `tokenize` call** costs engine + result box + the
  wrapper's in-flight bracket (two uncontended mutex acquisitions,
  ≈0.02 µs).
- **Reading a morpheme builds it on access**: ≈0.61 µs per morpheme
  fully materialised (cached enum singletons, per-view interning of
  repeated dictionary fields, direct `tuple.__new__`, one list slot,
  and the first-materialisation build lock that makes concurrent
  materialisation of one view safe) — paid only on results actually
  read.
- **Result memory follows the same shape** (VmRSS delta for holding
  1 MiB of chunked Japanese text, 64 results, fresh process;
  2026-09-11): eager `list()` of everything ≈ 189 MiB (76 MiB traced
  Python objects plus allocator growth); unread views ≈ 30 MiB (the
  native boxes); first-10-per-chunk ≈ 6.9 MiB, where the eager build's
  transient full lists cost ≈ 11 MiB.
- **The cheap calls stay cheap**: classify_locale ≈ 0.14 µs; stats at
  ≈ 0.8 µs is a plain cached read — the entries fingerprint is stamped
  once at construction, so no lock-and-rewrite fixed cost sits on the
  call.

## German dictionary trial (ARM)

*What it measures: a non-MeCab schema through the same pipeline — load
shape and leak discipline — plus the search-side knob that makes
out-of-vocabulary compounds split like a German reader would.*

`bench/german_trial.odin`, DWDSmor Open Edition converted CSV
(`dict/german/german.csv`):

| Metric | Value |
|---|---|
| Entries loaded | 53,531 |
| Load time | 76 µs |
| Skipped rows | 2 |
| Leaks | 0 |

Default options keep compounds whole (`Hausmuseum` → 1 morpheme);
`unk_cost_per_rune=2300` splits OOV compounds (`Haus|museum`,
`Museums|platz`) while keeping short OOV words whole (`Demo`, `zum`).

## Design decisions grounded in measurement

Every line below carries the number or the measured null that grounded
it; the design-shape rationale itself lives in the code's doc headers,
which are the specification.

- **The connection matrix stays dense i16.** Counting the shipped
  files: ipadic 2.7.0 holds 1,731,856 unique triples for 1,731,856
  cells; unidic-mecab 2.1.2 holds 35,772,361 for 35,772,361 —
  100.000% density in both, zero duplicate cells, zero out-of-range
  ids. A sparse layout keyed on measured density would never activate
  on a real dictionary.
- **`patterns.qpat` rows are absent in every measured dictionary**
  (0 rows): with none loaded, the unknown-resolution ladder is
  byte-identical and pays one slice-length check per lattice position.
- **The strict-UTF-8 pre-pass and the per-rune cancellation poll are
  invisible at noise**: every tokenize delta sits inside a ±9%
  window-variance band with both signs.
- **Non-zeroed allocation has a measured crossover, not a tuned
  constant.** Above cache scale the arena's zero-fill is a pure
  bandwidth tax — memset is a third of tokenize instructions when the
  fill runs, 8.5% without it — so the lattice's growth buffers request
  `Alloc_Non_Zeroed` from 1 MiB up. Below that gate the fill works as
  a write warm-up: allocating it away slows the 1K Viterbi arm ~9%,
  and routing every allocation through the raw mode moves wall clock
  nowhere despite −13% instructions at the 100K arm. F1 identical
  either way (0.9303, gold/pred/match counts identical).
- **A first-rune skip bitmap before the lattice walk is refuted by
  arithmetic, not built**: `cedar_step` is ~10 instructions, and the
  skippable work is a fraction of `collect_recursive`'s 2.6%
  instruction share — under the 3.5% adoption bar.
- **Branch micro-optimisation of the DP relaxation is spent.** Folding
  the successor's whole node-side contribution into the packed cost
  array removed every per-edge unknown branch but widened the hot
  array from 2 to 8 bytes per successor: +1.1%/+0.3% on the primary
  arm — a wash. i64→i32 stays rejected on the overflow contract.
- **Raw-growth result buffers pay only for large elements.** The
  wakachi/spans sinks (16 B / 32 B elements) top out at 512 KB / 1 MiB
  on a 100K text — at or under the 1 MiB crossover — and their 18.7%
  memset+memcpy instruction share costs no wall clock; Morpheme's
  128 B elements (a 2.8 MB result at 100K) are what ride the raw path.
  The tokenize result grown zeroed is the largest memset in the
  profile (LM: 31.6% memset + 8.0% memcpy) — the same gate applies.
- **The greedy longest-match keeps its per-request scan table**: the
  greedy wakachi arm measures 220 MiB/s through it.
- **The import edge's one-pass-per-concern shape carries two measured
  refusals.** An entries-array reservation sized from sampled row
  lengths costs +52 MiB of transient peak at unidic scale for zero
  load-time gain (the growth reallocs extend in place); extending the
  `tuple.__new__` cut to Span/NBestPath/Stats plus an iterator
  `__length_hint__` measures null (spans −0.35%, ~5 ns/item; `list()`
  +0.01% — `list(view)` already presizes via the view's `sq_length`).
- **The entries fingerprint mixes words, not bytes** — eight bytes per
  step cuts the construction-time walk ~8× in instructions (the FNV-1a
  chain is latency-bound at one dependent multiply per byte). A
  zero-copy mapped restore of the cedar arrays is refused on bounded
  gain: ~15–25 ms of the 141 ms unidic mapped restore, against the
  ownership shadow the build path would then have to carry.
- **The lattice build walks each same-class run once.** A per-position
  scan to the run's end measures 103/416/1,620 ms at 10/20/40 K
  katakana runes — 4× per doubling, the quadratic — where the shipped
  single walk measures 3/3/7 ms at a byte-identical output fingerprint.
- **The SDK's single-string results are presentation, not ABI**:
  `wakati`/`parse` assemble in the extension and equal the piecewise
  Python joins byte for byte — no export added, ABI version unchanged.
