// ABI tests: every export is called through the C surface it
// publishes, with the zero-leak discipline of the main suite (every
// handle/result/snapshot the test creates is explicitly freed).
package native

import "core:os"
import "core:strings"
import "core:testing"

IPADIC :: "tests/fixtures/ipadic_sample.csv"
EN_FIXTURE :: "tests/fixtures/en_sample.csv"
REF_SNAPSHOT :: "tmp/sdk_ref_snapshot.qdct"
GOLDEN :: "tests/fixtures/qdct_ref_snapshot.qdct"

@(test)
abi_check_layout_test :: proc(t: ^testing.T) {
	testing.expectf(t, moli_abi_version() == 7, "abi version")
	testing.expectf(t, string(moli_version()) == LIBRARY_VERSION, "version string")

	vals: [ABI_CHECK_LEN]i64
	n := moli_abi_check(&vals[0], ABI_CHECK_LEN)
	testing.expectf(t, n == ABI_CHECK_LEN, "abi_check wrote %d values", n)

	// The layout contract: a 72-byte Morpheme_FFI under natural
	// alignment, and the enum member counts every binding mirrors.
	testing.expectf(t, vals[0] == 7, "abi version value")
	testing.expectf(t, vals[1] == 72, "Morpheme_FFI size %d", vals[1])
	testing.expectf(t, vals[2] == 0 && vals[3] == 8, "start/end offsets")
	testing.expectf(t, vals[12] == 48 && vals[13] == 52, "jyutping offsets")
	testing.expectf(t, vals[14] == 56 && vals[15] == 60 && vals[16] == 62 && vals[17] == 63 && vals[18] == 64, "entry_id/cost/locale/class/is_unknown offsets")
	testing.expectf(t, vals[19] == 232, "Err_FFI size slot (two u32, three i64, message[192], d i64)")
	testing.expectf(t, vals[25] == 32 && vals[26] == 224, "message/d offsets")
	// The v3 additions: the Stats block covers every field, ending in
	// entries_hash (u64 after nine i64 and the f64) and the borrowed
	// skipped array.
	testing.expectf(t, vals[56] == 160, "Stats_FFI size slot (nine i64, f64, u64, eight ptr, i64)")
	testing.expectf(t, vals[67] == 80 && vals[68] == 88, "entries_hash/skipped offsets")
	// The v4 additions: the two constraint wire structs under natural
	// alignment (i64 pairs plus the pointer; the u8 rides at offset 8
	// with tail padding), then the enum counts the v3 slots carried.
	testing.expectf(t, vals[70] == 24 && vals[71] == 0 && vals[72] == 8 && vals[73] == 16, "Token_Constraint_FFI layout")
	testing.expectf(t, vals[74] == 16 && vals[75] == 0 && vals[76] == 8, "Boundary_Constraint_FFI layout")
	testing.expectf(t, vals[77] == 7 && vals[78] == 6 && vals[79] == 2 && vals[80] == 13, "enum counts")
	testing.expectf(t, vals[81] == 3 && vals[82] == 5 && vals[83] == 6 && vals[84] == 4, "error vocabulary counts")
	// The v7 addition: every enum's per-member ordinals, declaration
	// order — first/last members per enum plus the tail of the block
	// (the Save vocabulary including Format_Limit, then the constraint
	// reasons). Slots 85..139.
	testing.expectf(t, vals[85] == 0 && vals[91] == 6, "Language ordinals (Japanese..German)")
	testing.expectf(t, vals[92] == 0 && vals[97] == 5, "Locale ordinals (None..US)")
	testing.expectf(t, vals[98] == 0 && vals[99] == 1, "Mode ordinals")
	testing.expectf(t, vals[100] == 0 && vals[112] == 12, "Char_Class ordinals (Unknown..Emoji)")
	testing.expectf(t, vals[113] == 0 && vals[115] == 2, "Domain ordinals")
	testing.expectf(t, vals[116] == 0 && vals[120] == 4, "Load_Code ordinals")
	testing.expectf(t, vals[121] == 0 && vals[126] == 5, "Tokenize_Code ordinals")
	testing.expectf(t, vals[127] == 0 && vals[130] == 3, "Save_Code ordinals (Format_Limit last)")
	testing.expectf(t, vals[131] == 0 && vals[139] == 8, "Constraint_Reason ordinals")

	// A caller declining the detail passes NULL; a short buffer is
	// filled up to capacity only.
	testing.expectf(t, moli_abi_check(nil, 0) == 0, "null out with cap 0")
	short: [3]i64
	wrote := moli_abi_check(&short[0], 3)
	testing.expectf(t, wrote == 3 && short[0] == 7 && short[2] == 0, "short fill")
}

