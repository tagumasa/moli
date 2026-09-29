// Tokenizer coverage: the greedy loop, unknown-run grouping (kanji/
// katakana/ASCII runs collapse to one morpheme), the "*" lemma ->
// surface fallback, malformed UTF-8 (contiguous invalid bytes become a
// single unknown run), and wakachi.
package tests

import "base:runtime"
import "core:mem"
import "core:testing"
import "moli:moli"

@(test)
tokenizer_greedy_loop_test :: proc(t: ^testing.T) {
	greedy := moli.Load_Options{mode = .LongestMatch}
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, greedy)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	ms, err := moli.tokenize(&a, "犬が歩く", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	if len(ms) != 3 {
		testing.expectf(t, false, "犬が歩く: %v morphemes", len(ms))
		return
	}

	// The dynamic-sink leg: tokenize_into on a LongestMatch analyzer
	// runs the same greedy loop through the caller-owned array.
	out: [dynamic]moli.Morpheme
	out.allocator = mem.arena_allocator(&arena)
	if ierr := moli.tokenize_into(&a, "犬が歩く", &out, mem.arena_allocator(&arena)); ierr != nil {
		testing.expectf(t, false, "tokenize_into: %v", ierr)
		return
	}
	testing.expectf(t, len(out) == 3 && out[2].surface == "歩く",
		"greedy tokenize_into: %v morphemes, last %q", len(out), len(out) > 0 ? out[len(out) - 1].surface : "")
	if !expect_morph(t, ms[0], "犬", "名詞,一般", "犬") { return }
	if !expect_morph(t, ms[1], "が", "助詞,格助詞,一般", "が") { return }
	if !expect_morph(t, ms[2], "歩く", "動詞,自立,五段・カ行,基本形", "歩く") { return }

	// Byte offsets tile the input exactly (four runes, 3 bytes each).
	if ms[0].start != 0 || ms[0].end != 3 { testing.expectf(t, false, "offsets[0]"); return }
	if ms[1].start != 3 || ms[1].end != 6 { testing.expectf(t, false, "offsets[1]"); return }
	if ms[2].start != 6 || ms[2].end != 12 { testing.expectf(t, false, "offsets[2]"); return }

	// Longest-match: 東京 as one morpheme, then の, then 犬.
	ms2, err2 := moli.tokenize(&a, "東京の犬", mem.arena_allocator(&arena))
	if err2 != nil {
		testing.expectf(t, false, "tokenize 2: %v", err2)
		return
	}
	if len(ms2) != 3 || ms2[0].surface != "東京" || ms2[1].surface != "の" || ms2[2].surface != "犬" {
		testing.expectf(t, false, "東京の犬: %v morphemes", len(ms2))
		return
	}
	for _, i in ms2 {
		if i > 0 && ms2[i].start != ms2[i-1].end {
			testing.expectf(t, false, "contiguity broken at %v", i)
			return
		}
	}

	// Empty input answers zero morphemes.
	if ms3, err := moli.tokenize(&a, "", mem.arena_allocator(&arena)); err != nil || len(ms3) != 0 {
		testing.expectf(t, false, "empty input: (%v, %v)", len(ms3), err)
		return
	}
}

@(test)
tokenizer_unknown_run_grouping_test :: proc(t: ^testing.T) {
	greedy := moli.Load_Options{mode = .LongestMatch}
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, greedy)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	// ザザ matches nothing: the whole katakana run is ONE unknown
	// morpheme, then the dictionary word 犬.
	ms, err := moli.tokenize(&a, "ザザ犬", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	if len(ms) != 2 {
		testing.expectf(t, false, "ザザ犬: %v morphemes", len(ms))
		return
	}
	if ms[0].surface != "ザザ" || !ms[0].is_unknown {
		testing.expectf(t, false, "run morpheme: (%q, unknown=%v)", ms[0].surface, ms[0].is_unknown)
		return
	}
	// Unknown morphemes lemmatize to their surface and use the
	// fallback POS; the run's class comes from its first rune.
	if ms[0].lemma != "ザザ" || ms[0].pos != "名詞,普通名詞" || ms[0].char_class != .Katakana {
		testing.expectf(t, false, "run fields: (%q, %q, %v)", ms[0].lemma, ms[0].pos, ms[0].char_class)
		return
	}
	if ms[1].surface != "犬" || ms[1].is_unknown {
		testing.expectf(t, false, "dictionary word after run: %q", ms[1].surface)
		return
	}

	// A kanji run that matches nothing is likewise one morpheme.
	ms2, _ := moli.tokenize(&a, "檜山檜", mem.arena_allocator(&arena))
	if len(ms2) != 1 || ms2[0].surface != "檜山檜" || !ms2[0].is_unknown || ms2[0].char_class != .Hanzi {
		testing.expectf(t, false, "kanji run: %v morphemes", len(ms2))
		return
	}
}

