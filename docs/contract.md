# The Analyzer contract

What an embedder may rely on when using the library. The code and its
doc headers are the specification; this page collects the cross-cutting
rules into one place and names the file that owns each. Every example
below runs against the committed fixtures — nothing needs a fetched
dictionary.

## Model

One `Analyzer` per (language, dictionary) pair, loaded once and shared.
Everything on it is immutable after `load` returns except the lifecycle
counters and the drain hook (`Analyzer`'s own header,
[src/moli/analyzer.odin](../src/moli/analyzer.odin)):

```odin
a, err := moli.load(.Japanese, "tests/fixtures/ipadic_sample.csv", {}, context.allocator)
if err != nil { /* switch on Load_Fault / Schema_Mismatch_Error */ }
defer moli.free(&a)

// Any number of threads, one shared ^Analyzer:
ms, terr := moli.tokenize(&a, "犬が歩く", mem.arena_allocator(&arena))
```

| Call family | Concurrency lane |
|---|---|
| `tokenize`, `tokenize_opt`, `tokenize_constrained`, `tokenize_nbest`, the projections | Concurrent on a shared `^Analyzer`; each caller brings its own arena |
| `add_user_entries` | Mutating: one caller at a time; tokenizes that arrive mid-swap bounce with `.Unavailable`, nothing written |
| `stats`, `entry_info` | Bracketed by the same acquire/release as tokenize — a torn-down analyser answers `.Unavailable` instead of reading freed memory |
| `free` | Sets teardown, waits in-flight calls out, then releases; a nil pointer is a no-op |

## Concurrency and teardown

Every tokenize-family proc opens with the acquire/release bracket:
`acquire` registers the call and bounces it (`.Unavailable`, nothing
written, safe to retry elsewhere) when teardown or a mutation swap has
begun — the ordering dance and its guarantees are documented at
`acquire` in [analyzer.odin](../src/moli/analyzer.odin).

`free` drains rather than races: it marks teardown, then polls the
in-flight count every 100 µs (`DRAIN_POLL`) until the last call leaves.
One boundary sits outside the library's reach, stated at `free` in
[moli.odin](../src/moli/moli.odin): `free` releases the analyser's
*contents*; releasing the *storage* the struct lives in additionally
needs entry-level quiescence on the embedder's side — stop routing new
calls, let threads already entering a call drain at the request level,
then `free`, then release the storage. A wrapper that brackets every
handle call with its own in-flight count (the C/Python SDK's pattern,
[abi.md](abi.md)) provides exactly that quiescence.

## Zero-copy and allocation

```odin
Morpheme :: struct {
    surface, pos, lemma, reading, reading_jyutping: string,
    entry_id: i32, cost: i16, start, end: int,
    locale: Locale, char_class: Char_Class, is_unknown: bool,
}
```

| Field | Points into | Valid until |
|---|---|---|
| `surface`, `start`, `end` | The caller's text — or the arena's NFC copy when `normalize_nfc` was set (the offsets index that copy) | The input's own lifetime |
| `pos`, `lemma`, `reading`, `reading_jyutping` of a dictionary morpheme | Analyzer-owned entry strings | `free` — or an `add_user_entries` merge |
| `pos` of an unknown morpheme | Analyzer-owned rule strings (unk.def / patterns.qpat) | Same |
| `entry_id`, `cost`, `locale`, `char_class`, `is_unknown` | Values | Always |

Two field-level fallback rules live at the Morpheme layer, not in
storage (the emission builder in
[tokenizer.odin](../src/moli/tokenizer.odin)): a lemma of `"*"` or
`""` reads back as the surface; readings pass through verbatim, so a
stored `"*"` stays `"*"` (unknown morphemes carry `"*"` readings).

Allocation: `tokenize` allocates only the morpheme output array, in the
caller's arena, plus (when requested) the NFC copy in the same arena.
There is no hidden per-call allocation, and no allocator inside the
library is touched by a running call.

## Entry ids and dictionary versioning

`entry_id` is the index into the analyser's surface-sorted entry array
(`-1` for unknowns). It is stable while the dictionary state is
unchanged — and `add_user_entries` changes it, because the merge
re-sorts and renumbers. The version detector is the stats fingerprint:

```odin
s0, _ := moli.stats(&a)
moli.add_user_entries(&a, terms)   // any merge
s1, _ := moli.stats(&a)
// s1.entries_hash != s0.entries_hash: every entry_id taken before the
// merge is stale. Re-resolve:
info, ok, _ := moli.entry_info(&a, id)   // ok=false on a stale/out-of-range id
```

`entries_hash` is stamped identically on every construction path (CSV
load, `.qdct` restore, clone), so it fingerprints the dictionary, not
the route that built it.

## Input-validation boundaries

What the library refuses, what it degrades, and where the switch is:

| Input | Behaviour |
|---|---|
| Text not valid UTF-8 | Default: invalid bytes degrade into unknown morphemes. `strict_utf8 = true` rejects the call with `Malformed_Input_Error` at the first invalid byte, before any analysis (a genuine U+FFFD is valid and passes) |
| Decomposed (NFD) text | Default: combining marks surface as spurious unknowns. `normalize_nfc = true` composes first; surfaces then slice the arena copy |
| CSV column count differing from the detected schema | Load aborts with `Schema_Mismatch_Error{line, expected, got}` — extra or missing columns are never silently ignored |
| First CSV line no schema matches | `.Invalid_Format` |
| Malformed CSV quoting (unterminated quote; a byte other than `,`/end after a closing quote) | `.Invalid_Format` |
| Empty CSV surface; unk.def row naming an unknown class or non-numeric ids; matrix.def row out of range | `.Invalid_Format` — "a rule that can never match is a broken dictionary" |
| Entry/unk connection ids outside the loaded matrix | **Not** validated at load; the lookup answers the default connection cost (7000) for out-of-range pairs ([viterbi.odin](../src/moli/viterbi.odin), `matrix_cost`) |
| Absent optional resource (unk.def / char.def / matrix.def / patterns.qpat sibling) | Degrades; recorded in `stats().skipped` |
| Cost fields beyond i16 | Saturated-clamped into range, preserving order |
| A byte-order mark | Stripped once at the start of a file; line endings follow the file as shipped, never re-encoded |
| An invalid constraint set | `Bad_Constraint_Error` before any analysis; a set that over-constrains the lattice faults `Unsatisfiable_Error` carrying the earliest blocked offset — never a silently relaxed result |
| A fired cancel token | `Cancelled_Error` at the byte offset the walk reached; morphemes already appended stay written |

The closed vocabularies behind these behaviours (`Load_Fault`,
`Tokenize_Fault`, `Save_Fault` and their context structs) are defined in
[errors.odin](../src/moli/errors.odin), which also renders the one
canonical message per failure — bindings translate these codes, they
never re-derive the wording.

## Non-goals

The library tracks no consumers of the views it hands out: there is no
GC safety net and no prune protocol — ownership follows the table above,
and freeing relative to in-flight calls is the bracket, not an
assumption that nobody holds a view. Measured behaviour (footprint,
throughput, scaling) lives in [benchmarks.md](benchmarks.md) and is
a window measurement, not a guarantee. The `.qdct` snapshot layout is
specified in the header of [qdct.odin](../src/moli/qdct.odin); this
page does not restate it.
