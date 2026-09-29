// Constrained-analysis coverage: the empty set reproduces the plain
// Viterbi result exactly (the no-regression tripwire), token spans
// pin a surface and flip POS among homographs (or fault when the mask
// empties a region), boundary constraints force and forbid splits,
// validation rejects malformed sets with the documented reason and
// index, normalize_nfc composition faults on rescale, and the n-best
// search honors the same mask.
package tests

import "core:mem"
import "core:testing"
import "moli:moli"

constraint_arena :: proc(arena: ^mem.Arena, buf: ^[1 << 16]byte) -> mem.Allocator {
	mem.arena_init(arena, buf[:])
	return mem.arena_allocator(arena)
}

// morph_seq_eq compares two morpheme sequences field by field - the
// identity the empty constraint set must hold.
morph_seq_eq :: proc(x: []moli.Morpheme, y: []moli.Morpheme) -> bool {
	if len(x) != len(y) { return false }
	for i in 0 ..< len(x) {
		a, b := x[i], y[i]
		if a.surface != b.surface || a.pos != b.pos || a.lemma != b.lemma { return false }
		if a.reading != b.reading || a.reading_jyutping != b.reading_jyutping { return false }
		if a.entry_id != b.entry_id || a.cost != b.cost || a.start != b.start || a.end != b.end { return false }
		if a.is_unknown != b.is_unknown || a.char_class != b.char_class || a.locale != b.locale { return false }
	}
	return true
}

// expect_bad_constraint asserts the error is a Bad_Constraint_Error
// with the given reason and index, reporting and answering false
// otherwise. A nil err is a vacuous success and fails here - the
// callers assert a fault must have arrived.
expect_bad_constraint :: proc(t: ^testing.T, err: moli.Tokenize_Err, reason: moli.Constraint_Reason, index: int) -> bool {
	if err == nil {
		testing.expectf(t, false, "want bad constraint {} index {}, got success", reason, index)
		return false
	}
	switch v in err {
	case moli.Bad_Constraint_Error:
		if v.reason != reason || v.index != index {
			testing.expectf(t, false, "got bad constraint {} index {}, want {} index {}", v.reason, v.index, reason, index)
			return false
		}
		return true
	case moli.Tokenize_Fault, moli.Malformed_Input_Error, moli.Cancelled_Error, moli.Unsatisfiable_Error:
		testing.expectf(t, false, "want Bad_Constraint_Error, got %v", err)
	}
	return false
}

// expect_unsatisfiable asserts the error is an Unsatisfiable_Error at
// the given byte offset. A nil err is a vacuous success and fails
// here.
expect_unsatisfiable :: proc(t: ^testing.T, err: moli.Tokenize_Err, byte_offset: int) -> bool {
	if err == nil {
		testing.expectf(t, false, "want unsatisfiable at %d, got success", byte_offset)
		return false
	}
	switch v in err {
	case moli.Unsatisfiable_Error:
		if v.byte_offset != byte_offset {
			testing.expectf(t, false, "got unsatisfiable at %d, want %d", v.byte_offset, byte_offset)
			return false
		}
		return true
	case moli.Tokenize_Fault, moli.Malformed_Input_Error, moli.Cancelled_Error, moli.Bad_Constraint_Error:
		testing.expectf(t, false, "want Unsatisfiable_Error, got %v", err)
	}
	return false
}

@(test)
constraint_identity_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "さくら", left_id = 0, right_id = 0, cost = 5500, pos = "名詞,一般"},
		{surface = "さくら", left_id = 0, right_id = 0, cost = 6000, pos = "名詞,固有名詞,一般"},
		{surface = "が", left_id = 0, right_id = 0, cost = 4000, pos = "助詞,格助詞,一般"},
		{surface = "歩く", left_id = 0, right_id = 0, cost = 6000, pos = "動詞,自立"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	alloc := constraint_arena(&arena, &arena_buf)

	// Mixed known and unknown spans (どず is an unknown run, so the
	// identity covers the unknown emission too).
	text := "さくらがどず"
	plain, perr := moli.tokenize(&a, text, alloc)
	if perr != nil {
		testing.expectf(t, false, "tokenize: %v", perr)
		return
	}
	if len(plain) == 0 || !plain[len(plain) - 1].is_unknown {
		testing.expectf(t, false, "fixture must end in an unknown run, got %d morphemes", len(plain))
		return
	}
	cons, cerr := moli.tokenize_constrained(&a, text, moli.Constraints{}, {}, alloc)
	if cerr != nil {
		testing.expectf(t, false, "tokenize_constrained (empty set): %v", cerr)
		return
	}
	testing.expectf(t, morph_seq_eq(plain, cons), "the empty constraint set changed the result")
}

