// N-best enumeration coverage: paths leave the search in cost order,
// the best path matches tokenize, homographs enumerate as separate
// paths (distinct POS/cost), k clamps while over-large k returns
// only the distinct paths the lattice holds, and the NFC wrapper
// composes NFD input before the search (staying unknown without the
// flag, like tokenize_opt).
package tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "moli:moli"

nbest_arena_alloc :: proc(t: ^testing.T, arena: ^mem.Arena, arena_buf: ^[1 << 16]byte) -> mem.Allocator {
	mem.arena_init(arena, arena_buf[:])
	return mem.arena_allocator(arena)
}

@(test)
nbest_ranking_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "A", left_id = 0, right_id = 0, cost = 0,  pos = "x"},
		{surface = "B", left_id = 0, right_id = 0, cost = 0,  pos = "x"},
		{surface = "AB", left_id = 0, right_id = 0, cost = 10, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .EnglishUS, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	arena_alloc := nbest_arena_alloc(t, &arena, &arena_buf)

	paths := make([dynamic]moli.NBest_Path, 0, 4, arena_alloc)
	if err := moli.tokenize_nbest(&a, "AB", 2, {}, {}, &paths, arena_alloc); err != nil {
		testing.expectf(t, false, "tokenize_nbest: %v", err)
		return
	}
	// Edge cost is the no-matrix default (7000) everywhere:
	// [AB] = 2 edges + 10 = 14010; [A,B] = 3 edges = 21000.
	if len(paths) != 2 {
		testing.expectf(t, false, "want 2 paths, got %d", len(paths))
		return
	}
	testing.expectf(t, paths[0].cost == 14010, "path 0 cost %v, want 14010", paths[0].cost)
	testing.expectf(t, paths[1].cost == 21000, "path 1 cost %v, want 21000", paths[1].cost)
	testing.expectf(t, len(paths[0].morphemes) == 1 && paths[0].morphemes[0].surface == "AB", "path 0 is [AB]")
	testing.expectf(t, len(paths[1].morphemes) == 2 && paths[1].morphemes[0].surface == "A", "path 1 is [A,B]")

	// The enumerated best path agrees with tokenize's segmentation.
	ms, terr := moli.tokenize(&a, "AB", arena_alloc)
	if terr != nil {
		testing.expectf(t, false, "tokenize: %v", terr)
		return
	}
	same := len(ms) == len(paths[0].morphemes)
	if same {
		for i in 0 ..< len(ms) {
			if ms[i].surface != paths[0].morphemes[i].surface { same = false }
		}
	}
	testing.expectf(t, same, "nbest[0] matches tokenize output")
}

@(test)
nbest_homographs_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "A",  left_id = 0, right_id = 0, cost = 0,  pos = "x"},
		{surface = "B",  left_id = 0, right_id = 0, cost = 0,  pos = "x"},
		{surface = "AB", left_id = 0, right_id = 0, cost = 10, pos = "X"},
		{surface = "AB", left_id = 0, right_id = 0, cost = 11, pos = "Y"},
	}
	a, ok := build_test_analyzer(t, .EnglishUS, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	arena_alloc := nbest_arena_alloc(t, &arena, &arena_buf)

	paths := make([dynamic]moli.NBest_Path, 0, 4, arena_alloc)
	if err := moli.tokenize_nbest(&a, "AB", 3, {}, {}, &paths, arena_alloc); err != nil {
		testing.expectf(t, false, "tokenize_nbest: %v", err)
		return
	}
	if len(paths) != 3 {
		testing.expectf(t, false, "want 3 distinct paths, got %d", len(paths))
		return
	}
	testing.expectf(t, paths[0].cost < paths[1].cost && paths[1].cost < paths[2].cost, "strictly ascending costs")
	testing.expectf(t, paths[0].morphemes[0].pos == "X" && paths[1].morphemes[0].pos == "Y",
		"homograph paths keep their own POS (%s, %s)", paths[0].morphemes[0].pos, paths[1].morphemes[0].pos)
	testing.expectf(t, len(paths[2].morphemes) == 2, "third path is the split")
}