@(test)
load_and_tokenize_test :: proc(t: ^testing.T) {
	err: Err_FFI
	h := moli_load(0, cstring(IPADIC), nil, &err)
	if h == nil {
		// The fixture is committed and the recipe pins the working
		// directory, so a nil load here is a broken build or a real
		// regression - fail loudly, never pass vacuously.
		testing.expectf(t, false, "load %s failed: domain=%d code=%d", IPADIC, err.domain, err.code)
		return
	}
	defer moli_free(h)

	text := bytes("犬が歩く")
	r := moli_tokenize(h, &text[0], i64(len(text)), nil, &err)
	if r == nil {
		testing.expectf(t, false, "tokenize failed: domain=%d code=%d", err.domain, err.code)
		return
	}
	defer moli_result_free(r)

	n := moli_result_count(r)
	testing.expectf(t, n == 3, "3 morphemes, got %d", n)
	if n < 3 { return }
	ms := morph_slice(r)
	blob := blob_slice(r)

	testing.expectf(t, field(blob, ms[0], .Surface) == "犬", "surface 0")
	testing.expectf(t, field(blob, ms[0], .Pos) == "名詞,一般", "pos 0")
	testing.expectf(t, field(blob, ms[1], .Surface) == "が", "surface 1")
	testing.expectf(t, field(blob, ms[2], .Surface) == "歩く", "surface 2")
	testing.expectf(t, ms[0].start == 0 && ms[0].end == 3, "byte offsets 0")
	testing.expectf(t, ms[0].is_unknown == 0, "known entry")

	// Wakachi: surface-only morphemes, same count.
	w := moli_wakachi(h, &text[0], i64(len(text)), nil, &err)
	if w == nil {
		testing.expectf(t, false, "wakachi failed")
		return
	}
	defer moli_result_free(w)
	wms := morph_slice(w)
	testing.expectf(t, moli_result_count(w) == 3 && field(blob_slice(w), wms[0], .Surface) == "犬", "wakachi surfaces")

	// Spans: surfaces with byte offsets.
	sp := moli_spans(h, &text[0], i64(len(text)), nil, &err)
	if sp == nil {
		testing.expectf(t, false, "spans failed")
		return
	}
	defer moli_result_free(sp)
	sms := morph_slice(sp)
	testing.expectf(t, moli_result_count(sp) == 3, "span count")
	testing.expectf(t, sms[2].start == 6 && sms[2].end == 12, "span offsets: %d..%d", sms[2].start, sms[2].end)

	// N-best: three paths indexing the shared morpheme array (this
	// fixture answers 犬が歩く itself with a single path; the longer
	// sentence has the alternatives).
	nb_text := bytes("犬が歩いている")
	nb := moli_nbest(h, &nb_text[0], i64(len(nb_text)), 3, nil, &err)
	if nb == nil {
		testing.expectf(t, false, "nbest failed")
		return
	}
	defer moli_result_free(nb)
	testing.expectf(t, moli_result_count(nb) > 0, "nbest morphemes")
	testing.expectf(t, len(morph_slice(nb)) >= 3, "nbest morpheme total")
	testing.expectf(t, len(nb.paths) == 3, "3 nbest paths, got %d", len(nb.paths))
	first := nb.paths[0]
	testing.expectf(t, first.count > 0 && first.first >= 0 && int(first.first) + int(first.count) <= len(morph_slice(nb)), "path range in bounds")
}