@(test)
tokenizer_lemma_fallback_test :: proc(t: ^testing.T) {
	greedy := moli.Load_Options{mode = .LongestMatch}
	a, ok := load_ok(t, .EnglishGB, EN_FIXTURE, greedy)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	// defence carries lemma "*": it falls back to the surface.
	// travels carries a real differing lemma. The inter-word space is
	// its own (unknown) morpheme - Space is a char class like any
	// other.
	ms, err := moli.tokenize(&a, "defence travels", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	if len(ms) != 3 {
		testing.expectf(t, false, "defence travels: %v morphemes", len(ms))
		return
	}
	if !expect_morph(t, ms[0], "defence", "NOUN", "defence") { return }
	if !expect_morph(t, ms[2], "travels", "VERB", "travel") { return }
	if ms[1].surface != " " || !ms[1].is_unknown {
		testing.expectf(t, false, "space morpheme: (%q, unknown=%v)", ms[1].surface, ms[1].is_unknown)
		return
	}

	// Unknown English input lemmatizes to its surface.
	ms2, _ := moli.tokenize(&a, "xylophone", mem.arena_allocator(&arena))
	if len(ms2) != 1 || !ms2[0].is_unknown || ms2[0].lemma != "xylophone" {
		testing.expectf(t, false, "unknown lemma: (%q, %v)",
			len(ms2) > 0 ? ms2[0].lemma : "", len(ms2) > 0 ? ms2[0].is_unknown : false)
		return
	}
}

@(test)
tokenizer_malformed_utf8_test :: proc(t: ^testing.T) {
	greedy := moli.Load_Options{mode = .LongestMatch}
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, greedy)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	// Two contiguous invalid bytes: one unknown morpheme covering
	// exactly those bytes; the decode never aborts the loop.
	ms, err := moli.tokenize(&a, "犬\xFF\xFEが", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	if len(ms) != 3 {
		testing.expectf(t, false, "malformed input: %v morphemes", len(ms))
		return
	}
	if ms[0].surface != "犬" || ms[0].end != 3 {
		testing.expectf(t, false, "head morpheme: (%q, end %v)", ms[0].surface, ms[0].end)
		return
	}
	if !ms[1].is_unknown || ms[1].start != 3 || ms[1].end != 5 || len(ms[1].surface) != 2 {
		testing.expectf(t, false, "bad-byte morpheme: (unknown=%v, %v..%v, len %v)",
			ms[1].is_unknown, ms[1].start, ms[1].end, len(ms[1].surface))
		return
	}
	if ms[2].surface != "が" || ms[2].start != 5 {
		testing.expectf(t, false, "tail morpheme: (%q, start %v)", ms[2].surface, ms[2].start)
		return
	}
}

@(test)
tokenizer_wakachi_test :: proc(t: ^testing.T) {
	greedy := moli.Load_Options{mode = .LongestMatch}
	viterbi := moli.Load_Options{mode = .Viterbi}

	ga, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, greedy)
	if !ok { return }
	defer moli.free(&ga)
	va, ok2 := load_ok(t, .Japanese, IPADIC_FIXTURE, viterbi)
	if !ok2 { return }
	defer moli.free(&va)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	// Both modes emit the same surfaces for this input; wakachi
	// honors a.mode rather than always running the greedy loop.
	gs, err := moli.tokenize_wakachi(&ga, "犬が歩く", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "greedy wakachi: %v", err)
		return
	}
	if len(gs) != 3 || gs[0] != "犬" || gs[1] != "が" || gs[2] != "歩く" {
		testing.expectf(t, false, "greedy wakachi: %v surfaces", len(gs))
		return
	}
	vs, err2 := moli.tokenize_wakachi(&va, "犬が歩く", mem.arena_allocator(&arena))
	if err2 != nil {
		testing.expectf(t, false, "viterbi wakachi: %v", err2)
		return
	}
	if len(vs) != 3 || vs[0] != "犬" || vs[1] != "が" || vs[2] != "歩く" {
		testing.expectf(t, false, "viterbi wakachi: %v surfaces", len(vs))
		return
	}

	// Wakachi surfaces slice the input: byte offsets are exact.
	if gs[0] != "犬が歩く"[0:3] {
		testing.expectf(t, false, "wakachi surface is not a slice of the input")
		return
	}
}

