# AGENTS.md — moli

Rules and policy for coding agents on the moli codebase — not session
Records or measurements. User-facing documentation lives in README.md
and docs/ (index: docs/index.md).

# Project description

## Overview

moli is a morphological-analysis library written in **Odin** (package
`moli`, sources in `src/`): MeCab-format CSV dictionaries import into
a double-array trie over a dense i16 connection matrix, and Viterbi
(the default) or greedy longest-match tokenisation runs over the
result — Japanese (ipadic, UniDic), Chinese CN/TW/HK (mecab-jieba),
English GB/US, and a German trial. It is designed as a deterministic,
low-dependency backend for concurrent services. The code and its doc
headers are the specification.

## Package layout and dependency direction

Dependencies flow one way only: nothing under `src/` imports `tests/`,
`bench/`, or `sdk/`.

- `src/` — the analysis core (cedar trie, importer, tokenizer, Viterbi,
  char classification, qdct snapshots). It must not touch `os` or
  `thread`: file I/O belongs to the importer edge, concurrency to the
  caller. This keeps the core testable and embeddable.
- `tests/` — a separate package importing the core through
  `-collection:moli=src`. Its fixtures are small and committed
  (provenance and licences in `tests/fixtures/README.md`).
- `bench/` — single-file measurement harnesses, run in `-file` mode
  from the repo root. Scratch lives under gitignored `tmp/`, the real
  dictionaries under gitignored `dict/` (acquisition in README.md's
  "Dictionaries" section).
- `sdk/moli-python-sdk/` — a C ABI (`native/` → `lib/libmoli.so`,
  hand-mirrored by `c/moli_abi.h`) with a CPython extension
  (`c/moli_native.c`) and a Python layer (`src/moli/`). The analysis
  core stays untouched by the SDK: everything the SDK needs lives at
  the ABI boundary. The shim (like the importer) is the only other
  place allowed to link `core:thread`.

# Project principles

These principles govern every part below; each one names the sections
that carry its rules.

- **Correctness, processing performance, and resource behaviour are
  the product.** A change that trades any of them for convenience is a
  defect. Enforced in: Design rules; Testing conventions.
- **The specification governs the implementation.** Where code and
  specification disagree, one of them is defective — determine which,
  and fix that side. The code and its doc headers are the
  specification.
- **The Analyzer contract is the concurrency model.** The `Analyzer`
  is immutable after `load` returns; `tokenize`-family calls run
  concurrently on a shared `^Analyzer`; mutating calls serialize;
  freeing relative to in-flight calls is a real contract — an in-use
  count or serialized teardown, never "nobody holds it now". Each
  proc's thread-safety is documented at the API.
- **Every resource has one owner.** There is no GC safety net:
  allocators are explicit, lifetimes are visible at the call site, and
  an ownership transfer (a cache with a release hook, a buffer whose
  callee adopts it) is picked once. Enforced in: Memory and ownership.
- **Verdicts come from artifacts.** Suite outcomes are read from the
  log, never the exit status alone; performance claims are re-measured
  before they are believed. Enforced in: Build, test, commit.
- **Write for the next reader.** No text cites material the reader
  does not have, and no figure rots between edits. Enforced in:
  Self-containment.

## Self-containment

Committed code, doc headers, error strings, and documentation must be
self-contained: no citations of private notebooks, plans, sessions, or
issue numbers ("see cedar.md C5", "issue L6") — every such citation
dangles for a reader without the referenced material. State the
constraint in prose where it matters.

The same discipline bounds the figures written into the tree: exact
numbers that move while the code evolves (test counts, entry counts,
timings quoted in prose) rot between edits, and measured numbers are
records, not rules. Where a magnitude carries a rule, write it as
about/over/under and name the file or identifier that owns the exact
value.

# Development guide

## Build, test, commit

```sh
just check       # odin check src/moli + the SDK shim, -vet -strict-style
just test        # odin test tests (serial) + the log gate below
just sdk-test    # SDK build, shim ABI tests under the same gate, pytest
```

- Prefer the just recipes over raw odin invocations — they pin the
  working directory, the thread count, and the log paths.
- **Verdicts come from the log, never the exit status alone**: grep
  the suite log with
  `grep -a -E '\[ERROR\]|\[FATAL\]|\[WARN \]|\[WARN\]|\+\+\+ leak|bad free|out of range'`.
  Two details are load-bearing: leak blocks print under a *padded*
  header (`[WARN ] --- <bytes> :: ...`) which `\[WARN\]` alone cannot
  match, and a failing test can spill NUL bytes that make grep treat
  the whole log as binary — hence `-a`. The leak discipline is **zero
  leak lines**, not "fewer than before".
