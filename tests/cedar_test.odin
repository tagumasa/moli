// Cedar coverage: insert and lookup, placement collisions and the
// high-water cursor, the invariants, char_map round-trip, and
// homograph groups — multiple entries on one surface, surface-sorted
// contiguity, range enumeration, deterministic min-cost resolution.
package tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "moli:moli"

// Cedar_Fixture owns everything one cedar test needs: the entry list
// (cloned surfaces), the built cedar, the builder, and the builder's
// scratch arena. The fixture lives in the test's frame - the dynamic
// arena is initialized through the pointer and never copied by value.
Cedar_Fixture :: struct {
	entries: [dynamic]moli.Dictionary_Entry,
	cedar:   moli.Cedar,
	builder: moli.Cedar_Builder,
	arena:   mem.Dynamic_Arena,
}

// build_cedar builds a cedar over the given surfaces into f (declared
// by the caller). cedar_build reorders the fixture's own array into
// surface order — the slice index after the call IS the entry id —
// while each entry's cost keeps the pre-sort (file) index, so
// homograph resolution still prefers the earliest file row.
build_cedar :: proc(t: ^testing.T, f: ^Cedar_Fixture, surfaces: []string) -> bool {
	allocator := runtime.default_allocator()
	mem.dynamic_arena_init(&f.arena)

	f.entries = make([dynamic]moli.Dictionary_Entry, 0, len(surfaces), allocator)
	for s in surfaces {
		append(&f.entries, moli.Dictionary_Entry{
			surface          = strings.clone(s, allocator),
			cost             = i16(len(f.entries)),
			joined_pos       = strings.clone("*", allocator),
			lemma            = strings.clone(s, allocator),
			reading          = strings.clone("*", allocator),
			reading_jyutping = strings.clone("*", allocator),
		})
	}

	f.builder = moli.Cedar_Builder{
		allocator   = allocator,
		scratch_allocator = mem.dynamic_arena_allocator(&f.arena),
		cedar   = &f.cedar,
	}
	f.builder.entries = f.entries[:]
	if err := moli.cedar_build(&f.builder); err != nil {
		testing.expectf(t, false, "cedar_build failed: %v", err)
		cedar_fixture_destroy(f)
		return false
	}
	return true
}

// cedar_fixture_destroy releases the fixture in the reverse of build
// order.
cedar_fixture_destroy :: proc(f: ^Cedar_Fixture) {
	allocator := runtime.default_allocator()
	for _, i in f.entries {
		moli.dictionary_entry_destroy(&f.entries[i], allocator)
	}
	delete(f.entries)
	delete(f.cedar.base)
	delete(f.cedar.check)
	delete(f.cedar.terminals)
	delete(f.cedar.group_count)
	delete(f.builder.char_map.forward)
	if len(f.builder.char_map.inverse) > 0 { delete(f.builder.char_map.inverse) }
	mem.dynamic_arena_destroy(&f.arena)
}

// table_for builds the request scan table for text on the fixture's
// dynamic arena (released with the fixture). A failed build returns the
// zero table, which makes every match through it fail visibly.
table_for :: proc(f: ^Cedar_Fixture, text: string) -> moli.Scan_Table {
	s, _ := moli.scan_table_build(&f.builder.char_map, text, mem.dynamic_arena_allocator(&f.arena))
	return s
}

@(test)
cedar_insert_lookup_test :: proc(t: ^testing.T) {
	surfaces := []string{"犬", "さくら", "歩く", "東京", "犬小屋"}
	f: Cedar_Fixture
	if !build_cedar(t, &f, surfaces) { return }
	defer cedar_fixture_destroy(&f)

	// Entry ids follow the surface-sorted order the build established:
	// さくら(0), 東京(1), 歩く(2), 犬(3), 犬小屋(4).
	s0 := table_for(&f, "犬が歩く")
	if head, end, matched := moli.cedar_match(&f.cedar, &s0, 0); !matched || head != 3 || end != 3 {
		testing.expectf(t, false, "match 犬: got (%v, %v, %v)", head, end, matched)
		return
	}
	s1 := table_for(&f, "さくらの花見")
	if head, end, matched := moli.cedar_match(&f.cedar, &s1, 0); !matched || head != 0 || end != 9 {
		testing.expectf(t, false, "match さくら: got (%v, %v, %v)", head, end, matched)
		return
	}
	// Longest match: 犬小屋 beats 犬.
	s2 := table_for(&f, "犬小屋の犬")
	if head, end, matched := moli.cedar_match(&f.cedar, &s2, 0); !matched || head != 4 || end != 9 {
		testing.expectf(t, false, "longest 犬小屋: got (%v, %v, %v)", head, end, matched)
		return
	}
	// Mid-string start and a no-dictionary position: 歩く begins at
	// byte 6 (after two 3-byte runes) and spans two runes -> end 12.
	s3 := table_for(&f, "犬が歩く")
	if head, end, matched := moli.cedar_match(&f.cedar, &s3, 6); !matched || head != 2 || end != 12 {
		testing.expectf(t, false, "match 歩く at 6: got (%v, %v, %v)", head, end, matched)
		return
	}
	s4 := table_for(&f, "犬が歩く")
	if _, _, matched := moli.cedar_match(&f.cedar, &s4, 1); matched {
		testing.expectf(t, false, "が must not match")
		return
	}
	// An out-of-vocabulary leading rune ends the walk with no terminal.
	s5 := table_for(&f, "猫が歩く")
	if _, _, matched := moli.cedar_match(&f.cedar, &s5, 0); matched {
		testing.expectf(t, false, "猫 must not match")
		return
	}
}