// Wakachi over unknown runs in both modes: a known word followed by an
// out-of-vocabulary katakana run answers exactly [known, run] - the
// greedy loop's unknown_run_end leg and the Viterbi path's unknown
// group candidate.
@(test)
tokenizer_wakachi_unknown_run_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "犬", left_id = 0, right_id = 0, cost = 0, pos = "名詞"},
	}
	ga, ok := build_test_analyzer(t, .Japanese, .LongestMatch, entries, nil, 0)
	if !ok { return }
	defer moli.free(&ga)
	va, ok2 := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok2 { return }
	defer moli.free(&va)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	gs, err := moli.tokenize_wakachi(&ga, "犬ヴェルタース", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "greedy wakachi: %v", err)
		return
	}
	testing.expectf(t, len(gs) == 2 && gs[0] == "犬" && gs[1] == "ヴェルタース",
		"greedy wakachi unknown run: %d surfaces", len(gs))

	mem.arena_free_all(&arena)
	vs, err2 := moli.tokenize_wakachi(&va, "犬ヴェルタース", mem.arena_allocator(&arena))
	if err2 != nil {
		testing.expectf(t, false, "viterbi wakachi: %v", err2)
		return
	}
	testing.expectf(t, len(vs) == 2 && vs[0] == "犬" && vs[1] == "ヴェルタース",
		"viterbi wakachi unknown run: %d surfaces", len(vs))
}

// A starved arena propagates out of tokenize as .OutOfMemory: budget
// zero fails the first allocation the call makes (the normalizer's
// decompose buffer), exercising the wrapper's error pass-through.
@(test)
tokenize_oom_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	b := Budget_Allocator{backing = context.allocator, remaining = 0}
	allocator := mem.Allocator{data = &b, procedure = budget_allocator_proc}
	if _, err := moli.tokenize(&a, "犬が歩く", allocator); err != .OutOfMemory {
		testing.expectf(t, false, "starved tokenize: %v", err)
		return
	}
}

// tokenize_into replaces the caller's buffer contents on every call:
// a reused dynamic must not accumulate morphemes from earlier calls,
// whose strings point into those calls' (long-gone) arenas.
@(test)
tokenize_into_reuse_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	out: [dynamic]moli.Morpheme
	defer delete(out)

	buf1: [1 << 16]byte
	arena1: mem.Arena
	mem.arena_init(&arena1, buf1[:])
	if err := moli.tokenize_into(&a, "犬が歩く", &out, mem.arena_allocator(&arena1)); err != nil {
		testing.expectf(t, false, "first tokenize_into: %v", err)
		return
	}
	n_first := len(out)
	if n_first < 3 {
		testing.expectf(t, false, "first call: %d morphemes", n_first)
		return
	}

	buf2: [1 << 16]byte
	arena2: mem.Arena
	mem.arena_init(&arena2, buf2[:])
	if err := moli.tokenize_into(&a, "犬が歩く", &out, mem.arena_allocator(&arena2)); err != nil {
		testing.expectf(t, false, "second tokenize_into: %v", err)
		return
	}
	if len(out) != n_first {
		testing.expectf(t, false,
			"the second call must replace the buffer's contents, not append: %d vs %d", len(out), n_first)
		return
	}
	testing.expectf(t, out[0].surface == "犬", "the surviving morphemes are the second call's")
}
