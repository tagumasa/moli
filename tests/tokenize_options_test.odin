// Tokenize_Options coverage: unk_cost_bias steers the Viterbi search
// toward (or away from) unknown candidates, unk_cost_per_rune prices an
// unknown by its length so out-of-vocabulary compounds can split, emitted
// Morpheme costs stay the rules' own, and greedy mode ignores both knobs.
package tests

import "base:runtime"
import "core:mem"
import "core:testing"
import "moli:moli"

// bias_analyzer: expensive dictionary words あ/い/う over a Hiragana
// run with invoke on, so the whole-run unknown and the dictionary
// path genuinely compete.
bias_analyzer :: proc(t: ^testing.T, mode: moli.Mode) -> (moli.Analyzer, bool) {
	entries := []Test_Entry{
		{surface = "あ", left_id = 0, right_id = 0, cost = 20000, pos = "名詞"},
		{surface = "い", left_id = 0, right_id = 0, cost = 20000, pos = "名詞"},
		{surface = "う", left_id = 0, right_id = 0, cost = 20000, pos = "名詞"},
	}
	a, ok := build_test_analyzer(t, .Japanese, mode, entries, nil, 0)
	if !ok { return moli.Analyzer{}, false }
	a.char_flags[int(moli.Char_Class.Hiragana)] = moli.Char_Flags{invoke = true, group = true, length = 0}
	return a, true
}

