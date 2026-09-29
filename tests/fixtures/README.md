# Test fixtures — provenance and regeneration

Fixtures are small (< 10 KB each) and committed. The source
dictionaries they are sampled from live under `dict/` (gitignored;
`just dict-fetch` fetches them — README.md's "Dictionaries" section
records the sources and licences).

| Fixture | Source | License | Notes |
|---|---|---|---|
| `unidic_sample.csv` | [UniDic 2.1.2](https://clrd.ninjal.ac.jp/unidic_archive/cwj/2.1.2/) `lex.csv` (756K rows, 21 columns, UTF-8), © The UniDic Consortium | GPL / LGPL / BSD triple license — **committed under the BSD option** | 50 seeded-random rows + a real homograph pair (first duplicated surface in file order) |
| `jieba_sample.csv` | [mecab-jieba 0.1.1](https://github.com/lindera/mecab-jieba) `jieba.csv` (584K rows, 9 columns) — the pure jieba dictionary conversion | MIT, © the Lindera project (jieba itself is MIT) | 100 seeded-random rows + a real homograph pair; quoted definition fields with embedded commas occur naturally |
| `jieba_sample_crlf.csv` | derived from `jieba_sample.csv` | — | first 10 rows re-ended with CRLF (the CRLF input case) |
| `ipadic_sample.csv` | none — hand-written original rows | this project (MIT) | IPADic 13-column layout. Nothing is sampled from ipadic itself (its redistribution terms are narrower than the sources above); includes a homograph pair (さくら ×2) and the integration-test vocabulary (犬, が, 歩く, …) |
| `jieba_tw_sample.csv` / `jieba_hk_sample.csv` | none — hand-written original rows | this project (MIT) | 9-column jieba layout for ZH-TW and ZH-HK (台北市 → 台北+市, 香港島 → 香港+島) |
| `jieba_merge_cn.csv` / `jieba_merge_hk.csv` | none — hand-written original rows | this project (MIT) | the two-file jyutping pair: the CN primary has a homograph pair (島 ×2) and a prefix pair (今日 / 今日新聞); the HK donor has a duplicate surface (first row wins), empty and `*` readings, and a donor-only surface (旺角) |
| `en_sample.csv` | none — hand-written original rows | this project (MIT) | 13-column EnglishExt layout; `defence` carries lemma `*` (surface-fallback case), `travels` carries a differing lemma (`travel`) |
| `german_sample.csv` | none — hand-written original rows | this project (MIT) | 13-column layout for the German scaffold (no external data) |
| `resources/sample.csv` + `unk.def` / `char.def` / `matrix.def` / `patterns.qpat` | none — hand-written originals | this project (MIT) | a self-contained sibling set in its own subdirectory, so fixture-root loads still exercise skipped-resource recording. `unk.def` has one rule in the unidic column order and one in the ipadic order; `char.def` exercises every accepted record form (comments, category definitions, dotted and single-codepoint hex ranges); `matrix.def` is a 2×2 id space consistent with the entries' ids; `patterns.qpat` carries two rows (第 prefix, 的 suffix) that do not fire on the sample vocabulary |
| `qdct_ref_snapshot.qdct` | generated: `save_qdct` of an `ipadic_sample.csv` (Japanese) load | this project (MIT) | the committed golden .qdct (5 KiB). Byte-stable across loads, thread counts, and the ABI boundary on every supported (little-endian) target; the Odin ABI pass and the Python suite both byte-compare their snapshot against it. Regenerate only after a deliberate format change: run the shim ABI pass (`odin test sdk/moli-python-sdk/native -collection:moli=src`) and copy its `tmp/sdk_ref_snapshot.qdct` over this file. |

The `resources/` set exists because hand-written minimal siblings must
stay consistent with the entries' connection-id space, which random
sampling would break — they are not samples.

## Regenerating

    just dict-fetch   # one-time, ~165 MB download, ~700 MB extracted
    just fixtures     # seeded sampling — byte-identical output (seed 20260825)

The fixtures are committed, so regeneration appears as a reviewable
diff; changing the seed is a deliberate act, not an accident.

Attribution: UniDic — The UniDic Consortium (BSD notice above); mecab-jieba — the
Lindera project (MIT). The full license texts travel with the fixtures:
`LICENSES/unidic-bsd.txt` and `LICENSES/mecab-jieba.txt` are verbatim
copies of the `BSD` / `LICENSE` files in the upstream archives (the same
texts also land under `dict/` after `just dict-fetch`).
