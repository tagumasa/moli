// Viterbi coverage: lattice construction (homographs enumerated,
// BOS/EOS boundary ids), unknown-run connectivity (a dictionary word
// starting inside an unknown run is reachable and the best path can
// split the run around it), DP and traceback determinism, boundary
// costs via row/column 0, the boundary self-edge regression (a
// negative `0 0` matrix cell must not make BOS/EOS their own
// predecessors), and the homograph range enumeration order (groups
// descending, prefix surfaces in walk order).
package tests

import "base:runtime"
import "core:mem"
import "core:testing"
import "moli:moli"

@(test)
viterbi_lattice_construction_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	lattice, err := moli.build_lattice(&a, "さくら", nil, {}, mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "build_lattice: %v", err)
		return
	}
	// BOS + both homograph candidates at 0 + unknown candidates at the
	// two inner positions with no dictionary candidate (positions 3
	// and 6: a full-run plus a single-rune node, and a single node)
	// + EOS = 7 nodes. The inner unknowns are the connectivity
	// mechanism (see viterbi_unknown_run_connectivity_test).
	if len(lattice) != 7 {
		testing.expectf(t, false, "lattice: %v nodes", len(lattice))
		return
	}
	bos := lattice[0]
	if bos.start != 0 || bos.end != 0 || bos.entry_id != -1 || bos.is_unknown {
		testing.expectf(t, false, "BOS: %+v", bos)
		return
	}
	// Both さくら entries are lattice candidates (surface-sorted ids 1
	// and 2: が sorts first, the さくら pair follows, file order kept
	// within the group).
	ids := 0
	for n in lattice {
		if n.entry_id == 1 { ids += 1 }
		if n.entry_id == 2 { ids += 2 }
	}
	if ids != 3 {
		testing.expectf(t, false, "homograph candidates: id-mask %v", ids)
		return
	}
	eos := lattice[len(lattice) - 1]
	if eos.start != 9 || eos.end != 9 || eos.entry_id != -1 {
		testing.expectf(t, false, "EOS: %+v", eos)
		return
	}
}

@(test)
viterbi_unknown_run_connectivity_test :: proc(t: ^testing.T) {
	// The dictionary word アス starts INSIDE the katakana run アアスア.
	// Without the single-rune unknown candidate, its node would be
	// dead (the whole-run candidate overshoots its start).
	entries := []Test_Entry{
		{surface = "アス", left_id = 1, right_id = 1, cost = 100, pos = "名詞,一般"},
	}
	cells := []i16{0, -8000, -8000, 7000}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, cells, 2)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	lattice, err := moli.build_lattice(&a, "アアスア", nil, {}, arena_alloc)
	if err != nil {
		testing.expectf(t, false, "build_lattice: %v", err)
		return
	}
	path, perr := moli.viterbi_best_path(&a, lattice, "アアスア", 0, 0, arena_alloc)
	if perr != nil {
		testing.expectf(t, false, "best_path: %v", perr)
		return
	}

	// The dictionary node was reachable and IS on the best path: the
	// negative transition gradient pays for splitting the run.
	on_path := false
	for i in path {
		if lattice[i].entry_id == 0 { on_path = true }
	}
	if !on_path {
		testing.expectf(t, false, "dictionary word inside the run is unreachable")
		return
	}

	ms, terr := moli.tokenize(&a, "アアスア", arena_alloc)
	if terr != nil {
		testing.expectf(t, false, "tokenize: %v", terr)
		return
	}
	if len(ms) != 3 || ms[0].surface != "ア" || ms[1].surface != "アス" || ms[2].surface != "ア" {
		testing.expectf(t, false, "split path: %v morphemes", len(ms))
		return
	}
	if ms[1].is_unknown || !ms[0].is_unknown || !ms[2].is_unknown {
		testing.expectf(t, false, "split path unknown flags wrong")
		return
	}

	// Greedy mode on the same analyzer cannot split: the run is one
	// unknown morpheme.
	a.mode = .LongestMatch
	ms2, terr2 := moli.tokenize(&a, "アアスア", arena_alloc)
	if terr2 != nil {
		testing.expectf(t, false, "greedy tokenize: %v", terr2)
		return
	}
	if len(ms2) != 1 || ms2[0].surface != "アアスア" {
		testing.expectf(t, false, "greedy whole-run: %v morphemes", len(ms2))
		return
	}
}