- The Odin compiler tracks the **latest nightly** (currently
  `dev-2026-09-nightly:a2fb372`). If a nightly breaks the build, pin
  the last known-good hash and note it here. This nightly ships no
  `odin fmt` subcommand — there is no formatter step; re-check after
  a compiler update.
- Check the tree before every commit: never commit `.venv/`,
  `__pycache__/`, `.so` artifacts, `tmp/`, `dict/`, or any dictionary
  row or corpus text (`.gitignore` covers the paths; the rule covers
  the bytes — dictionary data is fetched, never distributed).

## Python SDK (sdk/moli-python-sdk)

- **Build order is Odin first, C second** (`just sdk-build`): the
  extension links `libmoli` (rpath `$ORIGIN/lib`, `@loader_path/lib`
  on macOS), so a stale `.so` surfaces as undefined-symbol import
  errors. After touching the shim, rebuild both.
- **The header mirror is hand-written on both sides**; the contract is
  enforced by `moli_abi_check`, which the extension verifies at import
  and the Odin ABI test asserts against. A layout change on either
  side must move all three together (shim structs, `moli_abi.h`,
  `moli_native.c`'s `verify_abi_layout`) and bump the ABI version.
- **Gates**: `just sdk-test` runs the Odin ABI tests under the
  zero-leak gate (log `tmp/sdk-test.log`) and then the pytest suite in
  `.venv`. Both passes byte-compare their snapshot of the ipadic
  fixture against the committed golden
  `tests/fixtures/qdct_ref_snapshot.qdct` (qdct bytes are stable
  across loads, thread counts, and the ABI boundary on every supported
  target) — no run-order coupling; plain `pytest` is green on a fresh
  clone. After a deliberate format change, regenerate the golden by
  copying the shim pass's `tmp/sdk_ref_snapshot.qdct` over it.

# Development rules in detail

## Design rules (code-review criteria)

### Library purity and the Analyzer contract

- No process-global variables. All state lives on the `Analyzer` (or
  the builder during `load`) and is passed explicitly.
- Allocators are always explicit parameters. `context.temp_allocator`
  is intra-procedure scratch only and never appears inside library
  procs — the lifetime contract of returned data depends on the caller
  knowing the allocator.
- Request-scope data lives on the caller's arena; an arena-allocated
  pointer never escapes its lifetime scope — copy into the destination
  allocator instead.

### Memory and ownership

- `string` / `[]T` cloned with allocator `a` are freed with
  `delete(x, a)` — a bare `delete(x)` frees through
  `context.allocator` and is a bad free whenever the two differ. The
  mirror rule: a `[dynamic]T` or map made with `make(..., a)`
  *carries* its allocator in the value, so bare `delete` on those is
  correct as written.
- A `[]T{...}` literal whose elements are compile-time constants is
  placed in static data — `delete` on it is an immediate bad free.
  Leave constant literals undeleted.
- `append` on a nil `[dynamic]` (or first insert on a zero-value map)
  grows through `context.allocator` — under `odin test` that strands a
  backing buffer and prints a leak WARN. Create long-lived collections
  with `make(..., a)` in the owner's init.
- Core `os` procs allocate through the allocator you pass: `os.stat` /
  `os.lstat` clone `File_Info.fullpath`, `os.read_link` its target,
  `os.environ` and `os.make_directory_temp` return owned clones. Never
  discard the result (`_, err := os.lstat(...)`) with a non-temp
  allocator. Two shapes pass review: use-then-delete at the call site,
  or run the whole procedure's scratch on a temp allocator / load
  arena and clone only what escapes.
- Handing a value to a cache with a release hook transfers ownership —
  a `defer`-destroy at the call site then double-frees. Pick ONE
  owner.
- Freeing an object obtained through a lookup requires an in-use count
  (or unlink-then-destroy). GC-language prune patterns do not port to
  manual memory: a just-returned pointer can be pruned before its
  first use.
- Odin `defer` fires at the end of the enclosing **scope**, not the
  procedure. For must-run-on-return cleanup, hoist a flag and use a
  procedure-scope `defer if flag { ... }`.

### Error model

- Failures are a closed per-boundary vocabulary (an enum, or a plain
  union combining the enum with context structs) propagated with
  **explicit checks** (`if err != nil`) — `or_return` is not the house
  idiom.
- Naming: the nil-able failure union at a boundary takes the `_Err`
  suffix (`Load_Err`, `Tokenize_Err`); the plain fault enum inside it
  takes `_Fault` (`Load_Fault`, `Tokenize_Fault`); a struct explaining
  a failure's circumstances takes `_Error` (`SchemaMismatch_Error`
  carrying line/expected/got). Union member types must be real types —
  spell out the enum + info-struct composition rather than bare
  constants.