@(test)
constraint_token_pos_flip_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "さくら", left_id = 0, right_id = 0, cost = 5500, pos = "名詞,一般"},
		{surface = "さくら", left_id = 0, right_id = 0, cost = 6000, pos = "名詞,固有名詞,一般"},
		{surface = "が", left_id = 0, right_id = 0, cost = 4000, pos = "助詞,格助詞,一般"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	alloc := constraint_arena(&arena, &arena_buf)

	plain, perr := moli.tokenize(&a, "さくらが", alloc)
	if perr != nil || len(plain) != 2 || plain[0].pos != "名詞,一般" {
		testing.expectf(t, false, "plain: err %v, %d morphemes", perr, len(plain))
		return
	}

	toks := []moli.Token_Constraint{{start = 0, end = 9, pos = "名詞,固有名詞"}}
	cons := moli.Constraints{tokens = toks}
	ms, cerr := moli.tokenize_constrained(&a, "さくらが", cons, {}, alloc)
	if cerr != nil {
		testing.expectf(t, false, "tokenize_constrained: %v", cerr)
		return
	}
	if len(ms) != 2 || ms[0].surface != "さくら" || ms[1].surface != "が" {
		testing.expectf(t, false, "want [さくら,が], got %d morphemes", len(ms))
		return
	}
	testing.expectf(t, ms[0].pos == "名詞,固有名詞,一般", "pinned pos %s, want 名詞,固有名詞,一般", ms[0].pos)
	testing.expectf(t, ms[0].entry_id != plain[0].entry_id,
		"pinned entry id %d must differ from plain %d", ms[0].entry_id, plain[0].entry_id)
	testing.expectf(t, ms[0].cost == 6000 && ms[0].end == 9 && ms[0].is_unknown == false,
		"pinned morpheme fields: cost %d end %d unknown %v", ms[0].cost, ms[0].end, ms[0].is_unknown)
}

@(test)
constraint_token_unknown_pin_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "が", left_id = 0, right_id = 0, cost = 4000, pos = "助詞,格助詞,一般"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	alloc := constraint_arena(&arena, &arena_buf)

	// どずが is one contiguous Hiragana run. The default flags offer
	// the grouped run, the run-start single-rune prefix, and (from
	// each interior position) that position's grouped remainder and
	// single rune - so [3,6) (ず) and [0,9) (the whole run) exist as
	// candidates while [0,6) does not.

	// Pinning the whole run keeps its grouped candidate as one
	// unknown morpheme (and the dictionary が inside it drops).
	toks_run := []moli.Token_Constraint{{start = 0, end = 9, pos = ""}}
	pin_run := moli.Constraints{tokens = toks_run}
	ms, err := moli.tokenize_constrained(&a, "どずが", pin_run, {}, alloc)
	if err != nil {
		testing.expectf(t, false, "pin (whole run): %v", err)
		return
	}
	if len(ms) != 1 || ms[0].surface != "どずが" || !ms[0].is_unknown || ms[0].end != 9 {
		testing.expectf(t, false, "pin (whole run): %d morphemes, first %v unknown=%v",
			len(ms), len(ms) > 0 ? ms[0].surface : "", len(ms) > 0 ? ms[0].is_unknown : false)
		return
	}

	// Pinning the interior rune leaves its neighbors' paths intact.
	toks_mid := []moli.Token_Constraint{{start = 3, end = 6, pos = ""}}
	pin_mid := moli.Constraints{tokens = toks_mid}
	ms2, err2 := moli.tokenize_constrained(&a, "どずが", pin_mid, {}, alloc)
	if err2 != nil {
		testing.expectf(t, false, "pin (interior rune): %v", err2)
		return
	}
	if len(ms2) != 3 || ms2[1].surface != "ず" || !ms2[1].is_unknown || ms2[1].start != 3 || ms2[1].end != 6 {
		testing.expectf(t, false, "pin (interior rune): want [ど,ず,が] with ず pinned, got %d", len(ms2))
		return
	}

	// A POS no candidate of that span can carry empties the region:
	// the single rune (pos 名詞,普通名詞) drops with the pattern, and
	// nothing else may end at byte 6.
	toks_v := []moli.Token_Constraint{{start = 3, end = 6, pos = "動詞"}}
	pin_verb := moli.Constraints{tokens = toks_v}
	_, err3 := moli.tokenize_constrained(&a, "どずが", pin_verb, {}, alloc)
	expect_unsatisfiable(t, err3, 6)
}

