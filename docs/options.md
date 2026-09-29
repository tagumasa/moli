# Options and input formats

Every option with its default and effect, and the grammar of every
input file — shown on real rows from the committed fixtures under
`tests/fixtures/` (the same rows the test suite runs; no fetched
dictionary needed). The definitions live in
[src/moli/moli.odin](../src/moli/moli.odin),
[src/moli/tokenizer.odin](../src/moli/tokenizer.odin), and
[src/moli/importer.odin](../src/moli/importer.odin); where this page
and the code disagree, the code wins and this page is wrong.

## Load options

`Load_Options` — the zero value is the recommended load (Viterbi mode,
canonical sibling discovery):

| Field | Default | Effect |
|---|---|---|
| `mode` | `.Viterbi` | `.LongestMatch` selects the greedy longest-match path; the unknown-cost options below are ignored there (no search happens) |
| `unk_def_path` | `""` | Empty looks for `unk.def` next to the dictionary CSV |
| `char_def_path` | `""` | Sibling `char.def` |
| `matrix_def_path` | `""` | Sibling `matrix.def` |
| `qpat_path` | `""` | Sibling `patterns.qpat` |
| `flat_char_class` | `false` | Direct-index character classification instead of the binary-search range table (the measured trade-off sits in [benchmarks.md](benchmarks.md)) |
| `lemma_locale` | `.None` | `.US`/`.GB` rewrite English lemmas toward the variant at load; `.CN` rewrites traditional Chinese lemmas to simplified. A `save_qdct` after a normalised load bakes the rewrites in — the option itself is not serialised |
| `jyutping_csv_path` | `""` | The ZH two-file flow: this HK-variant CSV's column-5 jyutping joins onto the loaded entries by surface. Explicit-only — there is no sibling discovery |
| `threads` | `0` | Parallelises the `matrix.def` parse with up to min(N, 64) workers; `<= 1` scans serially. Output-identical at any value |

The two-file jyutping flow against committed fixtures:

```odin
a, err := moli.load(.ChineseHK, "tests/fixtures/jieba_merge_cn.csv", {
    jyutping_csv_path = "tests/fixtures/jieba_merge_hk.csv",
}, context.allocator)
```

## Tokenize options

`Tokenize_Options` — the zero value is the dictionary-faithful
behaviour:

| Field | Default | Effect |
|---|---|---|
| `unk_cost_bias` | `0` | Shifts every unknown candidate's contribution to the search by this many units: positive penalises unknown segmentation, negative favours it. Changes which path wins — never the emitted `Morpheme` costs |
| `unk_cost_per_rune` | `0` | Adds this many units per rune of an unknown candidate's surface, on top of the bias: a long unknown grows expensive, which is what makes an out-of-vocabulary compound split into dictionary parts (the German trial's `Hausmuseum → Haus\|museum`) competitive |
| `normalize_nfc` | `false` | Composes the input to NFC first; surfaces then slice the arena copy, and `start`/`end` index the copy |
| `strict_utf8` | `false` | Rejects invalid UTF-8 with `Malformed_Input_Error` at the first bad byte, before any analysis |
| `cancel_token` | `nil` | Polled once per rune position; a fired token unwinds the call with `Cancelled_Error` at the offset reached |

`Cancel_Token`'s own contract: the zero value is live; `cancel` flips
it one-way and is safe from any thread (including before the call,
which bounces at offset 0); it is caller-owned and must outlive the
call; the library never resets it, so a spent token bounces every later
call that shares it — fresh token per request is the pattern.

## Dictionary CSV

The schema is detected from the **first non-empty line's** field count,
with the language breaking ties; every later line is then validated
against that column count (a mismatch aborts the load with
`Schema_Mismatch_Error` — see [contract.md](contract.md)):

| First line's fields | Language | Schema |
|---|---|---|
| 9 | `.ChineseHK` → `MeCabJiebaHK`; otherwise `MeCabJieba` | jieba layouts |
| 13 | `.EnglishGB`/`.EnglishUS` → `EnglishExt`; otherwise `Ipadic` | 13-column layouts |
| 17–25 | any | `Unidic` |
| anything else | — | `.Invalid_Format` |

Columns 1, 2, 3 are `left_id`, `right_id`, `cost` in every schema. The
remaining columns map per schema (0-based, as written in the importer's
`SCHEMA_COLUMNS` table):

| Schema | POS columns (joined) | Lemma | Reading | Extras |
|---|---|---|---|---|
| `Ipadic` (13) | 4–9 | 10 | 11 | — |
| `Unidic` (17–25) | 4–9 | 11 | 13 | 17 to the row's end |
| `MeCabJieba` / `MeCabJiebaHK` (9) | 4 | the surface | 5, optional on a short row | 8 |
| `EnglishExt` (13) | 4 | 10 | 11, optional | — |

