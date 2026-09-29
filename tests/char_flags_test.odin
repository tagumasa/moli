// char.def category-flag coverage: parse ("NAME INVOKE GROUP LENGTH"
// rows, the DEFAULT row's .Unknown target, unrecognized names
// ignored) and the lattice emission the flags drive - grouped run vs
// 1..length rune prefixes, the invoke bypass at dictionary positions,
// deduplication when the run and a prefix share an end, and the
// both-flags-off single-rune fallback that keeps the lattice
// connected.
package tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import "core:testing"
import "moli:moli"

@(test)
char_flags_default_values_test :: proc(t: ^testing.T) {
	flags := moli.char_flags_default()
	for i in 0 ..< len(moli.Char_Class) {
		if flags[i] != (moli.Char_Flags{invoke = false, group = true, length = 1}) {
			testing.expectf(t, false, "class %d is not the built-in default", i)
			return
		}
	}
	p := moli.char_flags_parse(1, 0, 2)
	testing.expectf(t, p == (moli.Char_Flags{invoke = true, group = false, length = 2}), "parse 1 0 2")
	testing.expectf(t, moli.char_flags_parse(0, 3, -9) == (moli.Char_Flags{invoke = false, group = true, length = 0}), "nonzero is true, negative length clamps to 0")
	testing.expectf(t, moli.char_flags_parse(0, 0, 300).length == 255, "length clamps to 255")
}

@(test)
char_flags_import_test :: proc(t: ^testing.T) {
	write_tmp(t, "tmp/charflags.def", "DEFAULT 0 1 0\nHIRAGANA 0 0 2\nALPHA 1 0 5\nBOGUS 1 1 7\n")
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {char_def_path = "tmp/charflags.def"})
	if !ok { return }
	defer moli.free(&a)

	expect_flag :: proc(t: ^testing.T, got: moli.Char_Flags, want: moli.Char_Flags, what: string) {
		testing.expectf(t, got == want, "%s: got (%v %v %v), want (%v %v %v)",
			what, got.invoke, got.group, got.length, want.invoke, want.group, want.length)
	}
	expect_flag(t, a.char_flags[int(moli.Char_Class.Unknown)],     moli.Char_Flags{false, true, 0}, "DEFAULT row lands on Unknown")
	expect_flag(t, a.char_flags[int(moli.Char_Class.Hiragana)],    moli.Char_Flags{false, false, 2}, "HIRAGANA row")
	expect_flag(t, a.char_flags[int(moli.Char_Class.ASCIILetter)], moli.Char_Flags{true, false, 5}, "ALPHA row")
	expect_flag(t, a.char_flags[int(moli.Char_Class.Katakana)],    moli.Char_Flags{false, true, 1}, "unnamed class keeps the built-in default")
}

// hiragana_analyzer builds a no-dictionary analyzer over a Hiragana
// run so the flag-driven candidates are the only nodes.
hiragana_analyzer :: proc(t: ^testing.T) -> (moli.Analyzer, bool) {
	return build_test_analyzer(t, .Japanese, .Viterbi, nil, nil, 0)
}