@(test)
cedar_placement_collision_test :: proc(t: ^testing.T) {
	// Enough shared-prefix siblings to force the placement scan to
	// step over earlier groups. Completing this build at all is the
	// regression guard: grow_arrays once looped forever here.
	surfaces := []string{
		"犬", "犬小屋", "犬用品", "猫", "猫まぐろ", "歩く", "歩行者", "歩道",
		"今日", "今日一", "今日中", "会議", "会議室", "会議中",
	}
	f: Cedar_Fixture
	if !build_cedar(t, &f, surfaces) { return }
	defer cedar_fixture_destroy(&f)

	if len(f.cedar.check) >= 4096 {
		testing.expectf(t, false, "placement grew to %v slots for 14 entries", len(f.cedar.check))
		return
	}
	for s in surfaces {
		tab := table_for(&f, s)
		if _, _, matched := moli.cedar_match(&f.cedar, &tab, 0); !matched {
			testing.expectf(t, false, "surface %q not reachable after placement", s)
			return
		}
	}
	// Every occupied slot beyond the root points at a valid parent
	// (>= 1); slots 0 and 1 are reserved (slot 1 IS the root, its
	// check pointing at the placeholder 0) and never landed on.
	for slot in 2 ..< len(f.cedar.check) {
		if f.cedar.check[slot] >= 0 && f.cedar.check[slot] < 1 {
			testing.expectf(t, false, "slot %v points below the root: %v", slot, f.cedar.check[slot])
			return
		}
	}
}

@(test)
cedar_invariants_test :: proc(t: ^testing.T) {
	surfaces := []string{"犬", "さくら", "歩く", "東京"}
	f: Cedar_Fixture
	if !build_cedar(t, &f, surfaces) { return }
	defer cedar_fixture_destroy(&f)

	if len(f.cedar.base) != len(f.cedar.check) || len(f.cedar.check) != len(f.cedar.terminals) {
		testing.expectf(t, false, "parallel arrays diverge: %v/%v/%v", len(f.cedar.base), len(f.cedar.check), len(f.cedar.terminals))
		return
	}

	// Walk every surface: each transition t = base[s] + code must be
	// in range with check[t] == s, and the walk must end on a terminal.
	for s in surfaces {
		node := i32(1)
		valid := true
		for r in s {
			code, mapped := f.builder.char_map.forward[r]
			if !mapped { valid = false; break }
			t := f.cedar.base[node] + i32(code)
			if int(t) >= len(f.cedar.check) || f.cedar.check[t] != node {
				valid = false
				break
			}
			node = t
		}
		if !valid || f.cedar.terminals[node] < 0 {
			testing.expectf(t, false, "invariant walk failed for %q", s)
			return
		}
	}
}

@(test)
char_map_round_trip_test :: proc(t: ^testing.T) {
	surfaces := []string{"犬が歩く", "さくら", "東京", "今日"}
	f: Cedar_Fixture
	if !build_cedar(t, &f, surfaces) { return }
	defer cedar_fixture_destroy(&f)

	cm := &f.builder.char_map
	if cm.n_chars != len(cm.inverse) || cm.n_chars != len(cm.forward) {
		testing.expectf(t, false, "sizes: n_chars=%v inverse=%v forward=%v", cm.n_chars, len(cm.inverse), len(cm.forward))
		return
	}
	for r, i in cm.inverse {
		code, mapped := cm.forward[r]
		if !mapped || int(code) != i {
			testing.expectf(t, false, "round trip: inverse[%v] -> forward=%v (mapped=%v)", i, code, mapped)
			return
		}
	}
	// Codes are the dense [0, n_chars) range.
	for code in 0 ..< cm.n_chars {
		if _, mapped := cm.forward[cm.inverse[code]]; !mapped {
			testing.expectf(t, false, "code %v has no rune", code)
			return
		}
	}
}