@(test)
nbest_k_bounds_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "A", left_id = 0, right_id = 0, cost = 0, pos = "x"},
		{surface = "AB", left_id = 0, right_id = 0, cost = 5, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .EnglishUS, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	arena_alloc := nbest_arena_alloc(t, &arena, &arena_buf)

	// k < 1 clamps to 1: exactly one path comes back.
	one := make([dynamic]moli.NBest_Path, 0, 2, arena_alloc)
	if err := moli.tokenize_nbest(&a, "AB", 0, {}, {}, &one, arena_alloc); err != nil {
		testing.expectf(t, false, "tokenize_nbest k=0: %v", err)
		return
	}
	testing.expectf(t, len(one) == 1, "k=0 clamps to one path, got %d", len(one))

	// k far beyond the lattice's distinct paths: all of them, no
	// padding, no error. Distinct paths here: [AB], [A,B].
	all := make([dynamic]moli.NBest_Path, 0, 2, arena_alloc)
	if err := moli.tokenize_nbest(&a, "AB", 99, {}, {}, &all, arena_alloc); err != nil {
		testing.expectf(t, false, "tokenize_nbest k=99: %v", err)
		return
	}
	testing.expectf(t, len(all) == 2, "over-large k returns the 2 real paths, got %d", len(all))
}