@(test)
load_errors_test :: proc(t: ^testing.T) {
	err: Err_FFI

	h := moli_load(0, cstring("tests/fixtures/no-such-file.csv"), nil, &err)
	testing.expectf(t, h == nil, "missing file returns NULL")
	expect_err(t, err, u32(Domain.Load), u32(Load_Code.File_Not_Found), "file not found")

	h2 := moli_load(99, cstring(IPADIC), nil, &err)
	testing.expectf(t, h2 == nil, "bad language ordinal rejected")
	expect_err(t, err, u32(Domain.Load), u32(Load_Code.Invalid_Format), "invalid ordinal")

	garbage := bytes("not a snapshot")
	h3 := moli_load_qdct_bytes(&garbage[0], i64(len(garbage)), &err)
	testing.expectf(t, h3 == nil, "garbage qdct rejected")
	expect_err(t, err, u32(Domain.Load), u32(Load_Code.Invalid_Format), "invalid format")

	// A NULL err pointer (caller declining the detail) must not crash.
	h4 := moli_load(0, cstring("tests/fixtures/no-such-file.csv"), nil, nil)
	testing.expectf(t, h4 == nil, "null err tolerated")
}

@(test)
cancel_and_strict_test :: proc(t: ^testing.T) {
	err: Err_FFI
	h := moli_load(0, cstring(IPADIC), nil, &err)
	if h == nil {
		testing.expectf(t, false, "load %s failed: domain=%d code=%d", IPADIC, err.domain, err.code)
		return
	}
	defer moli_free(h)

	tok := moli_cancel_new()
	testing.expectf(t, tok != nil, "cancel token")
	defer moli_cancel_free(tok)
	moli_cancel(tok)

	text := bytes("犬が歩く")
	opts: Tokenize_Options_FFI
	opts.cancel = tok
	r := moli_tokenize(h, &text[0], i64(len(text)), &opts, &err)
	testing.expectf(t, r == nil, "pre-spent token bounces the call")
	expect_err(t, err, u32(Domain.Tokenize), u32(Tokenize_Code.Cancelled), "cancelled")
	testing.expectf(t, err.a == 0, "cancelled at byte offset 0, got %d", err.a)

	bad := bytes("犬\xffが")
	strict: Tokenize_Options_FFI
	strict.strict_utf8 = 1
	r2 := moli_tokenize(h, &bad[0], i64(len(bad)), &strict, &err)
	testing.expectf(t, r2 == nil, "malformed input rejected")
	expect_err(t, err, u32(Domain.Tokenize), u32(Tokenize_Code.Malformed_Input), "malformed")
	testing.expectf(t, err.a == 3, "first invalid byte at 3, got %d", err.a)
}

