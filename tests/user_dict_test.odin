// User dictionary merge coverage: merged rows win at their cost,
// pre-existing entries keep answering (the merged array re-sorts by
// surface, so ids may shift - nothing public exposes them), a user
// row sharing an existing surface joins its homograph group, a user
// row may introduce runes the original dictionary never carried, the
// mutating flag bounces tokenize, teardown after a merge is clean, a
// qdct snapshot of the merged analyzer restores its segmentation, an
// empty-surface row rejects the batch untouched, and a clone-ladder
// allocation failure releases its partial row (the budget allocator
// keeps every clone under the leak gate).
package tests

import "core:mem"
import "core:testing"
import "moli:moli"

@(test)
user_dict_merge_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "犬", left_id = 0, right_id = 0, cost = 0, pos = "名詞,一般"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	// Before: the second kanji can only be an unknown.
	ms, err := moli.tokenize(&a, "犬助", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "tokenize before: %v", err)
		return
	}
	testing.expectf(t, len(ms) == 2 && ms[1].is_unknown, "犬 + unknown before the merge, got %d", len(ms))

	// Merge a domain term whose negative cost beats the split.
	user := []moli.User_Entry{
		{surface = "犬助", left_id = 0, right_id = 0, cost = -3000, pos = "名詞,固有名詞", lemma = "*", reading = "ケンスケ", reading_jyutping = "*"},
	}
	if uerr := moli.add_user_entries(&a, user); uerr != nil {
		testing.expectf(t, false, "add_user_entries: %v", uerr)
		return
	}

	mem.arena_free_all(&arena)
	ms2, err2 := moli.tokenize(&a, "犬助", arena_alloc)
	if err2 != nil {
		testing.expectf(t, false, "tokenize after: %v", err2)
		return
	}
	if len(ms2) != 1 || ms2[0].surface != "犬助" || ms2[0].is_unknown {
		testing.expectf(t, false, "merged term wins, got %d morphemes", len(ms2))
		return
	}
	testing.expectf(t, ms2[0].pos == "名詞,固有名詞" && ms2[0].reading == "ケンスケ" && ms2[0].lemma == "犬助",
		"user row fields carry: (%s, %s, %s)", ms2[0].pos, ms2[0].reading, ms2[0].lemma)

	// Pre-existing entries keep answering unchanged.
	mem.arena_free_all(&arena)
	ms3, err3 := moli.tokenize(&a, "犬", arena_alloc)
	if err3 != nil {
		testing.expectf(t, false, "tokenize old entry: %v", err3)
		return
	}
	testing.expectf(t, len(ms3) == 1 && ms3[0].surface == "犬" && ms3[0].pos == "名詞,一般", "old entry survives the merge")
}

@(test)
user_dict_new_runes_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "A", left_id = 0, right_id = 0, cost = 0, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .EnglishUS, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	user := []moli.User_Entry{
		{surface = "狗", left_id = 0, right_id = 0, cost = 0, pos = "NOUN", lemma = "*", reading = "*", reading_jyutping = "*"},
	}
	if uerr := moli.add_user_entries(&a, user); uerr != nil {
		testing.expectf(t, false, "add_user_entries: %v", uerr)
		return
	}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	ms, err := moli.tokenize(&a, "狗", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	testing.expectf(t, len(ms) == 1 && ms[0].surface == "狗" && !ms[0].is_unknown,
		"new-rune surface matches after the char-map rebuild, got %d morphemes", len(ms))
}

@(test)
user_dict_mutating_bounce_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "A", left_id = 0, right_id = 0, cost = 0, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .EnglishUS, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	_, err := moli.tokenize(&a, "A", mem.arena_allocator(&arena))
	testing.expectf(t, err == nil, "tokenize before the flag: %v", err)

	a.mutating = true
	_, bounced := moli.tokenize(&a, "A", mem.arena_allocator(&arena))
	testing.expectf(t, bounced == .Unavailable, "tokenize during the swap window bounces, got %v", bounced)
	a.mutating = false

	_, err2 := moli.tokenize(&a, "A", mem.arena_allocator(&arena))
	testing.expectf(t, err2 == nil, "tokenize after the flag clears: %v", err2)
}

@(test)
user_dict_qdct_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	user := []moli.User_Entry{
		{surface = "ぞの犬", left_id = 0, right_id = 0, cost = -5000, pos = "名詞,固有名詞", lemma = "*", reading = "*", reading_jyutping = "*"},
	}
	if uerr := moli.add_user_entries(&a, user); uerr != nil {
		testing.expectf(t, false, "add_user_entries: %v", uerr)
		return
	}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	before, err := moli.tokenize(&a, "ぞの犬", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	b, ok_b := qdct_roundtrip_restore(t, &a, "tmp/user_merged.qdct",
		mem.dynamic_arena_allocator(&scratch), context.allocator)
	if !ok_b { return }
	defer moli.free(&b)

	after, err2 := moli.tokenize(&b, "ぞの犬", mem.arena_allocator(&arena))
	if err2 != nil {
		testing.expectf(t, false, "tokenize restored: %v", err2)
		return
	}
	same := len(before) == len(after)
	if same {
		for i in 0 ..< len(before) {
			if before[i].surface != after[i].surface || before[i].pos != after[i].pos { same = false }
		}
	}
	testing.expectf(t, same, "qdct snapshot restores the merged analyzer's segmentation")
}