// The heap comparator breaks equal-f ties by insertion index - a
// deterministic total order. End to end: two distinct paths with the
// same total (AB priced so [AB] ties [A,B] at three default edges)
// both enumerate, in a stable order across repeated searches.
@(test)
nbest_tie_break_test :: proc(t: ^testing.T) {
	heap_entries := []moli.NBest_Entry{
		{f = 5, g = 0, node = 0, parent = -1},
		{f = 5, g = 0, node = 0, parent = -1},
		{f = 3, g = 0, node = 0, parent = -1},
	}
	testing.expectf(t,
		moli.nbest_entry_less(heap_entries[:], 0, 1) && !moli.nbest_entry_less(heap_entries[:], 1, 0),
		"equal-f tie is broken by index (a strict order)")
	testing.expectf(t, moli.nbest_entry_less(heap_entries[:], 2, 0), "lower f orders first")

	entries := []Test_Entry{
		{surface = "A",  left_id = 0, right_id = 0, cost = 0,    pos = "x"},
		{surface = "B",  left_id = 0, right_id = 0, cost = 0,    pos = "x"},
		{surface = "AB", left_id = 0, right_id = 0, cost = 7000, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .EnglishUS, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	arena_alloc := nbest_arena_alloc(t, &arena, &arena_buf)

	paths := make([dynamic]moli.NBest_Path, 0, 2, arena_alloc)
	if err := moli.tokenize_nbest(&a, "AB", 2, {}, {}, &paths, arena_alloc); err != nil {
		testing.expectf(t, false, "tokenize_nbest: %v", err)
		return
	}
	if len(paths) != 2 {
		testing.expectf(t, false, "want the 2 tied paths, got %d", len(paths))
		return
	}
	testing.expectf(t, paths[0].cost == 21000 && paths[1].cost == 21000,
		"tied totals: %v and %v", paths[0].cost, paths[1].cost)
	testing.expectf(t,
		len(paths[0].morphemes) + len(paths[1].morphemes) == 3 && len(paths[0].morphemes) != len(paths[1].morphemes),
		"the tied paths are the whole and the split (%d, %d)",
		len(paths[0].morphemes), len(paths[1].morphemes))

	paths2 := make([dynamic]moli.NBest_Path, 0, 2, arena_alloc)
	if err := moli.tokenize_nbest(&a, "AB", 2, {}, {}, &paths2, arena_alloc); err != nil {
		testing.expectf(t, false, "tokenize_nbest again: %v", err)
		return
	}
	testing.expectf(t, len(paths2[0].morphemes) == len(paths[0].morphemes),
		"the tie enumerates identically across searches")
}

@(test)
nbest_nfc_flag_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
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

	nfd := runes_str([]rune{0x304B, 0x3099}, allocator)
	defer delete(nfd, allocator)

	// The N-best wrapper composes before the search: the decomposed
	// pair matches the NFC dictionary surface on the best path.
	paths := make([dynamic]moli.NBest_Path, 0, 2, arena_alloc)
	if err := moli.tokenize_nbest(&a, nfd, 2, {normalize_nfc = true}, moli.Constraints{}, &paths, arena_alloc); err != nil {
		testing.expectf(t, false, "tokenize_nbest(nfc flag): %v", err)
		return
	}
	testing.expectf(t, len(paths) >= 1 && len(paths[0].morphemes) == 1 &&
		paths[0].morphemes[0].surface == "が" && !paths[0].morphemes[0].is_unknown,
		"NFD input composes on the best path, got %v paths", len(paths))

	// Without the flag the same input stays unknown, like tokenize_opt.
	mem.arena_free_all(&arena)
	plain := make([dynamic]moli.NBest_Path, 0, 2, arena_alloc)
	if err := moli.tokenize_nbest(&a, nfd, 2, {}, {}, &plain, arena_alloc); err != nil {
		testing.expectf(t, false, "tokenize_nbest(no flag): %v", err)
		return
	}
	testing.expectf(t, len(plain) >= 1 && plain[0].morphemes[0].is_unknown,
		"NFD input stays unknown without the flag")
}

// The per-rune unknown price must stay full-width arithmetic: a
// grouped run longer than 65535 runes carries that many runes on one
// node, so a 16-bit rune count anywhere in the pipeline would wrap at
// this boundary and bend the cost curve. Two lengths straddling the
// boundary, identical shape otherwise: the cost difference is exactly
// per_rune x delta. The class runs group-only (char.def semantics the
// helpers invite tests to assign), so the grouped node is the lattice
// candidate under test and the backward DP stays linear here.
@(test)
nbest_per_rune_width_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	a.char_flags[int(moli.Char_Class.Katakana)] = moli.Char_Flags{
		invoke = false, group = true, length = 0,
	}
	defer moli.free(&a)

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	alloc := mem.dynamic_arena_allocator(&scratch)

	per_rune :: 2300
	lengths := []int{65530, 65545}
	costs := make([dynamic]i64, 0, len(lengths), alloc)
	for n in lengths {
		text, terr := strings.repeat("ァ", n, alloc)
		if terr != nil {
			testing.expectf(t, false, "repeat(%d): %v", n, terr)
			return
		}
		paths := make([dynamic]moli.NBest_Path, 0, 1, alloc)
		if err := moli.tokenize_nbest(&a, text, 1, {unk_cost_per_rune = per_rune}, moli.Constraints{}, &paths, alloc); err != nil {
			testing.expectf(t, false, "tokenize_nbest(%d): %v", n, err)
			return
		}
		if len(paths) != 1 || len(paths[0].morphemes) != 1 {
			testing.expectf(t, false, "n=%d: want 1 path over the grouped run, got %d paths",
				n, len(paths))
			return
		}
		if len(paths[0].morphemes[0].surface) != 3 * n {
			testing.expectf(t, false, "n=%d: grouped surface %d bytes, want %d",
				n, len(paths[0].morphemes[0].surface), 3 * n)
			return
		}
		append(&costs, paths[0].cost)
	}
	delta := costs[1] - costs[0]
	want := i64(per_rune) * 15
	testing.expectf(t, delta == want,
		"cost delta %v, want %v (per_rune x 15 runes) - a wrapped rune count bends the curve",
		delta, want)
}