@(test)
cedar_homograph_group_test :: proc(t: ^testing.T) {
	// File order interleaves the homographs; the build must sort by
	// surface (stable within equals) so each surface's entries are one
	// contiguous range. Costs keep their pre-sort (file) index, so the
	// first さくら file row is the cheaper one.
	surfaces := []string{"犬", "さくら", "さくら", "はな", "はな", "ふゆ"}
	f: Cedar_Fixture
	if !build_cedar(t, &f, surfaces) { return }
	defer cedar_fixture_destroy(&f)

	// Surface-sorted, homographs adjacent, file order preserved inside
	// each group (costs are the pre-sort indices).
	sorted := []string{"さくら", "さくら", "はな", "はな", "ふゆ", "犬"}
	costs  := []i16{1, 2, 3, 4, 5, 0}
	for s, i in sorted {
		e := f.entries[i]
		if e.surface != s || e.cost != costs[i] {
			testing.expectf(t, false, "entry %d: (%q, %v), want (%q, %v)", i, e.surface, e.cost, s, costs[i])
			return
		}
	}

	// Group addressing: each surface's head with its count, non-heads
	// carrying zero. さくら = ids {0, 1}, はな = {2, 3}, ふゆ = {4},
	// 犬 = {5}.
	expect := []struct {
		surface: string,
		head:    int,
		count:   int,
	}{
		{surface = "さくら", head = 0, count = 2},
		{surface = "はな",   head = 2, count = 2},
		{surface = "ふゆ",   head = 4, count = 1},
		{surface = "犬",     head = 5, count = 1},
	}
	for g in expect {
		tab := table_for(&f, g.surface)
		head, _, matched := moli.cedar_match(&f.cedar, &tab, 0)
		// An unmatched walk answers head -1, so check the match before
		// indexing group_count with the head.
		if !matched {
			testing.expectf(t, false, "%q: cedar_match did not match", g.surface)
			return
		}
		if head != g.head || int(f.cedar.group_count[head]) != g.count {
			testing.expectf(t, false, "%q: head %v count %v, want (%v, %v)",
				g.surface, head, f.cedar.group_count[head], g.head, g.count)
			return
		}
	}
	if f.cedar.group_count[1] != 0 || f.cedar.group_count[3] != 0 {
		testing.expectf(t, false, "non-head slots must carry 0: %v %v",
			f.cedar.group_count[1], f.cedar.group_count[3])
		return
	}

	// Min-cost resolution is deterministic: the first さくら file row
	// (cost 1) beats the second (cost 2).
	if best := moli.cedar_resolve_entry(&f.cedar, f.entries[:], 0); best != 0 {
		testing.expectf(t, false, "resolve さくら: got %v, want 0", best)
		return
	}

	// Cost tie: equal costs fall to the lower id - the earlier file row
	// of the group.
	f.entries[2].cost = f.entries[3].cost
	if best := moli.cedar_resolve_entry(&f.cedar, f.entries[:], 2); best != 2 {
		testing.expectf(t, false, "resolve はな tie: got %v, want 2", best)
		return
	}
}

// Placement walks an explicit worklist, so trie depth - the longest
// surface's rune count - costs heap, not stack: a surface a hundred
// thousand runes deep (far past anything a real dictionary ships, the
// shape a hostile CSV would send) must load, place, and match rather
// than overflow the call stack.
@(test)
cedar_deep_surface_test :: proc(t: ^testing.T) {
	n := 100_000
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	buf := make([]u8, n * 3, mem.dynamic_arena_allocator(&arena))
	for i in 0 ..< n {
		buf[i * 3]     = 0xE3
		buf[i * 3 + 1] = 0x82
		buf[i * 3 + 2] = 0xA2
	}

	f: Cedar_Fixture
	if !build_cedar(t, &f, []string{string(buf)}) { return }
	defer cedar_fixture_destroy(&f)

	s := table_for(&f, string(buf))
	if head, end, matched := moli.cedar_match(&f.cedar, &s, 0); !matched || head != 0 || end != len(buf) {
		testing.expectf(t, false, "deep surface must match whole: (%v, %v, %v)", head, end, matched)
	}
}