@(test)
snapshot_roundtrip_test :: proc(t: ^testing.T) {
	err: Err_FFI
	h := moli_load(0, cstring(IPADIC), nil, &err)
	if h == nil {
		testing.expectf(t, false, "load %s failed: domain=%d code=%d", IPADIC, err.domain, err.code)
		return
	}
	defer moli_free(h)

	text := bytes("犬が歩く")
	r := moli_tokenize(h, &text[0], i64(len(text)), nil, &err)
	if r == nil {
		testing.expectf(t, false, "tokenize failed: domain=%d code=%d", err.domain, err.code)
		return
	}
	// The comparison strings borrow this result's blob, so it stays
	// alive until the test ends.
	defer moli_result_free(r)
	want_n := moli_result_count(r)
	want_first := field(blob_slice(r), morph_slice(r)[0], .Surface)
	want_last := field(blob_slice(r), morph_slice(r)[int(want_n) - 1], .Surface)

	// In-memory snapshot -> load_qdct_bytes (the documented one-copy
	// path; the caller's buffer stays usable afterwards).
	out_len: i64
	snap := moli_snapshot(h, &out_len, &err)
	testing.expectf(t, snap != nil && out_len > 0, "snapshot bytes")
	if snap == nil { return }
	snap_copy := make([]u8, int(out_len))
	snap_mp := cast([^]u8)(snap)
	copy(snap_copy, snap_mp[:int(out_len)])
	defer delete(snap_copy)
	moli_snapshot_free(snap)

	h2 := moli_load_qdct_bytes(&snap_copy[0], i64(len(snap_copy)), &err)
	testing.expectf(t, h2 != nil, "qdct bytes reload (domain=%d code=%d a=%d)", err.domain, err.code, err.a)
	if h2 == nil { return }
	defer moli_free(h2)
	testing.expectf(t, snap_copy[0] == 'Q', "caller buffer intact after the copy (buffer reuse rule)")

	r2 := moli_tokenize(h2, &text[0], i64(len(text)), nil, &err)
	if r2 == nil {
		testing.expectf(t, false, "reloaded tokenize failed")
		return
	}
	ms2 := morph_slice(r2)
	testing.expectf(t,
		moli_result_count(r2) == want_n &&
		field(blob_slice(r2), ms2[0], .Surface) == want_first &&
		field(blob_slice(r2), ms2[int(want_n) - 1], .Surface) == want_last,
		"identical segmentation after reload")
	moli_result_free(r2)

	// File save -> mmap load. The committed golden is the reference
	// both suites pin to: save_qdct's file must be byte-identical to
	// it (the pytest suite pins Python-side snapshot() to the same
	// bytes), so nothing couples the two suites' run order.
	testing.expectf(t, moli_save_qdct(h, cstring(REF_SNAPSHOT), &err) == 0, "save_qdct")
	saved, rerr := os.read_entire_file(REF_SNAPSHOT, context.allocator)
	if rerr != nil {
		testing.expectf(t, false, "read back %s: %v", REF_SNAPSHOT, rerr)
		return
	}
	defer delete(saved, context.allocator)
	golden, gerr := os.read_entire_file(GOLDEN, context.allocator)
	if gerr != nil {
		testing.expectf(t, false, "read %s: %v", GOLDEN, gerr)
		return
	}
	defer delete(golden, context.allocator)
	same := len(saved) == len(golden)
	if same {
		for i in 0 ..< len(saved) {
			if saved[i] != golden[i] { same = false; break }
		}
	}
	testing.expectf(t, same, "saved snapshot must equal the committed golden (%d vs %d bytes)", len(saved), len(golden))
	h3 := moli_load_qdct_mmap(cstring(REF_SNAPSHOT), &err)
	testing.expectf(t, h3 != nil, "mmap reload")
	if h3 != nil {
		r3 := moli_tokenize(h3, &text[0], i64(len(text)), nil, &err)
		testing.expectf(t, r3 != nil && moli_result_count(r3) == want_n, "mmap reloaded analyzer tokenizes")
		if r3 != nil { moli_result_free(r3) }
		moli_free(h3)
	}

	// clone: an independent analyzer that outlives the original.
	h4 := moli_clone(h, &err)
	testing.expectf(t, h4 != nil, "clone")
	if h4 != nil {
		r4 := moli_tokenize(h4, &text[0], i64(len(text)), nil, &err)
		testing.expectf(t, r4 != nil && moli_result_count(r4) == want_n, "clone tokenizes")
		if r4 != nil { moli_result_free(r4) }
		moli_free(h4)
	}
}