- No dead members: don't reserve never-returned error values for
  hypothetical future strict modes. Add them when they can actually be
  returned.
- No string-matching on error kinds; no panics for runtime lookup
  failures (`.NotFound`-style returns). Panic is for startup
  invariant violations only.

### Naming conventions

- Allocator parameters and fields follow the Odin core convention
  (measured against the compiler's `core/`: `allocator` 297 vs `alloc`
  4): generic is `allocator`; a role-named allocator takes the
  `<role>_allocator` form (`arena_allocator`, `scratch_allocator`),
  like core's `temp_allocator` / `buf_allocator`. A `mem.Arena` /
  `mem.Dynamic_Arena` value — the arena object itself, not the
  allocator view — keeps a plain role name (`scratch`, `arena`).
- Multiword type names are `Word_Word` (`Entry_Record`, `Char_Class`,
  `NBest_Path`); concatenated forms (`EntryRecord`) are not used.
- Allocator-error locals carry the failing operation as a prefix
  (`merr` = make, `aerr` = append, `cerr` = clone/copy). Odin rejects
  shadowing and same-scope `:=` redeclaration, so parallel sites in
  one scope take distinct/numbered variants (`merr2`, `merr3`) — that
  is the idiom, don't collapse them into a single name.
- Shim naming map (sdk): wire structs carry the `_FFI` suffix
  (`Morpheme_FFI` ← C `Moli_Morpheme`); the `*_Code` enums are the
  ABI-flattened mirrors of the core `*_Fault` enums (union context
  folded into plain codes).

## Testing conventions

- **Zero leak WARNs** (the grep in Build, test, commit): `odin test`
  runs every test under a tracking allocator and prints a leak block
  per leaked allocation — leaks don't fail the test, the grep
  discipline is the rule. Include an explicit load → tokenize → free
  cycle test so the Analyzer's ownership design is actually checked,
  and a concurrent-tokenize test for the thread-safety claims.
- **No sleeps**: time-dependent logic (benchmarks, TTLs, timeouts)
  takes an injected clock; tests advance time deterministically.
- **`testing.fail_now` aborts without running defers** (as does any
  panic): a leaked arena or fixture then corrupts the per-test
  tracking allocator and can wedge the whole runner. Use `expectf` +
  an early `return`, and guard array indexing the same way (a bounds
  panic skips defers too).
- Fixtures are small and checked in (< 10 KB). Malformed-UTF-8, BOM,
  and empty-file cases are mandatory for anything touching text or
  CSV.

## Cross-platform file handling

Linux is the development platform; macOS and Windows are supported
targets.

- Put platform differences behind `when ODIN_OS` branches or
  platform-suffixed files (`*_windows.odin`); don't scatter them.
- Build paths with the `core:os` filepath procedure group; never
  concatenate separators by hand.
- **Windows has no portable core mmap.** Any file-mapping feature
  needs an explicit decision (MapViewOfFile via `sys:win32`, or a
  no-mmap fallback with the option documented as POSIX-only).
- macOS/Windows filesystems are case-insensitive: compare and dedup
  paths with case-insensitive helpers, never `==`.
- CRLF vs LF follows the input file (MeCab CSVs exist in both); never
  re-encode behind the caller's back.
- Other-OS verification happens on a CI matrix with native builds, not
  via cross-compilation.

# Reference

## Odin language and stdlib (verified on dev-2026-09-nightly:a2fb372)

Re-check each item after a compiler update. Items marked fixed below
are probe-verified gone on dev-2026-09 and kept as history.

- **No optional-type sugar (`?T`) and no struct field defaults**
  exist on this nightly. Optionality is a `.None` sentinel enum member
  (the `os.Error` convention) or a nil-able plain union. Typed rune
  constants use the cast form `rune(0x3100)`, not `:: rune = …`.