// An empty-surface row is rejected with .Invalid_Format before any
// state is touched: an empty surface has no trie path (no terminal
// can ever point at it), so accepting the row would silently drop it
// from every segmentation.
@(test)
user_dict_empty_surface_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "A", left_id = 0, right_id = 0, cost = 0, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .EnglishUS, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	// The valid row ahead of the empty one must not half-land either.
	user := []moli.User_Entry{
		{surface = "B", left_id = 0, right_id = 0, cost = 0, pos = "NOUN", lemma = "*", reading = "*", reading_jyutping = "*"},
		{surface = "", left_id = 0, right_id = 0, cost = 0, pos = "NOUN", lemma = "*", reading = "*", reading_jyutping = "*"},
	}
	err := moli.add_user_entries(&a, user)
	testing.expectf(t, err == moli.Load_Fault.Invalid_Format,
		"an empty-surface row must reject the batch, got %v", err)
	testing.expectf(t, len(a.entries) == 1,
		"the rejected batch must leave the entry list untouched, got %d", len(a.entries))

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, terr := moli.tokenize(&a, "A", mem.arena_allocator(&arena))
	if terr != nil {
		testing.expectf(t, false, "tokenize after the rejection: %v", terr)
		return
	}
	testing.expectf(t, len(ms) == 1 && ms[0].surface == "A", "the analyzer still answers after the rejection")
}

// A budget of 7 (one merged backing + one full row of five clones plus
// the second row's first clone) dies inside the second row's clone
// ladder, so the failing iteration holds a half-cloned row. The
// Budget_Allocator itself lives in helpers.odin.
@(test)
user_dict_oom_midclone_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "A", left_id = 0, right_id = 0, cost = 0, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .EnglishUS, .Viterbi, entries, nil, 0)
	if !ok { return }

	budget := Budget_Allocator{backing = context.allocator, remaining = 7}
	saved := a.allocator
	a.allocator = mem.Allocator{data = &budget, procedure = budget_allocator_proc}
	user := []moli.User_Entry{
		{surface = "rowone", left_id = 0, right_id = 0, cost = 0, pos = "NOUN", lemma = "rowone", reading = "R1", reading_jyutping = "J1"},
		{surface = "rowtwo", left_id = 0, right_id = 0, cost = 0, pos = "NOUN", lemma = "rowtwo", reading = "R2", reading_jyutping = "J2"},
	}
	err := moli.add_user_entries(&a, user)
	a.allocator = saved
	defer moli.free(&a)

	testing.expectf(t, err == moli.Load_Fault.OutOfMemory,
		"a mid-ladder clone failure must surface as .OutOfMemory, got %v", err)
	testing.expectf(t, len(a.entries) == 1,
		"the failed merge must leave no rows behind, got %d", len(a.entries))

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, terr := moli.tokenize(&a, "A", mem.arena_allocator(&arena))
	if terr != nil {
		testing.expectf(t, false, "tokenize after the failed merge: %v", terr)
		return
	}
	testing.expectf(t, len(ms) == 1 && ms[0].surface == "A", "the analyzer still answers after the failed merge")
}

// The swap window's drain: add_user_entries must wait for a held call
// instead of swapping arrays under it. Same shape as
// free_drains_in_flight_test (in analyzer_test) - acquire registers
// the call, the injected wait hook releases it on the second poll,
// and the merge completing proves the drain waited. The merged row
// then answers, so the swap landed on drained state.
@(test)
user_dict_drains_in_flight_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "A", left_id = 0, right_id = 0, cost = 0, pos = "x"},
	}
	a, ok := build_test_analyzer(t, .EnglishUS, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)
	if !moli.acquire(&a) {
		testing.expectf(t, false, "acquire on a fresh analyzer must succeed")
		return
	}
	a.drain_wait = drain_release_at_second_poll

	user := []moli.User_Entry{
		{surface = "AB", left_id = 0, right_id = 0, cost = -3000, pos = "NOUN"},
	}
	if uerr := moli.add_user_entries(&a, user); uerr != nil {
		testing.expectf(t, false, "add_user_entries after the drain: %v", uerr)
		return
	}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, err := moli.tokenize(&a, "AB", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize after the drained merge: %v", err)
		return
	}
	testing.expectf(t, len(ms) == 1 && ms[0].surface == "AB" && !ms[0].is_unknown,
		"the merged row answers after the drain, got %d morphemes", len(ms))
}