@(test)
user_entries_stats_classify_test :: proc(t: ^testing.T) {
	err: Err_FFI
	h := moli_load(0, cstring(IPADIC), nil, &err)
	if h == nil {
		testing.expectf(t, false, "load %s failed: domain=%d code=%d", IPADIC, err.domain, err.code)
		return
	}
	defer moli_free(h)

	entry := User_Entry_FFI{
		surface = cstring("犬助"),
		pos     = cstring("名詞,固有名詞"),
		lemma   = cstring("*"),
		reading = cstring("ケンスケ"),
		cost    = -3000,
	}
	testing.expectf(t, moli_add_user_entries(h, &entry, 1, &err) == 0, "add_user_entries")

	text := bytes("犬助")
	r := moli_tokenize(h, &text[0], i64(len(text)), nil, &err)
	if r == nil {
		testing.expectf(t, false, "tokenize with user entry failed")
		return
	}
	defer moli_result_free(r)
	ms := morph_slice(r)
	testing.expectf(t, moli_result_count(r) == 1 && field(blob_slice(r), ms[0], .Surface) == "犬助", "user entry wins")
	testing.expectf(t, field(blob_slice(r), ms[0], .Reading) == "ケンスケ", "user reading")

	stats: Stats_FFI
	testing.expectf(t, moli_stats(h, &stats, &err) == 0, "stats")
	testing.expectf(t, stats.entries > 0 && stats.terminals > 0 && stats.cedar_nodes > 0, "stats counts")
	testing.expectf(t, stats.unk_rules == 0 && stats.skipped_count > 0, "absent siblings skipped (unk rules %d, skipped %d)", stats.unk_rules, stats.skipped_count)
	if stats.skipped_count > 0 {
		testing.expectf(t, stats.skipped[0] != nil, "skipped names readable")
	}

	// A load with full siblings present answers the unk inventory.
	res := moli_load(0, cstring("tests/fixtures/resources/sample.csv"), nil, &err)
	if res == nil {
		testing.expectf(t, false, "resources load failed: domain=%d code=%d", err.domain, err.code)
		return
	}
	defer moli_free(res)
	rstats: Stats_FFI
	testing.expectf(t, moli_stats(res, &rstats, &err) == 0, "resources stats")
	testing.expectf(t, rstats.unk_rules > 0 && rstats.skipped_count == 0, "unk present, nothing skipped")

	en := moli_load(4, cstring(EN_FIXTURE), nil, &err)
	if en == nil {
		testing.expectf(t, false, "EN load failed: domain=%d code=%d", err.domain, err.code)
		return
	}
	defer moli_free(en)
	en_text := bytes("the colour of defence")
	locale := moli_classify_locale(en, &en_text[0], i64(len(en_text)))
	testing.expectf(t, locale == 4, "GB classified as ordinal 4, got %d", locale)
}

@(test)
nil_and_zero_safety_test :: proc(t: ^testing.T) {
	// The single-call contract's cheap guards: NULL/zero inputs
	// return failure values, never crash.
	moli_free(nil)
	moli_result_free(nil)
	moli_snapshot_free(nil)
	moli_cancel(nil)
	moli_cancel_free(nil)
	testing.expectf(t, moli_result_count(nil) == 0, "nil result count")
	testing.expectf(t, moli_result_morphemes(nil) == nil, "nil morphemes")
	testing.expectf(t, moli_result_blob_len(nil) == 0, "nil blob len")
	testing.expectf(t, moli_classify_locale(nil, nil, 0) == 0, "nil classify")

	err: Err_FFI
	r := moli_tokenize(nil, nil, 0, nil, &err)
	testing.expectf(t, r == nil, "nil handle result")
	expect_err(t, err, u32(Domain.Tokenize), u32(Tokenize_Code.Unavailable), "nil handle")
}