@(test)
viterbi_dp_traceback_determinism_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	// The さくら homograph pair resolves to the cheaper entry (名詞,
	// 一般, cost 5500) on every run.
	for _ in 0 ..< 3 {
		ms, err := moli.tokenize(&a, "さくら", mem.arena_allocator(&arena))
		if err != nil {
			testing.expectf(t, false, "tokenize: %v", err)
			return
		}
		if len(ms) != 1 {
			testing.expectf(t, false, "さくら: %v morphemes", len(ms))
			return
		}
		if !expect_morph(t, ms[0], "さくら", "名詞,一般", "さくら") { return }
	}

	ms, err := moli.tokenize(&a, "さくらの犬", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	if len(ms) != 3 || ms[0].surface != "さくら" || ms[1].surface != "の" || ms[2].surface != "犬" {
		testing.expectf(t, false, "さくらの犬: %v morphemes", len(ms))
		return
	}
	if !expect_morph(t, ms[0], "さくら", "名詞,一般", "さくら") { return }
}

@(test)
viterbi_boundary_cost_test :: proc(t: ^testing.T) {
	// A 1x1 matrix whose single cell is 42: BOS.right_id and EOS
	// left_id are 0 by convention, so both boundary transitions cost
	// 42 and the EOS dp_cost is node cost + 2 * 42.
	entries := []Test_Entry{
		{surface = "犬", left_id = 0, right_id = 0, cost = 5000, pos = "名詞,一般"},
	}
	cells := []i16{42}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, cells, 1)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	if got := moli.matrix_cost(&a.conn_matrix, 0, 0); got != 42 {
		testing.expectf(t, false, "matrix (0,0): %v", got)
		return
	}

	lattice, err := moli.build_lattice(&a, "犬", nil, {}, arena_alloc)
	if err != nil {
		testing.expectf(t, false, "build_lattice: %v", err)
		return
	}
	_, err = moli.viterbi_best_path(&a, lattice, "犬", 0, 0, arena_alloc)
	if err != nil {
		testing.expectf(t, false, "best_path: %v", err)
		return
	}

	// The DP's boundary arithmetic is observable through the n-best
	// search cost: one path exists and its cost is node + both boundary
	// edges, 5000 + 2 * 42.
	paths := make([dynamic]moli.NBest_Path, 0, 4, arena_alloc)
	if nerr := moli.tokenize_nbest(&a, "犬", 1, {}, {}, &paths, arena_alloc); nerr != nil {
		testing.expectf(t, false, "nbest: %v", nerr)
		return
	}
	if len(paths) != 1 || paths[0].cost != 5000 + 2 * 42 {
		testing.expectf(t, false, "nbest: %v paths (want 1 costing %v)", len(paths), 5000 + 84)
		return
	}

	// Boundary lookup degrade: out-of-range and no-matrix cases keep
	// the default cost (covered fully in matrix_test).
	zero := moli.Connection_Matrix{}
	if got := moli.matrix_cost(&zero, 0, 0); got != moli.CONNECTION_DEFAULT_COST {
		testing.expectf(t, false, "no-matrix boundary: %v", got)
		return
	}
}

@(test)
viterbi_boundary_self_edge_test :: proc(t: ^testing.T) {
	// ipadic 2.7.0's matrix.def opens with `0 0 -434`: the cell the
	// boundary ids hit is NEGATIVE. BOS and EOS are zero-width nodes,
	// so their successor bucket is their own start group; without the
	// zero-width guard the DP relaxes BOS->BOS and EOS->EOS, sets
	// prev = self, and the traceback never reaches -1 (on the unfixed
	// code this test hangs rather than failing - that is the point).
	entries := []Test_Entry{
		{surface = "犬", left_id = 0, right_id = 0, cost = 5000, pos = "名詞,一般"},
	}
	cells := []i16{-434}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, cells, 1)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	lattice, err := moli.build_lattice(&a, "犬", nil, {}, arena_alloc)
	if err != nil {
		testing.expectf(t, false, "build_lattice: %v", err)
		return
	}
	_, err = moli.viterbi_best_path(&a, lattice, "犬", 0, 0, arena_alloc)
	if err != nil {
		testing.expectf(t, false, "best_path: %v", err)
		return
	}

	// The best path still runs BOS -> 犬 -> EOS (no self-edge was
	// relaxed: the traceback terminates instead of cycling), and the
	// n-best search cost carries the arithmetic: every edge costs
	// -434 here, so the path BOS->犬->EOS sums to
	// (-434 + 5000) + (-434 + 0).
	paths := make([dynamic]moli.NBest_Path, 0, 4, arena_alloc)
	if nerr := moli.tokenize_nbest(&a, "犬", 1, {}, {}, &paths, arena_alloc); nerr != nil {
		testing.expectf(t, false, "nbest: %v", nerr)
		return
	}
	if len(paths) != 1 || paths[0].cost != 5000 - 868 {
		testing.expectf(t, false, "nbest: %v paths (want 1 costing %v)", len(paths), 5000 - 868)
		return
	}

	ms, terr := moli.tokenize(&a, "犬", arena_alloc)
	if terr != nil {
		testing.expectf(t, false, "tokenize: %v", terr)
		return
	}
	if len(ms) != 1 || ms[0].surface != "犬" {
		testing.expectf(t, false, "tokenize: %v morphemes", len(ms))
		return
	}
}