@(test)
char_flags_length_splits_run_test :: proc(t: ^testing.T) {
	a, ok := hiragana_analyzer(t)
	if !ok { return }
	defer moli.free(&a)
	// KANJI-style row: no grouped run, candidates of 1..2 runes.
	a.char_flags[int(moli.Char_Class.Hiragana)] = moli.Char_Flags{invoke = false, group = false, length = 2}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	ms, err := moli.tokenize(&a, "あいう", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	covered := 0
	for m in ms {
		covered += len(m.surface)
		if utf8.rune_count_in_string(m.surface) > 2 {
			testing.expectf(t, false, "unknown morpheme %q exceeds the 2-rune cap", m.surface)
			return
		}
	}
	testing.expectf(t, covered == len("あいう"), "surfaces cover the input exactly once (%d of %d bytes)", covered, len("あいう"))
}

@(test)
char_flags_group_only_test :: proc(t: ^testing.T) {
	a, ok := hiragana_analyzer(t)
	if !ok { return }
	defer moli.free(&a)
	// ALPHA-style row: the grouped run alone; length 0 adds no
	// prefixes and no duplicate single rune appears.
	a.char_flags[int(moli.Char_Class.Hiragana)] = moli.Char_Flags{invoke = false, group = true, length = 0}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	ms, err := moli.tokenize(&a, "あいう", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	testing.expectf(t, len(ms) == 1 && ms[0].surface == "あいう", "group-only run: got %d morphemes", len(ms))
}

@(test)
char_flags_all_off_fallback_test :: proc(t: ^testing.T) {
	a, ok := hiragana_analyzer(t)
	if !ok { return }
	defer moli.free(&a)
	a.char_flags[int(moli.Char_Class.Hiragana)] = moli.Char_Flags{invoke = false, group = false, length = 0}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	ms, err := moli.tokenize(&a, "あいう", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	testing.expectf(t, len(ms) == 3 && ms[0].surface == "あ" && ms[2].surface == "う",
		"both flags off: single-rune fallback, got %d morphemes", len(ms))
}

@(test)
char_flags_invoke_at_dict_position_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "あい", left_id = 0, right_id = 0, cost = 0, pos = "名詞"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	// invoke off (the default): a dictionary hit at position 0 means
	// no unknown candidate starts there.
	lattice, lerr := moli.build_lattice(&a, "あいう", nil, {}, arena_alloc)
	if lerr != nil {
		testing.expectf(t, false, "build_lattice: %v", lerr)
		return
	}
	for n in lattice {
		if n.start == 0 && n.is_unknown {
			testing.expectf(t, false, "unknown at 0 despite a dictionary hit and invoke off")
			return
		}
	}

	// invoke on: the single-rune candidates sit next to the
	// dictionary node even though it matched.
	a.char_flags[int(moli.Char_Class.Hiragana)] = moli.Char_Flags{invoke = true, group = true, length = 0}
	lattice2, lerr2 := moli.build_lattice(&a, "あいう", nil, {}, arena_alloc)
	if lerr2 != nil {
		testing.expectf(t, false, "build_lattice 2: %v", lerr2)
		return
	}
	dict_node := false
	unknown_node := false
	for n in lattice2 {
		if n.start == 0 && n.entry_id >= 0 { dict_node = true }
		if n.start == 0 && n.is_unknown { unknown_node = true }
	}
	testing.expectf(t, dict_node && unknown_node, "invoke on: dict=%v unknown=%v at position 0", dict_node, unknown_node)
}

@(test)
char_flags_dedup_test :: proc(t: ^testing.T) {
	a, ok := hiragana_analyzer(t)
	if !ok { return }
	defer moli.free(&a)
	// Group plus a length that reaches the whole run: the rune-prefix
	// loop must not re-emit the grouped candidate's end.
	a.char_flags[int(moli.Char_Class.Hiragana)] = moli.Char_Flags{invoke = false, group = true, length = 3}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	lattice, err := moli.build_lattice(&a, "あいう", nil, {}, mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "build_lattice: %v", err)
		return
	}
	for i in 0 ..< len(lattice) {
		for j in i + 1 ..< len(lattice) {
			if lattice[i].start == lattice[j].start && lattice[i].end == lattice[j].end &&
				lattice[i].is_unknown && lattice[j].is_unknown {
				testing.expectf(t, false, "duplicate unknown candidate (%d,%d)", lattice[i].start, lattice[i].end)
				return
			}
		}
	}
	// The count is the assertion: 3 distinct unknown candidates at
	// position 0 (the grouped run plus the 1-rune and 2-rune
	// prefixes). Counting first - instead of writing into a fixed
	// array - keeps a lattice bug a failed assert, never a bounds
	// panic that would skip this test's defers.
	n_ends := 0
	for n in lattice {
		if n.start == 0 && n.is_unknown { n_ends += 1 }
	}
	if !testing.expectf(t, n_ends == 3, "expected 3 unknown candidates at 0, got %d", n_ends) {
		return
	}
}