// A user row whose surface already exists must join the existing
// homograph group: the merged rebuild re-sorts, the group grows to
// cover both rows, and the lattice enumerates them as separate
// candidates (n-best surfaces the alternative POS).
@(test)
user_dict_homograph_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "犬", left_id = 0, right_id = 0, cost = 5000, pos = "名詞,一般"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	user := []moli.User_Entry{
		{surface = "犬", left_id = 0, right_id = 0, cost = -100, pos = "名詞,固有名詞", lemma = "*", reading = "*", reading_jyutping = "*"},
	}
	if uerr := moli.add_user_entries(&a, user); uerr != nil {
		testing.expectf(t, false, "add_user_entries: %v", uerr)
		return
	}

	// One group of two at the 犬 terminal. The scan table is per-call
	// test scratch on the temp allocator.
	s, _ := moli.scan_table_build(&a.char_map, "犬", context.temp_allocator)
	head, _, matched := moli.cedar_match(&a.cedar, &s, 0)
	// An unmatched walk answers head -1; check the match before indexing
	// group_count.
	if !matched {
		testing.expectf(t, false, "犬 group: cedar_match did not match")
		return
	}
	if int(a.cedar.group_count[head]) != 2 {
		testing.expectf(t, false, "犬 group: head %v count %v", head, a.cedar.group_count[head])
		return
	}
	surfaces := 0
	for i in 0 ..< len(a.entries) {
		if a.entries[i].surface == "犬" { surfaces += 1 }
	}
	if surfaces != 2 {
		testing.expectf(t, false, "犬 rows: %v, want 2", surfaces)
		return
	}

	// The cheaper user row wins the segmentation; the pre-existing row
	// stays a lattice candidate - n-best enumerates both POS.
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, terr := moli.tokenize(&a, "犬", mem.arena_allocator(&arena))
	if terr != nil {
		testing.expectf(t, false, "tokenize: %v", terr)
		return
	}
	if len(ms) != 1 || ms[0].pos != "名詞,固有名詞" {
		testing.expectf(t, false, "user homograph wins: %v morphemes pos %q", len(ms), len(ms) > 0 ? ms[0].pos : "")
		return
	}
	mem.arena_free_all(&arena)
	paths := make([dynamic]moli.NBest_Path, 0, 4, mem.arena_allocator(&arena))
	if perr := moli.tokenize_nbest(&a, "犬", 2, {}, {}, &paths, mem.arena_allocator(&arena)); perr != nil {
		testing.expectf(t, false, "nbest: %v", perr)
		return
	}
	pos_seen := 0
	for p in paths {
		for m in p.morphemes {
			if m.surface == "犬" && m.pos == "名詞,一般" { pos_seen += 1 }
		}
	}
	if pos_seen == 0 {
		testing.expectf(t, false, "the pre-existing 犬 row must remain a candidate")
		return
	}
}

// A merge whose combined alphabet exceeds the u16 char-map codes
// fails cedar_build with .Invalid_Format AFTER the merged list has
// been surface-sorted - the exact failure shape the ownership split
// guards: the release path must destroy the user rows (wherever the
// sort left them) and never the old rows, whose strings the live
// analyzer still owns. The 65536 distinct non-BMP runes make the
// failure deterministic without any allocator choreography, and
// everything rides the tracking allocator so a double free or a
// leaked user string prints.
@(test)
user_dict_merge_invalid_after_sort_test :: proc(t: ^testing.T) {
	a, lerr := moli.load(.EnglishUS, EN_FIXTURE, {}, context.allocator)
	if lerr != nil {
		testing.expectf(t, false, "load: %v", lerr)
		return
	}
	n_before := len(a.entries)

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, block_allocator = context.allocator, array_allocator = context.allocator)
	defer mem.dynamic_arena_destroy(&scratch)

	list, merr := make([dynamic]moli.User_Entry, 0, 65536, context.allocator)
	defer delete(list)
	if merr != nil {
		testing.expectf(t, false, "list make: %v", merr)
		moli.free(&a)
		return
	}
	for i in 0 ..< 65536 {
		// The 0x01 prefix places every user surface before the ASCII
		// base rows in the sort, so the old release path's
		// merged[n_old:] would have targeted exactly the old rows; the
		// distinct 4-byte runes behind it carry the alphabet over the
		// u16 char-map limit.
		r := u32(0x20000 + i)
		buf := make([]u8, 5, mem.dynamic_arena_allocator(&scratch))
		buf[0] = 1
		buf[1] = u8(0xF0 | (r >> 18))
		buf[2] = u8(0x80 | ((r >> 12) & 0x3F))
		buf[3] = u8(0x80 | ((r >> 6) & 0x3F))
		buf[4] = u8(0x80 | (r & 0x3F))
		append(&list, moli.User_Entry{surface = string(buf), pos = "NOUN"})
	}

	err := moli.add_user_entries(&a, list[:])
	testing.expectf(t, err == moli.Load_Fault.Invalid_Format,
		"the over-wide alphabet must fail the merge, got %v", err)
	testing.expectf(t, len(a.entries) == n_before,
		"the failed merge must leave the base rows, got %d", len(a.entries))

	// The old rows' strings must be intact: tokenizing answers (a
	// destroyed old row would read freed memory here or at free).
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, terr := moli.tokenize(&a, "the", mem.arena_allocator(&arena))
	if terr != nil || len(ms) == 0 {
		testing.expectf(t, false, "the analyzer must still tokenize (err %v, %d morphemes)", terr, len(ms))
		moli.free(&a)
		return
	}
	moli.free(&a)
}