@(test)
viterbi_empty_negative_boundary_test :: proc(t: ^testing.T) {
	// Empty input collapses BOS and EOS onto the same start-0
	// successor bucket (both zero-width at offset 0). With a
	// negative boundary cell (ipadic ships `0 0 -434`) the unfixed
	// DP relaxes BOS back through EOS into a BOS<->EOS prev cycle
	// and tokenize("") hangs. BOS is the DP's fixed source and never
	// a relaxation target, so the path is exactly [BOS, EOS] and the
	// empty input yields zero morphemes (on the unfixed code this
	// test hangs rather than failing - that is the point).
	entries := []Test_Entry{
		{surface = "犬", left_id = 0, right_id = 0, cost = 5000, pos = "名詞,一般"},
	}
	cells := []i16{-434}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, cells, 1)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	lattice, lerr := moli.build_lattice(&a, "", nil, {}, arena_alloc)
	if lerr != nil {
		testing.expectf(t, false, "build_lattice: %v", lerr)
		return
	}
	if len(lattice) != 2 {
		testing.expectf(t, false, "empty lattice: %v nodes", len(lattice))
		return
	}
	path, perr := moli.viterbi_best_path(&a, lattice, "", 0, 0, arena_alloc)
	if perr != nil {
		testing.expectf(t, false, "best_path: %v", perr)
		return
	}
	// BOS is the DP's fixed source: the path is exactly [BOS, EOS] with
	// BOS first and no self-relaxation anywhere (the traceback
	// terminates).
	if len(path) != 2 || path[0] != 0 || path[1] != 1 {
		testing.expectf(t, false, "path: %v (want [0 1])", path)
		return
	}

	ms, terr := moli.tokenize(&a, "", arena_alloc)
	if terr != nil {
		testing.expectf(t, false, "tokenize: %v", terr)
		return
	}
	if len(ms) != 0 {
		testing.expectf(t, false, "tokenize of empty text: %v morphemes", len(ms))
		return
	}

	// The n-best search crosses the same shared start-0 bucket twice
	// more (backward heuristic DP and A* expansion) under the one
	// admission guard: the empty text enumerates exactly one path,
	// [BOS, EOS], emitting no morphemes.
	npaths := make([dynamic]moli.NBest_Path, 0, 1, arena_alloc)
	if nerr := moli.tokenize_nbest(&a, "", 2, {}, moli.Constraints{}, &npaths, arena_alloc); nerr != nil {
		testing.expectf(t, false, "nbest empty: %v", nerr)
		return
	}
	if len(npaths) != 1 {
		testing.expectf(t, false, "empty nbest: %d paths", len(npaths))
		return
	}
	testing.expectf(t, len(npaths[0].morphemes) == 0, "the empty path emits no morphemes")
}

// The homograph range enumeration order: within one terminal the group
// is emitted highest id first (the candidate order the lattice has
// always seen), and a shorter prefix surface arrives in walk order
// before the longer terminal's group.
@(test)
all_matches_order_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "さくら", left_id = 0, right_id = 0, cost = 100, pos = "名詞,一般"},
		{surface = "さくら", left_id = 0, right_id = 0, cost = 50,  pos = "名詞,固有名詞"},
		{surface = "さ",     left_id = 0, right_id = 0, cost = 100, pos = "名詞,一般"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	tab, terr := moli.lattice_walk_table_build(&a.char_map, &a.char_class, "さくら", mem.arena_allocator(&arena))
	if terr != nil {
		testing.expectf(t, false, "table build: %v", terr)
		return
	}
	buf: moli.Match_List
	buf.allocator = mem.arena_allocator(&arena)
	moli.all_matches_at(&a, &tab, 0, &buf)

	// Sorted ids: さ = 0 (prefix), さくら = 1, 2 (file order kept).
	// The walk reaches さ's terminal first, then さくら's group
	// descending.
	want := []int{0, 2, 1}
	if buf.n != len(want) {
		testing.expectf(t, false, "matches: %v, want %v", buf.n, want)
		return
	}
	for w, i in want {
		if moli.match_get(&buf, i) != w {
			testing.expectf(t, false, "matches: %v, want %v", buf.n, want)
			return
		}
	}
}