The POS join skips empty and `"*"` columns and joins the rest with
`,` — so ipadic's `助詞,格助詞,一般,*,*,*` reads back as
`助詞,格助詞,一般`. Real rows, one per family:

```
が,0,0,4000,助詞,格助詞,一般,*,*,*,が,ガ,ガ                      ← Ipadic (13)
ぬかそっ,1323,1323,12837,動詞,一般,*,*,五段-サ行,意志推量形,ヌカス,吐かす,…   ← Unidic (21; columns from index 17 land in extras)
```

Quoting follows the field parser's rules: a quote inside an unquoted
field is a literal; a doubled quote inside quotes is one quote; after a
closing quote only `,` or the record's end may follow — anything else
(including a mid-record `\r`) is malformed and rejects with
`.Invalid_Format`.

## unk.def

One rule per line, CSV-comma-separated:

```
KATAKANA,1,1,4000,名詞,一般,*
HIRAGANA,0,0,5000,名詞,一般,*
```

Column 0 names a char.def class (an unrecognised name fails the load);
columns 1–3 are the `left_id, right_id, cost` triple; the remaining
columns feed the joined POS (any count — the ipadic and unidic POS
column orders both occur in the wild and both parse). Rules are
evaluated in declaration order; the first whose class matches the
unknown run wins. Blank lines are skipped, a leading BOM is stripped.

## char.def

Whitespace-separated records; `#` starts a comment to end of line. The
committed fixture exercises every accepted form:

```
DEFAULT 0 1 0
KANJI 0 0 2
KATAKANA 1 1 2
0x3001 SYMBOL  # single-codepoint form, trailing comment
0x2E80..0x2EF0 KANJI
0xFF61..0xFF65 SYMBOL
```

- `NAME INVOKE GROUP LENGTH` — a category row setting that class's
  unknown-word flags: invoke fires unknown candidates even where a
  dictionary word starts, group offers the whole contiguous same-class
  run as one candidate, length offers 1..LENGTH-rune prefixes. The
  mandatory `DEFAULT` row targets the class of characters no range
  covers; unrecognised names map to that class.
- `lo..hi CLASS` — hex, both ends inclusive.
- `lo CLASS` — a single code point.
- `lo hi CLASS` — two hex columns then the class name.
- A single-token line (the count header real files ship) is skipped.

Later ranges override earlier ones on shared code points (real files
declare kanji numerals inside the kanji block). A range must be a valid
span of real code points below `0x110000`.

## matrix.def

The first line declares the dimensions; every following line is one
cell. The committed 2×2 fixture:

```
2 2
0 0 100
0 1 900
1 0 900
1 1 100
```

Dimensions are capped at 32767 per side, and exactly one zero
dimension is a malformed header. Unfilled cells carry the default
connection cost 7000 (the MeCab convention); a repeated cell counts
once for the density statistic; costs saturate into i16 like every
other cost field.

## patterns.qpat

Surface-shape rules for unknowns, checked **before** the unk.def walk,
declaration order, first match wins:

```
prefix,第,0,0,4500,名詞,接頭辞,*
suffix,的,0,0,4500,名詞,接尾辞,*
```

The kind column selects what the key means: `prefix`/`suffix` match the
candidate's surface by literal (non-empty), `charset` requires every
rune to carry the named char.def class. Columns 2–4 are the connection
triple, the rest feed the joined POS. A file with no rows is legal —
zero patterns, the resolution ladder unchanged.

## Faults at each boundary

One closed vocabulary per boundary, defined in
[errors.odin](../src/moli/errors.odin) with a canonical message each
(bindings translate these, they never re-derive wording):

- **Load**: `File_Not_Found`, `Invalid_Format`, `OutOfMemory`,
  `Nil_Handle`, `IO_Read`, plus the context-bearing
  `Schema_Mismatch_Error{line, expected, got}`.
- **Tokenize**: `OutOfMemory` (the caller's arena is exhausted),
  `Unavailable` (teardown or a swap raced the call; nothing was
  written), plus `Malformed_Input_Error`,
  `Cancelled_Error`, `Bad_Constraint_Error`,
  `Unsatisfiable_Error` — each carrying its byte offset or constraint
  index.
- **Save**: `IO_Write`, `OutOfMemory`, `Unavailable`, `Format_Limit`
  (the analyser's shape exceeds what the `.qdct` record forms can
  represent — the save refuses rather than silently narrowing a field).