- **`union #shared_nil` remains unusable for the enum+struct error
  shape** (probe-verified on dev-2026-09): plain-struct variants are
  rejected outright ("Each variant of a union with #shared_nil must
  have a 'nil' value"); enum variants are accepted but broken at
  runtime — any member assignment (`e = .Bad` or `e = Fault(.Bad)`)
  silently leaves the union nil, and only the explicit conversion
  `Err_Enum(.Bad)` constructs a value. A silent no-op assignment is
  worse than the old compile-time rejection, so the rule stands: the
  enum+struct error shape is a plain `union {Fault, Context}` — nil
  means "no failure", a member value constructs it directly
  (`.Some_Fault`), and a type switch takes it apart.
- **`matrix` is a keyword** (the SIMD type) — a struct field by that
  name is a syntax error.
- **Constant-data access**: the dev-2026-08 miscompilations (nested
  inline literals yielding empty strings; struct copies out of
  constant data arriving with scrambled slice fields) are gone on
  dev-2026-09 — copies and for-bindings are sound. What stands as a
  hard rule: variable indexing straight into a `::` constant is a
  compile error ("Cannot index a constant") — index constant tables
  through a materialized local (`xs := CONST`). Relevant to moli's
  constant tables (char-class ranges, schema column maps).
- **Fixed on dev-2026-09**: a make'd map cast into a union used to
  report `len() == 0`, miss every lookup, yet still iterate its
  entries — probe-verified sound now.
- **Single-test builds segfaulted on green code on dev-2026-08** (the
  `ODIN_TEST_NAMES` define changes the test binary's layout and the
  constant-data bugs were layout-dependent; fixed on dev-2026-09).
  Keep the reflex: reproduce any single-test segfault against the full
  suite before debugging it.
- **A `Dynamic_Arena` is self-referential**: never return or copy one
  by value out of the procedure that initialized it — declare it
  inline where it is used.
- **`strings.builder_make_len(n)` makes a zero-filled buffer of length
  n** (writes append *after* the zeros). Reserve capacity with
  `builder_make_len_cap(0, n, a)`. And `strings.to_string(b)` returns
  a view into the builder's buffer — clone out before returning when a
  `defer builder_destroy` is in scope.
- `core:path/filepath` traps (verified still present on dev-2026-09):
  `filepath.abs` returns `""` for input it cannot stat, and
  `dir("")`/`dir(".")` return `"."`/`""` — a peel loop following `dir`
  never terminates on such input. Use already-cleaned absolute paths
  directly and bound any directory-walking loop explicitly.

### Odin syntax that differs from C and Go

- `'abc'` is a RUNE literal — strings are always `"abc"` (escape inner
  quotes).
- `case:` in a `switch` over an enum/union is NOT a default unless the
  switch is `#partial`; full switches must enumerate.
- `+` string concatenation works only on compile-time constants —
  runtime joins go through `strings.concatenate` / `strings.join` (and
  `strings.join` returns an optional allocator error — check it).
- Procedure parameters are immutable — copy into a local to mutate.
- `for v, i in slice` binds value-then-index; `for _, x in` binds the
  INDEX to `x`.
- `fmt` treats `{` in any formatted string (including through `%q`
  and testing helpers) as a parameter brace — build JSON/CSV text by
  plain concatenation and compare with `==`.
- `for c in some_string` iterates RUNES — index bytes (`s[i]`) when
  appending to a `[]u8` buffer.
- Never return a string/view into a local stack buffer — clone out.
- A struct field named identically to an imported package is an
  "Illegal declaration cycle" — rename the field.
- `for x in []T{...} {` cannot parse the literal's brace — bind the
  literal to a local (or constant) first.
- Odin `int` is pointer-sized (64-bit on x86_64):
  `cast(int)(uintptr(p))` is a lossless bit conversion, not a C-style
  32-bit truncation.

## SDK C-side rules (paid-for landmines — keep them)

- Extension types using managed weakrefs must be `Py_TPFLAGS_HAVE_GC`
  and allocated via `PyType_GenericAlloc` (`PyObject_New` corrupts the
  heap).
- The closed flag alone cannot deliver "no call after `moli_free`" —
  the wrapper's `closing` flag + `in_flight` count bracket every
  handle call, and `close` waits them out before freeing. `close` must
  also claim the handle (null it under the GIL) *before* releasing the
  GIL, or two racing closes double-free.
- The drain/mutation locks are allocated with the object, never at use
  time — close's wait must not depend on a late allocation succeeding.
- Mutating calls (`add_user_entries`, `stats`'s scratch rewrite)
  serialize on the mut lock because the core's swap protocol assumes a
  single mutating caller.