@(test)
retained_tight_tier_test :: proc(t: ^testing.T) {
	// An input in the band the full-margin block (len*1024) would push
	// past TOKENIZE_RETAIN_MAX rides the tight tier: the thread's
	// retained scratch, grown once, then reused. Sentence repetition
	// makes the morpheme count linear, so both big passes check
	// exactly against the single-sentence run.
	err: Err_FFI
	h := moli_load(0, cstring(IPADIC), nil, &err)
	if h == nil {
		// The fixture is committed and the recipe pins the working
		// directory, so a nil load here is a broken build or a real
		// regression - fail loudly, never pass vacuously.
		testing.expectf(t, false, "load %s failed: domain=%d code=%d", IPADIC, err.domain, err.code)
		return
	}
	defer moli_free(h)

	sent := bytes("犬が歩く")
	r1 := moli_tokenize(h, &sent[0], i64(len(sent)), nil, &err)
	if r1 == nil {
		testing.expectf(t, false, "single-sentence tokenize failed: domain=%d code=%d", err.domain, err.code)
		return
	}
	per := moli_result_count(r1)
	ms := morph_slice(r1)
	blob := blob_slice(r1)
	first := strings.clone(field(blob, ms[0], .Surface))
	last := strings.clone(field(blob, ms[per - 1], .Surface))
	defer delete(first)
	defer delete(last)
	moli_result_free(r1)

	// The tight-tier band, derived from the tier constants instead of
	// restated: above the full-margin gate (TOKENIZE_STACK_BYTES) and
	// under the tight tier's coverage bound
	// (TOKENIZE_RETAIN_MAX / TOKENIZE_TIGHT_PER_INPUT), so the run
	// rides the tight tier first and the full-margin retry second.
	tight_band_mid := (TOKENIZE_STACK_BYTES + TOKENIZE_RETAIN_MAX / TOKENIZE_TIGHT_PER_INPUT) / 2
	n_rep := tight_band_mid / len(sent) + 1
	text := strings.repeat("犬が歩く", n_rep)
	defer delete(text)
	buf := transmute([]u8)text
	testing.expectf(t, len(buf) > TOKENIZE_STACK_BYTES &&
		len(buf) * TOKENIZE_TIGHT_PER_INPUT + TOKENIZE_STACK_BYTES <= TOKENIZE_RETAIN_MAX,
		"fixture %d bytes must land in the tight-tier band (>%d, tight-fit <=%d)",
		len(buf), TOKENIZE_STACK_BYTES, TOKENIZE_RETAIN_MAX)
	if !(len(buf) > TOKENIZE_STACK_BYTES &&
		len(buf) * TOKENIZE_TIGHT_PER_INPUT + TOKENIZE_STACK_BYTES <= TOKENIZE_RETAIN_MAX) {
		return
	}

	want := per * i64(n_rep)
	for pass := 0; pass < 2; pass += 1 {
		r := moli_tokenize(h, &buf[0], i64(len(buf)), nil, &err)
		if r == nil {
			testing.expectf(t, false, "tight-tier tokenize pass %d failed: domain=%d code=%d", pass, err.domain, err.code)
			return
		}
		n := moli_result_count(r)
		big_ms := morph_slice(r)
		big_blob := blob_slice(r)
		testing.expectf(t, n == want, "pass %d: %d morphemes, want %d", pass, n, want)
		if n == want {
			testing.expectf(t, field(big_blob, big_ms[0], .Surface) == first, "pass %d first surface", pass)
			testing.expectf(t, field(big_blob, big_ms[n - 1], .Surface) == last, "pass %d last surface", pass)
		}
		moli_result_free(r)
	}
}