@(test)
unk_cost_bias_flips_path_test :: proc(t: ^testing.T) {
	a, ok := bias_analyzer(t, .Viterbi)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	// Unbiased: one whole-run unknown beats three 20000-cost words.
	ms, err := moli.tokenize(&a, "あいう", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	testing.expectf(t, len(ms) == 1 && ms[0].surface == "あいう" && ms[0].is_unknown,
		"unbiased: whole-run unknown, got %d morphemes", len(ms))

	// Penalized: the dictionary path wins; the unknown's emitted cost
	// is still the rule's own (0 - the fallback POS), not the bias.
	mem.arena_free_all(&arena)
	ms2, err2 := moli.tokenize_opt(&a, "あいう", {unk_cost_bias = 80000}, arena_alloc)
	if err2 != nil {
		testing.expectf(t, false, "tokenize_opt: %v", err2)
		return
	}
	testing.expectf(t, len(ms2) == 3 && ms2[0].surface == "あ" && ms2[2].surface == "う",
		"biased: dictionary path, got %d morphemes", len(ms2))
	testing.expectf(t, ms2[0].cost == 20000, "dictionary morpheme cost is its own")
}

@(test)
unk_cost_bias_greedy_ignores_test :: proc(t: ^testing.T) {
	a, ok := bias_analyzer(t, .LongestMatch)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	plain, err := moli.tokenize(&a, "あいう", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	mem.arena_free_all(&arena)
	biased, err2 := moli.tokenize_opt(&a, "あいう", {unk_cost_bias = 80000}, arena_alloc)
	if err2 != nil {
		testing.expectf(t, false, "tokenize_opt: %v", err2)
		return
	}
	testing.expectf(t, len(plain) == len(biased),
		"greedy ignores the bias: %d vs %d morphemes", len(plain), len(biased))
}

// per_rune_analyzer: one cheap dictionary word at the head of a letter
// run with invoke on, so the whole-word unknown and the split path
// genuinely compete - the flat-cost world where an OOV compound stays
// whole no matter how it splits.
per_rune_analyzer :: proc(t: ^testing.T, mode: moli.Mode) -> (moli.Analyzer, bool) {
	entries := []Test_Entry{
		{surface = "Haus", left_id = 0, right_id = 0, cost = 1000, pos = "NOUN"},
	}
	a, ok := build_test_analyzer(t, .German, mode, entries, nil, 0)
	if !ok { return moli.Analyzer{}, false }
	a.char_flags[int(moli.Char_Class.ASCIILetter)] = moli.Char_Flags{invoke = true, group = true, length = 0}
	return a, true
}

@(test)
unk_cost_per_rune_splits_compound_test :: proc(t: ^testing.T) {
	a, ok := per_rune_analyzer(t, .Viterbi)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	// Unpriced: the single whole-word unknown wins - splitting costs
	// the dictionary word plus one extra boundary.
	ms, err := moli.tokenize(&a, "Hausmuseum", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	testing.expectf(t, len(ms) == 1 && ms[0].surface == "Hausmuseum" && ms[0].is_unknown,
		"unpriced: whole-word unknown, got %d morphemes", len(ms))

	// Priced per rune: the long unknown loses to Haus + a shorter
	// unknown (4 rune gap must beat word cost 1000 + boundary 7000,
	// so 3000/rune clears it). Emitted costs stay the rules' own.
	mem.arena_free_all(&arena)
	opts: moli.Tokenize_Options = {unk_cost_per_rune = 3000}
	ms2, err2 := moli.tokenize_opt(&a, "Hausmuseum", opts, arena_alloc)
	if err2 != nil {
		testing.expectf(t, false, "tokenize_opt: %v", err2)
		return
	}
	testing.expectf(t, len(ms2) == 2 && ms2[0].surface == "Haus" && !ms2[0].is_unknown,
		"priced: split path, got %d morphemes", len(ms2))
	testing.expectf(t, ms2[0].cost == 1000, "dictionary morpheme cost is its own")
	testing.expectf(t, len(ms2) == 2 && ms2[1].surface == "museum" && ms2[1].is_unknown && ms2[1].cost == 0,
		"unknown morpheme cost is the rule's own (0)")

	// N-best agreement: the same options must rank the split first.
	mem.arena_free_all(&arena)
	paths, nerr := make([dynamic]moli.NBest_Path, 0, 2, arena_alloc)
	if nerr != nil { return }
	if err3 := moli.tokenize_nbest(&a, "Hausmuseum", 2, opts, moli.Constraints{}, &paths, arena_alloc); err3 != nil {
		testing.expectf(t, false, "tokenize_nbest: %v", err3)
		return
	}
	testing.expectf(t, len(paths) > 0 && len(paths[0].morphemes) == 2 &&
		paths[0].morphemes[0].surface == "Haus" && paths[0].morphemes[1].surface == "museum",
		"n-best ranks the priced split first, got %d paths", len(paths))
}

@(test)
unk_cost_per_rune_greedy_ignores_test :: proc(t: ^testing.T) {
	a, ok := per_rune_analyzer(t, .LongestMatch)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	plain, err := moli.tokenize(&a, "Hausmuseum", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	mem.arena_free_all(&arena)
	priced, err2 := moli.tokenize_opt(&a, "Hausmuseum", {unk_cost_per_rune = 3000}, arena_alloc)
	if err2 != nil {
		testing.expectf(t, false, "tokenize_opt: %v", err2)
		return
	}
	testing.expectf(t, len(plain) == 2 && len(priced) == 2,
		"greedy ignores the per-rune price: %d vs %d morphemes", len(plain), len(priced))
}

// The streaming-buffer variant composes decomposed input the same way
// tokenize_opt does - the NFC wrapper leg of tokenize_into_opt.
@(test)
tokenize_into_nfc_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "が", left_id = 0, right_id = 0, cost = 0, pos = "助詞"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	out := make([dynamic]moli.Morpheme, 0, 8, arena_alloc)
	if err := moli.tokenize_into_opt(&a, "か\u3099", {normalize_nfc = true}, &out, arena_alloc); err != nil {
		testing.expectf(t, false, "tokenize_into_opt: %v", err)
		return
	}
	testing.expectf(t, len(out) == 1 && out[0].surface == "が" && !out[0].is_unknown,
		"into_opt composes NFD input and matches, got %d morphemes", len(out))
}