@(test)
constraint_boundary_forbid_test :: proc(t: ^testing.T) {
	// Plain prefers the split (31000 over 32000: the merge saves one
	// 7000 default edge but carries 8000 more node cost);
	// forbidding the boundary drops the あ that ends there and the
	// merge becomes the only path.
	entries := []Test_Entry{
		{surface = "あ", left_id = 0, right_id = 0, cost = 5000, pos = "x"},
		{surface = "い", left_id = 0, right_id = 0, cost = 5000, pos = "x"},
		{surface = "あい", left_id = 0, right_id = 0, cost = 18000, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	alloc := constraint_arena(&arena, &arena_buf)

	plain, perr := moli.tokenize(&a, "あい", alloc)
	if perr != nil || len(plain) != 2 {
		testing.expectf(t, false, "plain: err %v, %d morphemes", perr, len(plain))
		return
	}

	bounds := []moli.Boundary_Constraint{{at = 3, must_exist = false}}
	cons := moli.Constraints{boundaries = bounds}
	ms, cerr := moli.tokenize_constrained(&a, "あい", cons, {}, alloc)
	if cerr != nil {
		testing.expectf(t, false, "tokenize_constrained (forbid): %v", cerr)
		return
	}
	if len(ms) != 1 || ms[0].surface != "あい" || ms[0].start != 0 || ms[0].end != 6 {
		testing.expectf(t, false, "forbid: want one [あい], got %d morphemes", len(ms))
	}
}

@(test)
constraint_boundary_must_test :: proc(t: ^testing.T) {
	// Plain prefers the merge (9000 over 10000); requiring the
	// boundary drops the spanning あい and the split becomes the only
	// path.
	entries := []Test_Entry{
		{surface = "あ", left_id = 0, right_id = 0, cost = 5000, pos = "x"},
		{surface = "い", left_id = 0, right_id = 0, cost = 5000, pos = "x"},
		{surface = "あい", left_id = 0, right_id = 0, cost = 9000, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	alloc := constraint_arena(&arena, &arena_buf)

	plain, perr := moli.tokenize(&a, "あい", alloc)
	if perr != nil || len(plain) != 1 {
		testing.expectf(t, false, "plain: err %v, %d morphemes", perr, len(plain))
		return
	}

	bounds := []moli.Boundary_Constraint{{at = 3, must_exist = true}}
	cons := moli.Constraints{boundaries = bounds}
	ms, cerr := moli.tokenize_constrained(&a, "あい", cons, {}, alloc)
	if cerr != nil {
		testing.expectf(t, false, "tokenize_constrained (must): %v", cerr)
		return
	}
	if len(ms) != 2 || ms[0].surface != "あ" || ms[0].end != 3 || ms[1].surface != "い" || ms[1].start != 3 {
		testing.expectf(t, false, "must: want [あ,い] split at 3, got %d morphemes", len(ms))
	}
}

@(test)
constraint_boundary_must_unsat_test :: proc(t: ^testing.T) {
	// あい is the only candidate (the dictionary match suppresses
	// unknowns at offset 0, and nothing else ends mid-span);
	// requiring a boundary inside it empties position 3 entirely.
	entries := []Test_Entry{
		{surface = "あい", left_id = 0, right_id = 0, cost = 9000, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	alloc := constraint_arena(&arena, &arena_buf)

	bounds := []moli.Boundary_Constraint{{at = 3, must_exist = true}}
	cons := moli.Constraints{boundaries = bounds}
	_, err := moli.tokenize_constrained(&a, "あい", cons, {}, alloc)
	expect_unsatisfiable(t, err, 3)
}

@(test)
constraint_validation_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "さくら", left_id = 0, right_id = 0, cost = 5500, pos = "名詞,一般"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	alloc := constraint_arena(&arena, &arena_buf)

	tok0_9 := []moli.Token_Constraint{{start = 0, end = 9, pos = ""}}
	tok_oob := []moli.Token_Constraint{{start = 0, end = 99, pos = ""}}
	tok_empty := []moli.Token_Constraint{{start = 9, end = 9, pos = ""}}
	tok_midrune := []moli.Token_Constraint{{start = 1, end = 9, pos = ""}}
	tok_badpos := []moli.Token_Constraint{{start = 0, end = 9, pos = ",名詞"}}
	tok_overlap := []moli.Token_Constraint{{start = 0, end = 9, pos = ""}, {start = 3, end = 9, pos = ""}}
	b_in := []moli.Boundary_Constraint{{at = 3, must_exist = true}}
	b_zero := []moli.Boundary_Constraint{{at = 0, must_exist = true}}
	b_midrune := []moli.Boundary_Constraint{{at = 1, must_exist = true}}
	b_edge := []moli.Boundary_Constraint{{at = 9, must_exist = false}}
	b_conflict := []moli.Boundary_Constraint{{at = 3, must_exist = true}, {at = 3, must_exist = false}}

	Bad_Case :: struct {
		label:  string,
		cons:   moli.Constraints,
		reason: moli.Constraint_Reason,
		index:  int,
	}
	cases := []Bad_Case{
		{label = "span past end", cons = moli.Constraints{tokens = tok_oob}, reason = .Out_Of_Bounds, index = 0},
		{label = "empty span", cons = moli.Constraints{tokens = tok_empty}, reason = .Empty_Span, index = 0},
		{label = "mid-rune span edge", cons = moli.Constraints{tokens = tok_midrune}, reason = .Not_Rune_Boundary, index = 0},
		{label = "empty pos column", cons = moli.Constraints{tokens = tok_badpos}, reason = .Bad_Pos_Pattern, index = 0},
		{label = "overlapping tokens", cons = moli.Constraints{tokens = tok_overlap}, reason = .Token_Overlap, index = 1},
		{label = "boundary at text edge", cons = moli.Constraints{boundaries = b_zero}, reason = .Out_Of_Bounds, index = 0},
		{label = "mid-rune boundary", cons = moli.Constraints{boundaries = b_midrune}, reason = .Not_Rune_Boundary, index = 0},
		{label = "boundary inside token", cons = moli.Constraints{tokens = tok0_9, boundaries = b_in}, reason = .Boundary_Inside_Token, index = 0},
		{label = "forbidden edge of token", cons = moli.Constraints{tokens = tok0_9, boundaries = b_edge}, reason = .Boundary_At_Token_Edge, index = 0},
		{label = "conflicting boundaries", cons = moli.Constraints{boundaries = b_conflict}, reason = .Conflicting_Boundaries, index = -1},
	}

	for c in cases {
		_, err := moli.tokenize_constrained(&a, "さくらが", c.cons, {}, alloc)
		if err == nil {
			testing.expectf(t, false, "%s: want a fault", c.label)
			continue
		}
		expect_bad_constraint(t, err, c.reason, c.index)
	}

	// The redundant-but-consistent combination stays legal: a
	// must-exist boundary at a token span's edge is implied by the
	// pin, not contradicted by it.
	b_at9 := []moli.Boundary_Constraint{{at = 9, must_exist = true}}
	ok_cons := moli.Constraints{tokens = tok0_9, boundaries = b_at9}
	ms, err2 := moli.tokenize_constrained(&a, "さくらが", ok_cons, {}, alloc)
	if err2 != nil {
		testing.expectf(t, false, "pin + edge boundary: %v", err2)
		return
	}
	testing.expectf(t, len(ms) == 2 && ms[0].surface == "さくら" && ms[0].end == 9 && ms[1].surface == "が",
		"pin + edge boundary: want [さくら,が], got %d", len(ms))
}

@(test)
constraint_nfc_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "さくら", left_id = 0, right_id = 0, cost = 5500, pos = "名詞,一般"},
		{surface = "が", left_id = 0, right_id = 0, cost = 4000, pos = "助詞,格助詞,一般"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	alloc := constraint_arena(&arena, &arena_buf)

	// NFD が = か + U+3099 (15 bytes composed down to 12): a token
	// pin over the decomposed pair indexes bytes normalization
	// removes, so the call faults instead of re-reading the offsets
	// against a different string.
	nfd := "さくらか\u3099"
	toks := []moli.Token_Constraint{{start = 9, end = 15, pos = ""}}
	cons := moli.Constraints{tokens = toks}
	_, err := moli.tokenize_constrained(&a, nfd, cons, {normalize_nfc = true}, alloc)
	if !expect_bad_constraint(t, err, .Normalization_Rescaled, -1) { return }

	// The zero set has no offsets to invalidate, so the same rescaling
	// input must take tokenize_opt's composition - the zero-value
	// identity holds under normalize_nfc too.
	zero, zerr := moli.tokenize_constrained(&a, nfd, moli.Constraints{}, {normalize_nfc = true}, alloc)
	if zerr != nil {
		testing.expectf(t, false, "zero set + rescaling nfc: %v", zerr)
		return
	}
	plain_nfd, pnerr := moli.tokenize_opt(&a, nfd, {normalize_nfc = true}, alloc)
	if pnerr != nil {
		testing.expectf(t, false, "tokenize_opt (rescaling nfc): %v", pnerr)
		return
	}
	testing.expectf(t, morph_seq_eq(plain_nfd, zero), "zero set diverged from plain tokenize under rescaling nfc")

	// Already-NFC text under the same flag keeps its offsets (the
	// composition is byte-identical) and matches the flag-bearing
	// plain tokenize.
	nfc := "さくらが"
	bounds := []moli.Boundary_Constraint{{at = 9, must_exist = true}}
	cons2 := moli.Constraints{boundaries = bounds}
	ms, err2 := moli.tokenize_constrained(&a, nfc, cons2, {normalize_nfc = true}, alloc)
	if err2 != nil {
		testing.expectf(t, false, "already-NFC + constraints: %v", err2)
		return
	}
	plain, perr := moli.tokenize_opt(&a, nfc, {normalize_nfc = true}, alloc)
	if perr != nil {
		testing.expectf(t, false, "tokenize_opt(nfc): %v", perr)
		return
	}
	testing.expectf(t, morph_seq_eq(plain, ms), "already-NFC constraint set diverged from plain tokenize")
}

@(test)
constraint_nbest_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "あ", left_id = 0, right_id = 0, cost = 5000, pos = "x"},
		{surface = "い", left_id = 0, right_id = 0, cost = 5000, pos = "x"},
		{surface = "あい", left_id = 0, right_id = 0, cost = 9000, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	alloc := constraint_arena(&arena, &arena_buf)

	bounds := []moli.Boundary_Constraint{{at = 3, must_exist = true}}
	cons := moli.Constraints{boundaries = bounds}

	paths := make([dynamic]moli.NBest_Path, 0, 4, alloc)
	if err := moli.tokenize_nbest(&a, "あい", 3, {}, cons, &paths, alloc); err != nil {
		testing.expectf(t, false, "tokenize_nbest (constrained): %v", err)
		return
	}
	// The spanning path is gone; the split is the only one left, at
	// 3 edges * 7000 + 5000 + 5000.
	if len(paths) != 1 {
		testing.expectf(t, false, "want 1 path, got %d", len(paths))
		return
	}
	testing.expectf(t, paths[0].cost == 31000, "path cost %d, want 31000", paths[0].cost)
	if len(paths[0].morphemes) != 2 || paths[0].morphemes[0].end != 3 || paths[0].morphemes[1].start != 3 {
		testing.expectf(t, false, "path does not split at the required boundary")
		return
	}
	ms, cerr := moli.tokenize_constrained(&a, "あい", cons, {}, alloc)
	if cerr != nil {
		testing.expectf(t, false, "tokenize_constrained: %v", cerr)
		return
	}
	testing.expectf(t, morph_seq_eq(ms, paths[0].morphemes[:]), "nbest best path disagrees with tokenize_constrained")

	// The same mask faults the n-best search when nothing survives.
	solo := []Test_Entry{
		{surface = "あい", left_id = 0, right_id = 0, cost = 9000, pos = "x"},
	}
	a2, ok2 := build_test_analyzer(t, .Japanese, .Viterbi, solo, nil, 0)
	if !ok2 { return }
	defer moli.free(&a2)
	paths2 := make([dynamic]moli.NBest_Path, 0, 4, alloc)
	err2 := moli.tokenize_nbest(&a2, "あい", 3, {}, cons, &paths2, alloc)
	if err2 == nil {
		testing.expectf(t, false, "want Unsatisfiable_Error, got %d paths", len(paths2))
		return
	}
	expect_unsatisfiable(t, err2, 3)
}