@(test)
constrained_export_test :: proc(t: ^testing.T) {
	err: Err_FFI
	h := moli_load(0, cstring(IPADIC), nil, &err)
	if h == nil {
		// The fixture is committed and the recipe pins the working
		// directory, so a nil load here is a broken build or a real
		// regression - fail loudly, never pass vacuously.
		testing.expectf(t, false, "load %s failed: domain=%d code=%d", IPADIC, err.domain, err.code)
		return
	}
	defer moli_free(h)

	// The fixture's さくら homographs (名詞,一般 at 5500, 名詞,固有名詞,一般
	// at 6000): pinning [0,9) under 名詞,固有名詞 flips the winner while
	// the rest of the sentence tokenizes unchanged.
	text := bytes("さくらが咲く")

	plain := moli_tokenize(h, &text[0], i64(len(text)), nil, &err)
	if plain == nil {
		testing.expectf(t, false, "plain tokenize failed")
		return
	}
	pms := morph_slice(plain)
	pblob := blob_slice(plain)
	if moli_result_count(plain) < 2 || field(pblob, pms[0], .Pos) != "名詞,一般" {
		testing.expectf(t, false, "fixture premise: plain picks 名詞,一般")
		moli_result_free(plain)
		return
	}

	toks := []Token_Constraint_FFI{{start = 0, end = 9, pos = cstring("名詞,固有名詞")}}
	r := moli_tokenize_constrained(h, &text[0], i64(len(text)), &toks[0], 1, nil, 0, nil, &err)
	if r == nil {
		testing.expectf(t, false, "constrained failed: domain=%d code=%d", err.domain, err.code)
		moli_result_free(plain)
		return
	}
	ms := morph_slice(r)
	blob := blob_slice(r)
	testing.expectf(t, moli_result_count(r) == moli_result_count(plain), "same count as plain")
	testing.expectf(t, field(blob, ms[0], .Surface) == "さくら", "pinned surface")
	testing.expectf(t, field(blob, ms[0], .Pos) == "名詞,固有名詞,一般", "pinned pos: %s", field(blob, ms[0], .Pos))
	testing.expectf(t, ms[0].start == 0 && ms[0].end == 9, "pinned offsets")
	moli_result_free(r)
	moli_result_free(plain)

	// A boundary constraint that contradicts the dictionary merge
	// (東京 is one entry; forcing a split at byte 3 leaves nothing that
	// ends there) surfaces the unsatisfiable fault through the wire.
	tokyo := bytes("東京")
	bnds := []Boundary_Constraint_FFI{{at = 3, must_exist = 1}}
	err2: Err_FFI
	r2 := moli_tokenize_constrained(h, &tokyo[0], i64(len(tokyo)), nil, 0, &bnds[0], 1, nil, &err2)
	if r2 != nil {
		testing.expectf(t, false, "contradictory boundary must fault")
		moli_result_free(r2)
		return
	}
	expect_err(t, err2, u32(Domain.Tokenize), u32(Tokenize_Code.Constraint_Unsatisfiable), "unsatisfiable")
	testing.expectf(t, err2.a == 3, "blocked offset %d, want 3", err2.a)

	// A rejected set carries its index and span through the payload.
	bad := []Token_Constraint_FFI{{start = 1, end = 9, pos = nil}}
	err3: Err_FFI
	r3 := moli_tokenize_constrained(h, &text[0], i64(len(text)), &bad[0], 1, nil, 0, nil, &err3)
	if r3 != nil {
		testing.expectf(t, false, "mid-rune span must fault")
		moli_result_free(r3)
		return
	}
	expect_err(t, err3, u32(Domain.Tokenize), u32(Tokenize_Code.Bad_Constraint), "bad constraint")
	testing.expectf(t, err3.a == 0 && err3.b == 1 && err3.c == 9, "payload index/start/end")
	// d is the rejection's reason ordinal (start=1 is mid-rune in the
	// 3-byte さ: Not_Rune_Boundary, declaration position 2).
	testing.expectf(t, err3.d == 2, "payload reason (Not_Rune_Boundary), got %d", err3.d)

	// The export's head guard: a negative count (or a dangling
	// non-empty array) is a call-shape fault the shim itself rejects
	// before touching the handle.
	err4: Err_FFI
	r4 := moli_tokenize_constrained(h, &text[0], i64(len(text)), nil, -1, nil, 0, nil, &err4)
	testing.expectf(t, r4 == nil, "negative count rejected")
	expect_err(t, err4, u32(Domain.Tokenize), u32(Tokenize_Code.Bad_Constraint), "negative count")
}

// --- helpers -------------------------------------------------------

bytes :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

Field_Kind :: enum {
	Surface,
	Pos,
	Reading,
}

field :: proc(blob: []u8, m: Morpheme_FFI, kind: Field_Kind) -> string {
	off, n := m.surf_off, m.surf_len
	switch kind {
	case .Surface:
	case .Pos:     off, n = m.pos_off, m.pos_len
	case .Reading: off, n = m.reading_off, m.reading_len
	}
	return string(blob[off:off + n])
}

morph_slice :: proc(r: ^Result_Box) -> []Morpheme_FFI {
	n := int(moli_result_count(r))
	mp := cast([^]Morpheme_FFI)(moli_result_morphemes(r))
	return mp[:n]
}

blob_slice :: proc(r: ^Result_Box) -> []u8 {
	n := int(moli_result_blob_len(r))
	mp := cast([^]u8)(moli_result_blob(r))
	return mp[:n]
}

expect_err :: proc(t: ^testing.T, err: Err_FFI, want_domain: u32, want_code: u32, what: string) {
	testing.expectf(t, err.domain == want_domain && err.code == want_code, "%s: domain=%d code=%d (want %d/%d)", what, err.domain, err.code, want_domain, want_code)
	// The message is NUL-terminated within its 192-byte buffer.
	n := 0
	for b in err.message {
		if b == 0 { break }
		n += 1
	}
	testing.expectf(t, n < len(err.message), "%s: message terminated", what)
}
